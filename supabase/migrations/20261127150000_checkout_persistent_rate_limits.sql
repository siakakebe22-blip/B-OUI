-- B-OUI — Limitation persistante et atomique du checkout.
-- Stockage opaque des identifiants (HMAC côté Edge Function), aucun IP/téléphone brut.
begin;

create table if not exists public.checkout_rate_limits (
  bucket_key text primary key
    check (bucket_key ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  request_count integer not null check (request_count > 0),
  updated_at timestamptz not null default clock_timestamp()
);

alter table public.checkout_rate_limits enable row level security;
revoke all on table public.checkout_rate_limits from public, anon, authenticated;

create or replace function public.consume_checkout_rate_limit(
  p_bucket_key text,
  p_limit integer,
  p_window_seconds integer
)
returns table (allowed boolean, retry_after_seconds integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_started timestamptz;
  v_count integer;
  v_now timestamptz := clock_timestamp();
begin
  if p_bucket_key is null or p_bucket_key !~ '^[0-9a-f]{64}$'
     or p_limit is null or p_limit not between 1 and 1000
     or p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception 'INVALID_RATE_LIMIT_INPUT' using errcode = '22023';
  end if;

  insert into public.checkout_rate_limits as current_bucket
    (bucket_key, window_started_at, request_count, updated_at)
  values (p_bucket_key, v_now, 1, v_now)
  on conflict (bucket_key) do update
    set window_started_at = case
          when current_bucket.window_started_at
               + make_interval(secs => p_window_seconds) <= v_now
          then v_now else current_bucket.window_started_at end,
        request_count = case
          when current_bucket.window_started_at
               + make_interval(secs => p_window_seconds) <= v_now
          then 1 else current_bucket.request_count + 1 end,
        updated_at = v_now
  returning current_bucket.window_started_at, current_bucket.request_count
    into v_started, v_count;

  if v_count > p_limit then
    return query select false,
      greatest(1, ceil(extract(epoch from
        (v_started + make_interval(secs => p_window_seconds) - v_now)))::integer);
  else
    return query select true, 0;
  end if;

  -- Nettoyage opportuniste pour borner la rétention des identifiants HMAC.
  if mod(v_count, 100) = 0 then
    delete from public.checkout_rate_limits
    where window_started_at < v_now - interval '1 day';
  end if;
end;
$$;

revoke all on function public.consume_checkout_rate_limit(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.consume_checkout_rate_limit(text, integer, integer)
  to service_role;

commit;
