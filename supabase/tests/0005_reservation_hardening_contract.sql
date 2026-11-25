-- B-OUI — Contrat de sécurité du correctif de réservation
-- À exécuter après intégration de la proposition dans une migration, sur PostgreSQL TEST.
-- Ce contrat vérifie la définition et les privilèges ; il ne remplace pas les tests runtime.

do $$
declare
  v_definition text;
begin
  if to_regprocedure('public.create_reservation(uuid,integer,uuid,integer)') is null then
    raise exception 'Fonction create_reservation absente';
  end if;

  select pg_get_functiondef(
    'public.create_reservation(uuid,integer,uuid,integer)'::regprocedure
  ) into v_definition;

  if position('SCHOOL_NOT_VERIFIED' in v_definition) = 0
     or position('v_school_status' in v_definition) = 0
     or position('for share' in lower(v_definition)) = 0 then
    raise exception 'Le contrôle verrouillé de l’école vérifiée est absent';
  end if;

  if position('IDEMPOTENCY_KEY_CONFLICT' in v_definition) = 0
     or position('v_existing_ticket_type_id' in v_definition) = 0
     or position('v_existing_quantity' in v_definition) = 0
     or position('is distinct from p_ticket_type_id' in v_definition) = 0
     or position('is distinct from p_quantity' in v_definition) = 0 then
    raise exception 'La comparaison du contenu de la clé d’idempotence est absente';
  end if;

  if has_function_privilege('anon',
      'public.create_reservation(uuid,integer,uuid,integer)', 'EXECUTE') then
    raise exception 'anon ne doit pas pouvoir créer de réservation';
  end if;
  if not has_function_privilege('authenticated',
      'public.create_reservation(uuid,integer,uuid,integer)', 'EXECUTE') then
    raise exception 'authenticated doit pouvoir appeler create_reservation';
  end if;
end $$;

select 'B-OUI reservation hardening contract: OK' as result;
