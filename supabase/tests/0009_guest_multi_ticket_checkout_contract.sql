-- B-OUI — Contrat de sécurité du checkout invité et multi-catégories
-- PostgreSQL local uniquement.

do $$
declare
  v_definition text;
begin
  if to_regprocedure('public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)') is null then
    raise exception 'Fonction create_checkout_reservation absente';
  end if;

  select pg_get_functiondef(
    'public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)'::regprocedure
  ) into v_definition;

  if position('security definer' in lower(v_definition)) = 0
     or position('search_path' in lower(v_definition)) = 0
     or position('pg_catalog' in lower(v_definition)) = 0
     or position('ONE_EVENT_PER_CHECKOUT' in v_definition) = 0
     or position('SCHOOL_NOT_VERIFIED' in v_definition) = 0
     or position('IDEMPOTENCY_KEY_CONFLICT' in v_definition) = 0
     or position('for update' in lower(v_definition)) = 0
     or position('quantity_reserved' in v_definition) = 0 then
    raise exception 'Contrôles de sécurité du checkout incomplets';
  end if;

  if exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = 'public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)'::regprocedure
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'PUBLIC ne doit pas pouvoir exécuter le checkout';
  end if;
  if not has_function_privilege('anon',
      'public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)', 'EXECUTE') then
    raise exception 'anon doit pouvoir exécuter le checkout invité';
  end if;
  if not has_function_privilege('authenticated',
      'public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)', 'EXECUTE') then
    raise exception 'authenticated doit pouvoir exécuter le checkout';
  end if;
  if has_function_privilege('service_role',
      'public.create_checkout_reservation(jsonb,uuid,text,text,text,integer)', 'EXECUTE') is false then
    raise exception 'service_role doit hériter des privilèges de service';
  end if;

  if to_regprocedure('public.create_reservation(uuid,integer,uuid,integer)') is null then
    raise exception 'Le parcours historique create_reservation doit être conservé';
  end if;
end $$;

select 'B-OUI guest multi-ticket checkout contract: OK' as result;
