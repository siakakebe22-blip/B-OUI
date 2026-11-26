-- B-OUI — Commande multi-catégories et acheteur invité (additif)
-- Cette migration conserve create_reservation et ajoute un parcours de checkout
-- sans compte, ou avec compte, pour plusieurs catégories d'un même événement.
-- À valider exclusivement sur PostgreSQL local avant toute proposition de migration distante.

begin;

create or replace function public.create_checkout_reservation(
  p_items jsonb,
  p_idempotency_key uuid,
  p_buyer_name text,
  p_buyer_phone text,
  p_buyer_email text default null,
  p_hold_minutes integer default 10
)
returns table (
  reservation_id uuid,
  reservation_reference text,
  total_amount_gnf bigint,
  expires_at timestamptz,
  was_existing boolean
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_normalized_items jsonb;
  v_existing_items jsonb;
  v_reservation public.reservations%rowtype;
  v_ticket public.ticket_types%rowtype;
  v_event public.events%rowtype;
  v_school_status public.school_status;
  v_item record;
  v_total numeric;
  v_expiry timestamptz;
  v_reference text;
begin
  if p_idempotency_key is null
     or jsonb_typeof(p_items) is distinct from 'array'
     or p_buyer_name is null
     or length(trim(p_buyer_name)) not between 2 and 160
     or p_buyer_phone is null
     or p_buyer_phone !~ '^\+[1-9][0-9]{7,14}$'
     or (p_buyer_email is not null and
         (length(trim(p_buyer_email)) > 254 or
          trim(p_buyer_email) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'))
     or p_hold_minutes is distinct from 10 then
    raise exception 'INVALID_CHECKOUT_INPUT' using errcode = '22023';
  end if;

  if jsonb_array_length(p_items) not between 1 and 10 then
    raise exception 'INVALID_CHECKOUT_ITEMS' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) as x(item)
    where jsonb_typeof(x.item) is distinct from 'object'
  ) then
    raise exception 'INVALID_CHECKOUT_ITEMS' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) as x(item)
    where jsonb_typeof(x.item->'ticket_type_id') is distinct from 'string'
       or (x.item->>'ticket_type_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or jsonb_typeof(x.item->'quantity') is distinct from 'number'
       or (x.item->>'quantity') !~ '^[0-9]+$'
       or (x.item->>'quantity')::integer not between 1 and 10
       or exists (
         select 1 from jsonb_object_keys(x.item) as k(key)
         where k.key not in ('ticket_type_id','quantity')
       )
  ) then
    raise exception 'INVALID_CHECKOUT_ITEMS' using errcode = '22023';
  end if;

  if (select sum((x.item->>'quantity')::integer)
      from jsonb_array_elements(p_items) as x(item)) > 10 then
    raise exception 'CHECKOUT_QUANTITY_LIMIT' using errcode = '22023';
  end if;

  -- Normalise les doublons d'une même catégorie avant tout verrouillage.
  select jsonb_agg(
    jsonb_build_object('ticket_type_id', grouped.ticket_type_id::text,
                       'quantity', grouped.quantity)
    order by grouped.ticket_type_id
  )
  into v_normalized_items
  from (
    select (x.item->>'ticket_type_id')::uuid as ticket_type_id,
           sum((x.item->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as x(item)
    group by (x.item->>'ticket_type_id')::uuid
  ) grouped;

  if v_user_id is not null and not exists (
    select 1 from public.profiles p where p.id = v_user_id
  ) then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  -- La clé est globale, car la contrainte unique du schéma l'est aussi.
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 0));

  select r.* into v_reservation
  from public.reservations r
  where r.idempotency_key = p_idempotency_key;

  if found then
    select jsonb_agg(
      jsonb_build_object('ticket_type_id', grouped.ticket_type_id::text,
                         'quantity', grouped.quantity)
      order by grouped.ticket_type_id
    )
    into v_existing_items
    from (
      select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
      from public.reservation_items ri
      where ri.reservation_id = v_reservation.id
      group by ri.ticket_type_id
    ) grouped;

    if v_reservation.buyer_user_id is distinct from v_user_id
       or v_reservation.buyer_name is distinct from trim(p_buyer_name)
       or v_reservation.buyer_phone is distinct from trim(p_buyer_phone)
       or v_reservation.buyer_email is distinct from nullif(trim(p_buyer_email), '')
       or v_existing_items is distinct from v_normalized_items then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;

    return query select v_reservation.id, v_reservation.reference,
      v_reservation.total_amount_gnf, v_reservation.expires_at, true;
    return;
  end if;

  -- Verrouille toutes les catégories dans un ordre stable, puis valide chaque quota.
  for v_item in
    select (x.item->>'ticket_type_id')::uuid as ticket_type_id,
           sum((x.item->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as x(item)
    group by (x.item->>'ticket_type_id')::uuid
    order by (x.item->>'ticket_type_id')::uuid
  loop
    select tt.* into v_ticket
    from public.ticket_types tt
    where tt.id = v_item.ticket_type_id
    for update;

    if not found or not v_ticket.active then
      raise exception 'TICKET_TYPE_UNAVAILABLE' using errcode = 'P0001';
    end if;

    if v_ticket.quantity_total - v_ticket.quantity_reserved - v_ticket.quantity_sold < v_item.quantity then
      raise exception 'INSUFFICIENT_QUOTA' using errcode = 'P0001';
    end if;

    if v_ticket.sales_start_at is not null and clock_timestamp() < v_ticket.sales_start_at then
      raise exception 'SALES_NOT_STARTED' using errcode = 'P0001';
    end if;
    if v_ticket.sales_end_at is not null and clock_timestamp() >= v_ticket.sales_end_at then
      raise exception 'SALES_CLOSED' using errcode = 'P0001';
    end if;

  end loop;

  -- Toutes les catégories sont désormais verrouillées. On verrouille ensuite
  -- l'événement, puis l'école : même ordre que le parcours de réservation historique.
  select e.* into v_event
  from public.events e
  join public.ticket_types first_ticket
    on first_ticket.event_id = e.id
  where first_ticket.id = (v_normalized_items->0->>'ticket_type_id')::uuid
  for share of e;

  if not found then
    raise exception 'EVENT_NOT_AVAILABLE' using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_normalized_items) as x(item)
    join public.ticket_types tt
      on tt.id = (x.item->>'ticket_type_id')::uuid
    where tt.event_id <> v_event.id
  ) then
    raise exception 'ONE_EVENT_PER_CHECKOUT' using errcode = '22023';
  end if;

  if v_event.status <> 'published' then
    raise exception 'EVENT_NOT_AVAILABLE' using errcode = 'P0001';
  end if;

  select s.status into v_school_status
  from public.schools s
  where s.id = v_event.school_id
  for share;

  if not found or v_school_status <> 'verified' then
    raise exception 'SCHOOL_NOT_VERIFIED' using errcode = 'P0001';
  end if;

  select sum((x.item->>'quantity')::numeric * tt.price_gnf::numeric)
  into v_total
  from jsonb_array_elements(v_normalized_items) as x(item)
  join public.ticket_types tt
    on tt.id = (x.item->>'ticket_type_id')::uuid;

  if v_total is null or v_total < 0 or v_total > 9223372036854775807 then
    raise exception 'CHECKOUT_TOTAL_OUT_OF_RANGE' using errcode = '22003';
  end if;

  v_expiry := clock_timestamp() + make_interval(mins => p_hold_minutes);
  v_reference := 'BOUI-' || to_char(clock_timestamp() at time zone 'UTC', 'YYMMDD') ||
    '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.reservations (
    reference, buyer_user_id, buyer_name, buyer_email, buyer_phone,
    event_id, status, currency, total_amount_gnf, idempotency_key, expires_at
  ) values (
    v_reference, v_user_id, trim(p_buyer_name),
    nullif(trim(p_buyer_email), ''), trim(p_buyer_phone),
    v_event.id, 'pending_payment', 'GNF', v_total::bigint,
    p_idempotency_key, v_expiry
  )
  returning * into v_reservation;

  insert into public.reservation_items (
    reservation_id, event_id, ticket_type_id, quantity, unit_price_gnf
  )
  select v_reservation.id, v_event.id, tt.id,
         (x.item->>'quantity')::integer, tt.price_gnf
  from jsonb_array_elements(v_normalized_items) as x(item)
  join public.ticket_types tt
    on tt.id = (x.item->>'ticket_type_id')::uuid
  order by tt.id;

  for v_item in
    select (x.item->>'ticket_type_id')::uuid as ticket_type_id,
           sum((x.item->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(v_normalized_items) as x(item)
    group by (x.item->>'ticket_type_id')::uuid
    order by (x.item->>'ticket_type_id')::uuid
  loop
    update public.ticket_types
    set quantity_reserved = quantity_reserved + v_item.quantity,
        updated_at = clock_timestamp()
    where id = v_item.ticket_type_id;
  end loop;

  return query select v_reservation.id, v_reservation.reference,
    v_reservation.total_amount_gnf, v_reservation.expires_at, false;
end;
$$;

revoke all on function public.create_checkout_reservation(jsonb, uuid, text, text, text, integer)
  from public;
grant execute on function public.create_checkout_reservation(jsonb, uuid, text, text, text, integer)
  to anon, authenticated, service_role;

commit;
