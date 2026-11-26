-- B-OUI / Migration 0006 : cloisonnement des coordonnées et journal d'audit append-only
-- À valider exclusivement sur PostgreSQL local avant toute intégration distante.

begin;

-- RLS filtre les lignes, pas les colonnes : les coordonnées de contact ne doivent
-- jamais être exposées par le SELECT public de la table schools.
revoke select on table public.schools from anon, authenticated;
grant select (id, name, slug, city, status) on table public.schools to anon, authenticated;

create or replace view public.school_directory
with (security_invoker = true)
as
select id, name, slug, city
from public.schools
where status = 'verified';

revoke all on table public.school_directory from public;
grant select on table public.school_directory to anon, authenticated;

comment on view public.school_directory is
  'Annuaire public des écoles vérifiées ; aucune coordonnée privée.';

-- Les traces ne sont jamais modifiables ou supprimables par les rôles applicatifs.
revoke all on table public.audit_logs from public, anon, authenticated;
revoke update, delete, truncate, references, trigger
  on table public.audit_logs from service_role;
grant select, insert on table public.audit_logs to service_role;

commit;
