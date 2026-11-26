-- B-OUI / Migration 0008 : refus des accusés après expiration du bail webhook
-- Correctif additif : conserve l'historique de la migration 0007.
begin;

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

  -- Le bail doit être encore valide au moment où le verrou de ligne est acquis.
  -- clock_timestamp() évite qu'une transaction longue prolonge artificiellement
  -- un bail via la sémantique transactionnelle de now().
  if not found
     or v_event.processing_status <> 'processing'
     or v_event.lease_token <> p_lease_token
     or v_event.lease_expires_at <= clock_timestamp() then
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

revoke all on function public.finish_payment_webhook_event(uuid, uuid, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.finish_payment_webhook_event(uuid, uuid, text, text, text, boolean)
  to service_role;

commit;
