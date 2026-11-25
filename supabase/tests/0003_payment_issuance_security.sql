-- B-OUI : contrat de sécurité de la migration 0003
-- À exécuter après 0001, 0002 et 0003 sur une base Supabase de TEST.
-- Les tests d'intégration webhook/transactions doivent compléter ces assertions.

do $$
begin
  if to_regprocedure('public.confirm_verified_payment(uuid,text,bigint,text,jsonb,jsonb)') is null then
    raise exception 'Fonction confirm_verified_payment absente';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'tickets'
      and column_name = 'qr_key_version'
  ) then
    raise exception 'Version de clé QR absente';
  end if;

  if has_function_privilege('anon',
      'public.confirm_verified_payment(uuid,text,bigint,text,jsonb,jsonb)', 'EXECUTE')
     or has_function_privilege('authenticated',
      'public.confirm_verified_payment(uuid,text,bigint,text,jsonb,jsonb)', 'EXECUTE') then
    raise exception 'Les clients ne doivent pas confirmer les paiements';
  end if;
  if not has_function_privilege('service_role',
      'public.confirm_verified_payment(uuid,text,bigint,text,jsonb,jsonb)', 'EXECUTE') then
    raise exception 'service_role doit pouvoir confirmer un paiement vérifié';
  end if;

  if has_table_privilege('authenticated', 'public.payments', 'UPDATE')
     or has_table_privilege('authenticated', 'public.tickets', 'INSERT')
     or has_table_privilege('authenticated', 'public.ticket_types', 'UPDATE') then
    raise exception 'Une écriture financière ou de billet est accessible au client';
  end if;
end $$;

select 'B-OUI migration 0003 security contract: OK' as result;
