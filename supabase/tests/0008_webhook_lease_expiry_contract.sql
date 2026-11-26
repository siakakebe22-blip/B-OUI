-- B-OUI : contrat de sécurité migration 0008
do $$
declare
  v_finish text;
begin
  select pg_get_functiondef(
    'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)'::regprocedure
  ) into v_finish;

  if position('lease_expires_at' in lower(v_finish)) = 0
     or position('clock_timestamp()' in lower(v_finish)) = 0 then
    raise exception 'La clôture doit refuser un bail expiré avec une horloge réelle';
  end if;

  if has_function_privilege('anon',
       'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)','EXECUTE')
     or has_function_privilege('authenticated',
       'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)','EXECUTE')
     or not has_function_privilege('service_role',
       'public.finish_payment_webhook_event(uuid,uuid,text,text,text,boolean)','EXECUTE') then
    raise exception 'Droits finish incorrects après durcissement';
  end if;
end $$;

select 'B-OUI migration 0008 webhook lease expiry contract: OK' as result;
