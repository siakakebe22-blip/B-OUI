-- B-OUI : contrat de confidentialité des écoles et immutabilité du journal d'audit
-- À exécuter après toutes les migrations sur PostgreSQL local.

do $$
begin
  if has_table_privilege('anon', 'public.schools', 'SELECT')
     or has_table_privilege('authenticated', 'public.schools', 'SELECT') then
    raise exception 'La table schools reste directement lisible par les clients';
  end if;

  if has_column_privilege('anon', 'public.schools', 'contact_email', 'SELECT')
     or has_column_privilege('anon', 'public.schools', 'contact_phone', 'SELECT')
     or has_column_privilege('authenticated', 'public.schools', 'contact_email', 'SELECT')
     or has_column_privilege('authenticated', 'public.schools', 'contact_phone', 'SELECT') then
    raise exception 'Une coordonnée privée reste lisible par un rôle client';
  end if;

  if not has_column_privilege('anon', 'public.schools', 'status', 'SELECT')
     or not has_column_privilege('authenticated', 'public.schools', 'status', 'SELECT') then
    raise exception 'La colonne status doit être lisible pour filtrer l’annuaire sécurisé';
  end if;

  if not has_table_privilege('anon', 'public.school_directory', 'SELECT')
     or not has_table_privilege('authenticated', 'public.school_directory', 'SELECT') then
    raise exception 'L''annuaire public des écoles n''est pas accessible';
  end if;

  if has_table_privilege('anon', 'public.audit_logs', 'SELECT')
     or has_table_privilege('authenticated', 'public.audit_logs', 'SELECT')
     or has_table_privilege('anon', 'public.audit_logs', 'INSERT')
     or has_table_privilege('authenticated', 'public.audit_logs', 'INSERT') then
    raise exception 'Un rôle client possède un accès au journal d''audit';
  end if;

  if has_table_privilege('service_role', 'public.audit_logs', 'UPDATE')
     or has_table_privilege('service_role', 'public.audit_logs', 'DELETE')
     or has_table_privilege('service_role', 'public.audit_logs', 'TRUNCATE') then
    raise exception 'Le journal d''audit n''est pas append-only pour service_role';
  end if;

  if not has_table_privilege('service_role', 'public.audit_logs', 'INSERT') then
    raise exception 'service_role ne peut pas ajouter de trace d''audit';
  end if;
end $$;

select 'B-OUI security contract 0006: OK' as result;
