-- Contrat SQL : compteur atomique, seuil et isolation des buckets.
begin;

do $$
declare
  v_key text := repeat('a', 64);
  v_result record;
begin
  delete from public.checkout_rate_limits where bucket_key = v_key;

  select * into v_result
  from public.consume_checkout_rate_limit(v_key, 2, 900);
  if v_result.allowed is distinct from true or v_result.retry_after_seconds <> 0 then
    raise exception 'First request should be allowed';
  end if;

  select * into v_result
  from public.consume_checkout_rate_limit(v_key, 2, 900);
  if v_result.allowed is distinct from true or v_result.retry_after_seconds <> 0 then
    raise exception 'Second request should be allowed';
  end if;

  select * into v_result
  from public.consume_checkout_rate_limit(v_key, 2, 900);
  if v_result.allowed is distinct from false or v_result.retry_after_seconds < 1 then
    raise exception 'Third request should be rate limited';
  end if;

  select * into v_result
  from public.consume_checkout_rate_limit(repeat('b', 64), 2, 900);
  if v_result.allowed is distinct from true then
    raise exception 'Buckets must be isolated';
  end if;

  begin
    perform * from public.consume_checkout_rate_limit('raw-phone-number', 2, 900);
    raise exception 'Invalid bucket key should be rejected';
  exception when sqlstate '22023' then
    null;
  end;

  delete from public.checkout_rate_limits
  where bucket_key in (v_key, repeat('b', 64));
end;
$$;

rollback;
