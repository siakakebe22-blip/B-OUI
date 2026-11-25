-- B-OUI / Migration 0004 : inbox webhook et expiration cohérente des réservations
-- Cette migration ne connecte aucun prestataire et ne traite aucun paiement réel.
-- À exécuter uniquement dans une base de TEST isolée.

begin;

-- Inbox durable : aucune charge utile brute ni secret du prestataire n'est conservé.
-- deduplication_key est calculée par le backend à partir d'un identifiant d'événement
-- stable du prestataire, ou d'une empreinte canonique si aucun ID n'est documenté.
create table public.payment_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null
    check (provider in ('orange_money_gn', 'mtn_momo_gn')),
  provider_event_id text,
  deduplication_key text not null,
  provider_transaction_id text,
  event_type text not null,
  payload_sha256 bytea not null
    check (octet_length(payload_sha256) = 32),
  payload_redacted jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload_redacted) = 'object'),
  processing_status text not null default 'received'
    check (processing_status in ('received', 'processing', 'processed', 'failed', 'ignored')),
  processing_attempts integer not null default 0
    check (processing_attempts >= 0),
  received_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  processed_at timestamptz,
  result_code text,
  constraint payment_webhook_events_dedup_unique
    unique (provider, deduplication_key),
  constraint payment_webhook_events_provider_id_length
    check (provider_event_id is null or length(trim(provider_event_id)) between 1 and 200),
  constraint payment_webhook_events_dedup_length
    check (length(trim(deduplication_key)) between 1 and 220),
  constraint payment_webhook_events_transaction_length
    check (provider_transaction_id is null or length(trim(provider_transaction_id)) between 1 and 180),
  constraint payment_webhook_events_type_length
    check (length(trim(event_type)) between 1 and 120),
  constraint payment_webhook_events_result_length
    check (result_code is null or length(result_code) <= 120),
  constraint payment_webhook_events_processed_timestamp
    check (
      (processing_status = 'processed' and processed_at is not null)
      or (processing_status <> 'processed' and processed_at is null)
    )
);

create index payment_webhook_events_queue_idx
  on public.payment_webhook_events(received_at, id)
  where processing_status in ('received', 'failed');

create index payment_webhook_events_transaction_idx
  on public.payment_webhook_events(provider, provider_transaction_id)
  where provider_transaction_id is not null;

alter table public.payment_webhook_events enable row level security;
revoke all on public.payment_webhook_events from public, anon, authenticated;
grant select, insert, update on public.payment_webhook_events to service_role;

-- Expiration : verrouille d'abord les réservations dans un ordre stable,
-- puis tous les types de billets concernés par UUID croissant. Les quantités
-- sont agrégées et vérifiées avant toute libération : aucun greatest(0, ...)
-- ne masque désormais une incohérence de stock.
create or replace function public.expire_pending_reservations(p_batch_size integer default 200)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_reservation_ids uuid[];
  v_count integer := 0;
begin
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 1000 then
    raise exception 'INVALID_BATCH_SIZE' using errcode = '22023';
  end if;

  select array_agg(batch.id order by batch.expires_at, batch.id)
    into v_reservation_ids
  from (
    select r.id, r.expires_at
    from public.reservations r
    where r.status = 'pending_payment'
      and r.expires_at <= now()
    order by r.expires_at, r.id
    for update skip locked
    limit p_batch_size
  ) as batch;

  if v_reservation_ids is null or cardinality(v_reservation_ids) = 0 then
    return 0;
  end if;

  -- Même ordre global de verrouillage des ticket_types que la confirmation.
  perform tt.id
  from public.ticket_types tt
  where tt.id in (
    select distinct ri.ticket_type_id
    from public.reservation_items ri
    where ri.reservation_id = any(v_reservation_ids)
  )
  order by tt.id
  for update;

  if exists (
    select 1
    from (
      select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
      from public.reservation_items ri
      where ri.reservation_id = any(v_reservation_ids)
      group by ri.ticket_type_id
    ) as totals
    join public.ticket_types tt on tt.id = totals.ticket_type_id
    where tt.quantity_reserved < totals.quantity
  ) then
    raise exception 'RESERVED_QUOTA_INCONSISTENT_DURING_EXPIRATION'
      using errcode = 'P0001';
  end if;

  update public.ticket_types tt
  set quantity_reserved = tt.quantity_reserved - totals.quantity,
      updated_at = now()
  from (
    select ri.ticket_type_id, sum(ri.quantity)::integer as quantity
    from public.reservation_items ri
    where ri.reservation_id = any(v_reservation_ids)
    group by ri.ticket_type_id
  ) as totals
  where tt.id = totals.ticket_type_id;

  update public.reservations
  set status = 'expired', updated_at = now()
  where id = any(v_reservation_ids)
    and status = 'pending_payment'
    and expires_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.expire_pending_reservations(integer)
  from public, anon, authenticated;
grant execute on function public.expire_pending_reservations(integer)
  to service_role;

commit;
