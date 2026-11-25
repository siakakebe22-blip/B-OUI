-- B-OUI : contrôles structurels de la migration 0001
-- Exécuter après migration sur une base PostgreSQL de test avec psql.
-- Ce script ne crée ni ne modifie de données métier.

do $$
declare
  required_table text;
  protected_table text;
  rls_enabled boolean;
begin
  foreach required_table in array array[
    'profiles','schools','school_members','events','event_approvals',
    'organizers','event_organizers','ticket_types','reservations',
    'reservation_items','payments','tickets','ticket_scans',
    'commission_rules','refunds','ticket_recovery_attempts',
    'platform_settings','audit_logs'
  ] loop
    if to_regclass('public.' || required_table) is null then
      raise exception 'Table manquante: public.%', required_table;
    end if;

    select c.relrowsecurity into rls_enabled
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = required_table;

    if not coalesce(rls_enabled, false) then
      raise exception 'RLS non activée sur public.%', required_table;
    end if;
  end loop;

  foreach protected_table in array array[
    'event_approvals','organizers','event_organizers','payments',
    'ticket_scans','commission_rules','refunds',
    'ticket_recovery_attempts','platform_settings','audit_logs'
  ] loop
    if exists (
      select 1 from pg_policies p
      where p.schemaname = 'public'
        and p.tablename = protected_table
        and p.cmd in ('INSERT','UPDATE','DELETE','ALL')
    ) then
      raise exception 'Une politique client d''écriture existe sur la table protégée %', protected_table;
    end if;
  end loop;

  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='payments_one_confirmed_per_reservation'
  ) then
    raise exception 'Index anti-double-confirmation absent';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='ticket_scans_one_accepted_entry'
  ) then
    raise exception 'Index anti-double-entree absent';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.ticket_types'::regclass
      and conname='ticket_types_quantity_reserved_quantity_sold_check'
  ) then
    raise exception 'Contrainte de quota absente';
  end if;
end $$;

select 'B-OUI schema contract: OK' as result;
