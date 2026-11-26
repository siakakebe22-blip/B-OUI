-- B-OUI : contrat de sécurité migration 0007
do $$
declare
  v_claim text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_webhook_events'
      and column_name='lease_token'
  ) then raise exception 'lease_token absent'; end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_webhook_events'
      and column_name='next_attempt_at'
  ) then raise exception 'next_attempt_at absent'; end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_webhook_events'
      and column_name='max_attempts'
  ) then raise exception 'max_attempts absent'; end if;

  if has_table_privilege('anon','public.payment_webhook_events','SELECT')
     or has_table_privilege('authenticated','public.payment_webhook_events','SELECT')
     or has_table_privilege('authenticated','public.payment_webhook_events','INSERT')
     or has_table_privilege('authenticated','public.payment_webhook_events','UPDATE')
     or has_table_privilege('authenticated','public.payment_webhook_events','DELETE') then
    raise exception 'Accès client interdit à l’inbox';
  end if;

  if not has_function_privilege('service_role',
       'public.claim_payment_webhook_events(uuid,integer,integer)','EXECUTE')
     or has_function_privilege('authenticated',
       'public.claim_payment_webhook_events(uuid,integer,integer)','EXECUTE') then
    raise exception 'Droits claim incorrects';
  end if;
  if not has_function_privilege('service_role',
       'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)','EXECUTE')
     or has_function_privilege('authenticated',
       'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)','EXECUTE') then
    raise exception 'Droits finish incorrects';
  end if;

  select pg_get_functiondef(
    'public.claim_payment_webhook_events(uuid,integer,integer)'::regprocedure
  ) into v_claim;
  if position('skip locked' in lower(v_claim)) = 0 then
    raise exception 'Le claim doit utiliser FOR UPDATE SKIP LOCKED';
  end if;
  if position('lease_expires_at' in lower(v_claim)) = 0 then
    raise exception 'Le claim doit gérer les baux expirés';
  end if;
end $$;

select 'B-OUI migration 0007 webhook lifecycle contract: OK' as result;
