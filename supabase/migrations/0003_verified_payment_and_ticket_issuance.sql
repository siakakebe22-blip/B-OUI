-- B-OUI / Migration 0003 : confirmation de paiement vérifiée et émission atomique
-- Le webhook doit être authentifié par l'API (signature, anti-rejeu, statut, montant,
-- devise et référence). Cette fonction n'est PAS un vérificateur de webhook :
-- elle n'est appelable que par le backend de confiance (service_role).
-- À exécuter uniquement dans une base de TEST isolée.

begin;

-- Le QR est un jeton opaque signé côté backend (HMAC avec secret hors base),
-- dérivable à nouveau pour le même ticket. La version permet la rotation des clés.
-- qr_token_hash reste l'empreinte unique du jeton, jamais le jeton ni le secret.
alter table public.tickets
  add column qr_key_version integer not null default 1
  check (qr_key_version > 0);

create or replace function public.confirm_verified_payment(
  p_payment_id uuid,
  p_provider_transaction_id text,
  p_amount_gnf bigint,
  p_currency text,
  p_provider_payload_redacted jsonb,
  p_tickets jsonb
)
returns table (
  payment_id uuid,
  reservation_id uuid,
  was_already_confirmed boolean,
  tickets_issued integer
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_reservation public.reservations%rowtype;
  v_payment public.payments%rowtype;
  v_item record;
  v_expected integer;
  v_supplied integer;
  v_inserted integer := 0;
begin
  if p_payment_id is null
     or p_provider_transaction_id is null
     or length(trim(p_provider_transaction_id)) not between 1 and 180
     or p_amount_gnf is null or p_amount_gnf < 0
     or p_currency is distinct from 'GNF'
     or jsonb_typeof(p_provider_payload_redacted) is distinct from 'object'
     or jsonb_typeof(p_tickets) is distinct from 'array' then
    raise exception 'INVALID_VERIFIED_PAYMENT_INPUT' using errcode = '22023';
  end if;

  -- Ordre de verrouillage commun à la confirmation et à l'expiration :
  -- réservation, paiement, puis types de billets triés par UUID.
  select r.* into v_reservation
  from public.reservations r
  join public.payments p on p.reservation_id = r.id
  where p.id = p_payment_id
  for update of r;

  if not found then
    raise exception 'PAYMENT_OR_RESERVATION_NOT_FOUND' using errcode = 'P0001';
  end if;

  select p.* into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found or v_payment.reservation_id <> v_reservation.id then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.amount_gnf <> p_amount_gnf
     or v_reservation.total_amount_gnf <> p_amount_gnf
     or v_payment.currency <> p_currency then
    raise exception 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH' using errcode = 'P0001';
  end if;

  -- Une notification répétée du même paiement est un succès sans nouvelle émission.
  if v_payment.status = 'confirmed' then
    if v_payment.provider_transaction_id <> p_provider_transaction_id
       or v_reservation.status <> 'paid' then
      raise exception 'CONFIRMED_PAYMENT_CONFLICT' using errcode = '23505';
    end if;
    return query
      select v_payment.id, v_reservation.id, true,
        (select count(*)::integer from public.tickets t
         where t.reservation_id = v_reservation.id);
    return;
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_NOT_PENDING' using errcode = 'P0001';
  end if;
  if v_reservation.status <> 'pending_payment' then
    raise exception 'RESERVATION_NOT_PAYABLE' using errcode = 'P0001';
  end if;
  if v_reservation.expires_at <= now() then
    raise exception 'RESERVATION_EXPIRED_PAYMENT_REQUIRES_MANUAL_REVIEW' using errcode = 'P0001';
  end if;

  select coalesce(sum(ri.quantity), 0)::integer into v_expected
  from public.reservation_items ri
  where ri.reservation_id = v_reservation.id;

  select count(*)::integer into v_supplied
  from jsonb_array_elements(p_tickets);

  if v_expected < 1 or v_supplied <> v_expected then
    raise exception 'TICKET_ISSUANCE_COUNT_MISMATCH' using errcode = '22023';
  end if;

  -- Chaque billet est pré-généré par le backend avec un numéro unique,
  -- une empreinte SHA-256 hexadécimale et une version de clé HMAC.
  if exists (
    select 1
    from jsonb_to_recordset(p_tickets) as x(
      reservation_item_id uuid,
      ticket_number text,
      qr_token_hash_hex text,
      qr_key_version integer
    )
    where x.reservation_item_id is null
       or x.ticket_number is null or length(trim(x.ticket_number)) not between 1 and 100
       or x.qr_token_hash_hex is null or x.qr_token_hash_hex !~ '^[0-9a-fA-F]{64}$'
       or x.qr_key_version is null or x.qr_key_version < 1
  ) then
    raise exception 'INVALID_TICKET_ISSUANCE_PAYLOAD' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_tickets) as x(
      reservation_item_id uuid,
      ticket_number text,
      qr_token_hash_hex text,
      qr_key_version integer
    )
    left join public.reservation_items ri
      on ri.id = x.reservation_item_id
     and ri.reservation_id = v_reservation.id
    where ri.id is null
  ) then
    raise exception 'TICKET_ITEM_DOES_NOT_BELONG_TO_RESERVATION' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.reservation_items ri
    left join (
      select x.reservation_item_id, count(*)::integer as qty
      from jsonb_to_recordset(p_tickets) as x(
        reservation_item_id uuid,
        ticket_number text,
        qr_token_hash_hex text,
        qr_key_version integer
      )
      group by x.reservation_item_id
    ) issued on issued.reservation_item_id = ri.id
    where ri.reservation_id = v_reservation.id
      and coalesce(issued.qty, 0) <> ri.quantity
  ) then
    raise exception 'TICKET_ITEM_QUANTITY_MISMATCH' using errcode = '22023';
  end if;

  -- Verrouillage des stocks dans un ordre stable pour éviter les deadlocks.
  for v_item in
    select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
    from public.reservation_items ri
    where ri.reservation_id = v_reservation.id
    group by ri.ticket_type_id
    order by ri.ticket_type_id
  loop
    perform 1
    from public.ticket_types tt
    where tt.id = v_item.ticket_type_id
    for update;

    if not found then
      raise exception 'TICKET_TYPE_MISSING' using errcode = 'P0001';
    end if;

    if (select tt.quantity_reserved from public.ticket_types tt
        where tt.id = v_item.ticket_type_id) < v_item.quantity then
      raise exception 'RESERVED_QUOTA_INCONSISTENT' using errcode = 'P0001';
    end if;
  end loop;

  update public.payments
  set status = 'confirmed',
      provider_transaction_id = p_provider_transaction_id,
      provider_payload_redacted = p_provider_payload_redacted,
      confirmed_at = now(),
      updated_at = now()
  where id = v_payment.id;

  update public.reservations
  set status = 'paid', paid_at = now(), updated_at = now()
  where id = v_reservation.id;

  for v_item in
    select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
    from public.reservation_items ri
    where ri.reservation_id = v_reservation.id
    group by ri.ticket_type_id
    order by ri.ticket_type_id
  loop
    update public.ticket_types
    set quantity_reserved = quantity_reserved - v_item.quantity,
        quantity_sold = quantity_sold + v_item.quantity,
        updated_at = now()
    where id = v_item.ticket_type_id;
  end loop;

  insert into public.tickets (
    reservation_id, reservation_item_id, ticket_number,
    qr_token_hash, qr_key_version, status
  )
  select v_reservation.id, x.reservation_item_id, x.ticket_number,
         decode(x.qr_token_hash_hex, 'hex'), x.qr_key_version, 'valid'
  from jsonb_to_recordset(p_tickets) as x(
    reservation_item_id uuid,
    ticket_number text,
    qr_token_hash_hex text,
    qr_key_version integer
  );

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_expected then
    raise exception 'TICKET_ISSUANCE_INCOMPLETE' using errcode = 'P0001';
  end if;

  return query select v_payment.id, v_reservation.id, false, v_inserted;
end;
$$;

revoke all on function public.confirm_verified_payment(uuid, text, bigint, text, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.confirm_verified_payment(uuid, text, bigint, text, jsonb, jsonb)
  to service_role;

commit;
