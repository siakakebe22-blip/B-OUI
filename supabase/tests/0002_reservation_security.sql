-- B-OUI : contrat de sécurité de la migration 0002
-- À exécuter après 0001 et 0002 sur une base Supabase de TEST.

do $$
begin
  if to_regprocedure('public.create_reservation(uuid,integer,uuid,integer)') is null then
    raise exception 'Fonction create_reservation absente';
  end if;
  if to_regprocedure('public.expire_pending_reservations(integer)') is null then
    raise exception 'Fonction expire_pending_reservations absente';
  end if;

  if has_function_privilege('anon',
      'public.create_reservation(uuid,integer,uuid,integer)', 'EXECUTE') then
    raise exception 'anon ne doit pas pouvoir créer de réservation';
  end if;
  if not has_function_privilege('authenticated',
      'public.create_reservation(uuid,integer,uuid,integer)', 'EXECUTE') then
    raise exception 'authenticated doit pouvoir appeler create_reservation';
  end if;
  if has_function_privilege('authenticated',
      'public.expire_pending_reservations(integer)', 'EXECUTE') then
    raise exception 'authenticated ne doit pas pouvoir expirer les réservations';
  end if;
  if not has_function_privilege('service_role',
      'public.expire_pending_reservations(integer)', 'EXECUTE') then
    raise exception 'service_role doit pouvoir exécuter le traitement d’expiration';
  end if;

  if has_table_privilege('authenticated', 'public.reservations', 'INSERT') then
    raise exception 'INSERT direct sur reservations doit être interdit';
  end if;
  if has_table_privilege('authenticated', 'public.ticket_types', 'UPDATE') then
    raise exception 'UPDATE direct sur ticket_types doit être interdit';
  end if;
end $$;

select 'B-OUI migration 0002 security contract: OK' as result;
