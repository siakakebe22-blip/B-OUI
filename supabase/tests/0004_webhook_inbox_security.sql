-- B-OUI : contrat de sécurité et de structure de la migration 0004
-- À exécuter après 0001 à 0004 sur une base Supabase de TEST.

do $$
declare
  v_expiration_definition text;
begin
  if to_regclass('public.payment_webhook_events') is null then
    raise exception 'Table payment_webhook_events absente';
  end if;

  if not (
    select c.relrowsecurity
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'payment_webhook_events'
  ) then
    raise exception 'RLS doit être activée sur payment_webhook_events';
  end if;

  if has_table_privilege('anon', 'public.payment_webhook_events', 'SELECT')
     or has_table_privilege('authenticated', 'public.payment_webhook_events', 'SELECT')
     or has_table_privilege('authenticated', 'public.payment_webhook_events', 'INSERT')
     or has_table_privilege('authenticated', 'public.payment_webhook_events', 'UPDATE')
     or has_table_privilege('authenticated', 'public.payment_webhook_events', 'DELETE') then
    raise exception 'La webhook inbox ne doit pas être accessible aux clients';
  end if;

  if not has_table_privilege('service_role', 'public.payment_webhook_events', 'INSERT')
     or not has_table_privilege('service_role', 'public.payment_webhook_events', 'UPDATE')
     or not has_table_privilege('service_role', 'public.payment_webhook_events', 'SELECT') then
    raise exception 'service_role doit gérer la webhook inbox';
  end if;

  if to_regprocedure('public.expire_pending_reservations(integer)') is null
     or not has_function_privilege(
       'service_role', 'public.expire_pending_reservations(integer)', 'EXECUTE'
     )
     or has_function_privilege(
       'authenticated', 'public.expire_pending_reservations(integer)', 'EXECUTE'
     ) then
    raise exception 'Privilèges de la fonction d’expiration incorrects';
  end if;

  select pg_get_functiondef(
    'public.expire_pending_reservations(integer)'::regprocedure
  ) into v_expiration_definition;

  if position('greatest(0' in lower(v_expiration_definition)) > 0 then
    raise exception 'L’expiration ne doit pas masquer un sous-compte de quota';
  end if;
  if position('order by tt.id' in lower(v_expiration_definition)) = 0 then
    raise exception 'Les verrous de types de billets doivent être ordonnés';
  end if;
end $$;

select 'B-OUI migration 0004 security contract: OK' as result;
