-- B-OUI — Proposition de durcissement de create_reservation
-- Brouillon SQL préparé hors migration : à intégrer dans une migration créée par
-- `supabase migration new ...` après revue et test sur une base locale isolée.
-- Aucun SQL n'a été exécuté sur une base distante.

begin;

create or replace function public.create_reservation(
  p_ticket_type_id uuid,
  p_quantity integer,
  p_idempotency_key uuid,
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
  v_user_id uuid;
  v_ticket public.ticket_types%rowtype;
  v_event public.events%rowtype;
  v_reservation public.reservations%rowtype;
  v_school_status public.school_status;
  v_existing_item_count integer;
  v_existing_ticket_type_id uuid;
  v_existing_quantity integer;
  v_reference text;
  v_total bigint;
  v_expiry timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '28000';
  end if;
  if p_ticket_type_id is null or p_idempotency_key is null then
    raise exception 'INVALID_REQUEST' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then
    raise exception 'QUANTITY_OUT_OF_RANGE' using errcode = '22023';
  end if;
  if p_hold_minutes is null or p_hold_minutes < 1 or p_hold_minutes > 20 then
    raise exception 'HOLD_DURATION_OUT_OF_RANGE' using errcode = '22023';
  end if;

  -- Sérialise les répétitions de la même demande pour ce compte.
  perform pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || ':' || p_idempotency_key::text, 0)
  );

  select r.* into v_reservation
  from public.reservations r
  where r.idempotency_key = p_idempotency_key;

  if found then
    if v_reservation.buyer_user_id is distinct from v_user_id then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;

    select count(*)::integer
      into v_existing_item_count
    from public.reservation_items ri
    where ri.reservation_id = v_reservation.id;

    if v_existing_item_count <> 1 then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;

    select ri.ticket_type_id, ri.quantity
      into v_existing_ticket_type_id, v_existing_quantity
    from public.reservation_items ri
    where ri.reservation_id = v_reservation.id;

    -- Une clé ne peut rejouer que la même demande métier (type + quantité).
    -- La durée du hold n'est pas comparée : elle n'est pas persistée dans le schéma.
    if v_existing_ticket_type_id is distinct from p_ticket_type_id
       or v_existing_quantity is distinct from p_quantity then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;

    return query select v_reservation.id, v_reservation.reference,
      v_reservation.total_amount_gnf, v_reservation.expires_at, true;
    return;
  end if;

  -- Verrouille le quota avant de lire et verrouiller les statuts métier.
  select tt.* into v_ticket
  from public.ticket_types tt
  where tt.id = p_ticket_type_id
  for update;

  if not found or not v_ticket.active then
    raise exception 'TICKET_TYPE_UNAVAILABLE' using errcode = 'P0001';
  end if;

  -- FOR SHARE empêche une dépublication concurrente pendant la réservation.
  select e.* into v_event
  from public.events e
  where e.id = v_ticket.event_id
  for share;

  if not found or v_event.status <> 'published' then
    raise exception 'EVENT_NOT_AVAILABLE' using errcode = 'P0001';
  end if;

  -- SECURITY DEFINER contourne les policies RLS : le contrôle d'école doit
  -- donc être explicite dans la fonction, et verrouillé contre une suspension.
  select s.status into v_school_status
  from public.schools s
  where s.id = v_event.school_id
  for share;

  if not found or v_school_status <> 'verified' then
    raise exception 'SCHOOL_NOT_VERIFIED' using errcode = 'P0001';
  end if;

  if v_ticket.sales_start_at is not null and now() < v_ticket.sales_start_at then
    raise exception 'SALES_NOT_STARTED' using errcode = 'P0001';
  end if;
  if v_ticket.sales_end_at is not null and now() >= v_ticket.sales_end_at then
    raise exception 'SALES_CLOSED' using errcode = 'P0001';
  end if;
  if v_ticket.quantity_total - v_ticket.quantity_reserved - v_ticket.quantity_sold < p_quantity then
    raise exception 'INSUFFICIENT_QUOTA' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  v_total := v_ticket.price_gnf * p_quantity;
  v_expiry := now() + make_interval(mins => p_hold_minutes);
  v_reference := 'BOUI-' || to_char(now() at time zone 'UTC', 'YYMMDD') ||
    '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.reservations (
    reference, buyer_user_id, buyer_name, buyer_email, buyer_phone,
    event_id, status, currency, total_amount_gnf, idempotency_key, expires_at
  )
  select v_reference, v_user_id, p.full_name, u.email, p.phone_e164,
    v_event.id, 'pending_payment', 'GNF', v_total, p_idempotency_key, v_expiry
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.id = v_user_id
  returning * into v_reservation;

  insert into public.reservation_items (
    reservation_id, event_id, ticket_type_id, quantity, unit_price_gnf
  ) values (
    v_reservation.id, v_event.id, v_ticket.id, p_quantity, v_ticket.price_gnf
  );

  update public.ticket_types
  set quantity_reserved = quantity_reserved + p_quantity,
      updated_at = now()
  where id = v_ticket.id;

  return query select v_reservation.id, v_reservation.reference,
    v_reservation.total_amount_gnf, v_reservation.expires_at, false;
end;
$$;

revoke all on function public.create_reservation(uuid, integer, uuid, integer) from public, anon;
grant execute on function public.create_reservation(uuid, integer, uuid, integer) to authenticated;

commit;
