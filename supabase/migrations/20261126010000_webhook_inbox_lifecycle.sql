-- B-OUI / Migration 0007 : cycle de vie durable de l'inbox webhook
-- Traitement backend uniquement. Aucun endpoint ni secret fournisseur n'est ajouté.
begin;

alter table public.payment_webhook_events
  drop constraint if exists payment_webhook_events_processing_status_check;

alter table public.payment_webhook_events
  add constraint payment_webhook_events_processing_status_check
  check (processing_status in ('received', 'processing', 'processed', 'failed', 'ignored', 'dead_letter'));

alter table public.payment_webhook_events
  add column if not exists max_attempts integer not null default 8
    check (max_attempts between 1 and 20),
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists lease_owner uuid,
  add column if not exists lease_token uuid,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists last_error_code text,
  add column if not exists updated_at timestamptz not null default now();

alter table public.payment_webhook_events
  add constraint payment_webhook_events_lease_consistency
  check (
    (processing_status = 'processing'
      and lease_owner is not null and lease_token is not null and lease_expires_at is not null)
    or
    (processing_status <> 'processing'
      and lease_owner is null and lease_token is null and lease_expires_at is null)
  ),
  add constraint payment_webhook_events_error_length
  check (last_error_code is null or length(last_error_code) between 1 and 120);

create index payment_webhook_events_due_idx
  on public.payment_webhook_events(next_attempt_at, received_at, id)
  where processing_status in ('received', 'failed');

create index payment_webhook_events_expired_lease_idx
  on public.payment_webhook_events(lease_expires_at, received_at, id)
  where processing_status = 'processing';

-- Réserve un lot de travail de façon atomique. Un événement n'est détenu que
-- par un worker à la fois ; un bail expiré peut être repris par un autre worker.
create or replace function public.claim_payment_webhook_events(
  p_worker_id uuid,
  p_batch_size integer default 20,
  p_lease_seconds integer default 90
)
returns table (
  event_id uuid,
  provider text,
  provider_event_id text,
  provider_transaction_id text,
  event_type text,
  payload_sha256 bytea,
  payload_redacted jsonb,
  processing_attempts integer,
  lease_token uuid,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_worker_id is null then
    raise exception 'INVALID_WORKER_ID' using errcode = '22023';
  end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 100 then
    raise exception 'INVALID_BATCH_SIZE' using errcode = '22023';
  end if;
  if p_lease_seconds is null or p_lease_seconds < 15 or p_lease_seconds > 900 then
    raise exception 'INVALID_LEASE_SECONDS' using errcode = '22023';
  end if;

  update public.payment_webhook_events as e
  set processing_status = 'dead_letter',
      last_error_code = 'LEASE_EXPIRED_RETRY_LIMIT',
      lease_owner = null, lease_token = null, lease_expires_at = null,
      updated_at = now()
  where e.processing_status = 'processing'
    and e.lease_expires_at <= now()
    and e.processing_attempts >= e.max_attempts;

  return query
  with candidates as (
    select e.id
    from public.payment_webhook_events e
    where e.processing_attempts < e.max_attempts
      and (
        (e.processing_status in ('received', 'failed') and e.next_attempt_at <= now())
        or
        (e.processing_status = 'processing' and e.lease_expires_at <= now())
      )
    order by e.next_attempt_at, e.received_at, e.id
    for update skip locked
    limit p_batch_size
  )
  update public.payment_webhook_events e
  set processing_status = 'processing',
      processing_attempts = e.processing_attempts + 1,
      last_attempt_at = now(),
      lease_owner = p_worker_id,
      lease_token = gen_random_uuid(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      updated_at = now()
  from candidates c
  where e.id = c.id
  returning e.id, e.provider, e.provider_event_id, e.provider_transaction_id,
            e.event_type, e.payload_sha256, e.payload_redacted,
            e.processing_attempts, e.lease_token, e.lease_expires_at;
end;
$$;

-- Accusé interne idempotent : seul le détenteur du bail courant peut terminer
-- l'événement. Les échecs retryables suivent un backoff exponentiel plafonné.
create or replace function public.finish_payment_webhook_event(
  p_event_id uuid,
  p_lease_token uuid,
  p_outcome text,
  p_result_code text default null,
  p_error_code text default null,
  p_retryable boolean default false
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event public.payment_webhook_events%rowtype;
  v_status text;
  v_delay_seconds integer;
begin
  if p_event_id is null or p_lease_token is null then
    raise exception 'INVALID_EVENT_LEASE' using errcode = '22023';
  end if;
  if p_outcome is null or p_outcome not in ('processed', 'ignored', 'failed') then
    raise exception 'INVALID_WEBHOOK_OUTCOME' using errcode = '22023';
  end if;
  if p_result_code is not null and length(p_result_code) > 120 then
    raise exception 'INVALID_RESULT_CODE' using errcode = '22023';
  end if;
  if p_error_code is not null and length(p_error_code) not between 1 and 120 then
    raise exception 'INVALID_ERROR_CODE' using errcode = '22023';
  end if;

  select * into v_event
  from public.payment_webhook_events
  where id = p_event_id
  for update;

  if not found
     or v_event.processing_status <> 'processing'
     or v_event.lease_token <> p_lease_token then
    raise exception 'WEBHOOK_LEASE_NOT_OWNED' using errcode = '42501';
  end if;

  if p_outcome = 'processed' then
    v_status := 'processed';
  elsif p_outcome = 'ignored' then
    v_status := 'ignored';
  elsif p_retryable and v_event.processing_attempts < v_event.max_attempts then
    v_status := 'failed';
  else
    v_status := 'dead_letter';
  end if;

  v_delay_seconds := least(
    3600,
    (30 * power(2, greatest(v_event.processing_attempts - 1, 0)))::integer
  );

  update public.payment_webhook_events
  set processing_status = v_status,
      processed_at = case when v_status = 'processed' then now() else null end,
      result_code = p_result_code,
      last_error_code = case when v_status in ('failed', 'dead_letter') then p_error_code else null end,
      next_attempt_at = case when v_status = 'failed'
        then now() + make_interval(secs => v_delay_seconds)
        else next_attempt_at end,
      lease_owner = null,
      lease_token = null,
      lease_expires_at = null,
      updated_at = now()
  where id = p_event_id;

  return v_status;
end;
$$;

revoke all on function public.claim_payment_webhook_events(uuid, integer, integer)
  from public, anon, authenticated;
revoke all on function public.finish_payment_webhook_event(uuid, uuid, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_payment_webhook_events(uuid, integer, integer)
  to service_role;
grant execute on function public.finish_payment_webhook_event(uuid, uuid, text, text, text, boolean)
  to service_role;

revoke all on public.payment_webhook_events from public, anon, authenticated;
grant select, insert, update on public.payment_webhook_events to service_role;

commit;
