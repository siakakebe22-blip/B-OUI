-- B-OUI / Migration 0002 : réservation atomique et expiration
-- Cible : Supabase PostgreSQL. À exécuter uniquement dans un environnement de test isolé.
-- La confirmation de paiement et l'émission des billets seront ajoutées dans une migration séparée.

begin;

-- Les clients ne peuvent lire que les ressources publiques ou leurs propres données.
-- Les écritures passent par les fonctions contrôlées ou le backend de confiance.
grant select on public.schools, public.events, public.ticket_types to anon, authenticated;
grant select on public.profiles, public.school_members,
  public.reservations, public.reservation_items, public.payments, public.tickets
  to authenticated;
grant update (full_name, phone_e164) on public.profiles to authenticated;

-- Interdit les écritures directes des clients sur les compteurs de quotas et les opérations financières.
revoke insert, update, delete, truncate, references, trigger
  on public.reservations, public.reservation_items, public.payments,
     public.tickets, public.ticket_types, public.ticket_scans, public.refunds
  from anon, authenticated;

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

  -- Sérialise les répétitions d'une même demande pour ce compte.
  perform pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || ':' || p_idempotency_key::text, 0)
  );

  select r.* into v_reservation
  from public.reservations r
  where r.idempotency_key = p_idempotency_key;

  if found then
    if v_reservation.buyer_user_id <> v_user_id then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;
    return query select v_reservation.id, v_reservation.reference,
      v_reservation.total_amount_gnf, v_reservation.expires_at, true;
    return;
  end if;

  -- Verrouille le type de billet : deux acheteurs ne peuvent consommer le même dernier quota.
  select tt.* into v_ticket
  from public.ticket_types tt
  where tt.id = p_ticket_type_id
  for update;

  if not found or not v_ticket.active then
    raise exception 'TICKET_TYPE_UNAVAILABLE' using errcode = 'P0001';
  end if;

  select e.* into v_event
  from public.events e
  where e.id = v_ticket.event_id;

  if not found or v_event.status <> 'published' then
    raise exception 'EVENT_NOT_AVAILABLE' using errcode = 'P0001';
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

-- Expiration par lots. La réservation est verrouillée avant libération du quota.
-- À appeler périodiquement depuis un ordonnanceur/backend de confiance.
create or replace function public.expire_pending_reservations(p_batch_size integer default 200)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_reservation record;
  v_item record;
  v_count integer := 0;
begin
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 1000 then
    raise exception 'INVALID_BATCH_SIZE' using errcode = '22023';
  end if;

  for v_reservation in
    select r.id
    from public.reservations r
    where r.status = 'pending_payment'
      and r.expires_at <= now()
    order by r.expires_at
    for update skip locked
    limit p_batch_size
  loop
    -- La mise à jour conditionnelle rend le traitement idempotent.
    update public.reservations
    set status = 'expired', updated_at = now()
    where id = v_reservation.id
      and status = 'pending_payment'
      and expires_at <= now();

    if found then
      for v_item in
        select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
        from public.reservation_items ri
        where ri.reservation_id = v_reservation.id
        group by ri.ticket_type_id
      loop
        update public.ticket_types
        set quantity_reserved = greatest(0, quantity_reserved - v_item.quantity),
            updated_at = now()
        where id = v_item.ticket_type_id;
      end loop;
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_pending_reservations(integer) from public, anon, authenticated;
-- Le rôle service_role est réservé au backend/ordonnanceur de confiance dans Supabase.
grant execute on function public.expire_pending_reservations(integer) to service_role;

commit;
