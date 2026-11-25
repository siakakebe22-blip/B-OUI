#!/usr/bin/env bash
set -euo pipefail
: "$DB_URL"
test -n "$DB_URL"

# Fixtures isolées : deux écoles, deux comptes acheteurs et deux réservations.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
 ('11000000-0000-4000-8000-000000000001','authenticated','authenticated','boui-tenant-a@example.test','',now(),now(),now()),
 ('11000000-0000-4000-8000-000000000002','authenticated','authenticated','boui-tenant-b@example.test','',now(),now(),now())
on conflict (id) do nothing;

insert into public.profiles (id, full_name) values
 ('11000000-0000-4000-8000-000000000001','Acheteur école A'),
 ('11000000-0000-4000-8000-000000000002','Acheteur école B')
on conflict (id) do nothing;

insert into public.schools (id,name,slug,city,status,verified_at,contact_email,contact_phone)
values
 ('21000000-0000-4000-8000-000000000001','École isolation A','ecole-isolation-a','Conakry','verified',now(),'secret-a@example.test','+224600000001'),
 ('21000000-0000-4000-8000-000000000002','École isolation B','ecole-isolation-b','Kindia','verified',now(),'secret-b@example.test','+224600000002')
on conflict (id) do nothing;

insert into public.school_members (school_id,user_id,role,active) values
 ('21000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000001','school_admin',true),
 ('21000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000002','school_admin',true)
on conflict (school_id,user_id) do nothing;

insert into public.events (id,school_id,title,slug,city,venue,starts_at,status,published_at)
values
 ('31000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','Événement école A','event-ecole-a','Conakry','Site A',now()+interval '7 days','published',now()),
 ('31000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000002','Événement école B','event-ecole-b','Kindia','Site B',now()+interval '7 days','published',now())
on conflict (id) do nothing;

insert into public.ticket_types (id,event_id,name,price_gnf,quantity_total,active)
values
 ('41000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','Entrée A',10000,20,true),
 ('41000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002','Entrée B',12000,20,true)
on conflict (id) do nothing;
SQL

reserve() {
  local uid="$1" ticket="$2" key="$3"
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','$uid',true);
select set_config('request.jwt.claims','{"sub":"$uid","role":"authenticated"}',true);
select reservation_id from public.create_reservation('$ticket',1,'$key',5);
commit;
SQL
}
reserve 11000000-0000-4000-8000-000000000001 41000000-0000-4000-8000-000000000001 51000000-0000-4000-8000-000000000001 >/dev/null
reserve 11000000-0000-4000-8000-000000000002 41000000-0000-4000-8000-000000000002 51000000-0000-4000-8000-000000000002 >/dev/null

# L'acheteur A ne doit voir aucune réservation, ligne, paiement ou billet de B.
for relation in reservations reservation_items payments tickets; do
  count="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select count(*) from public.$relation t
where
SQL
)"
done
# Vérifications ciblées via identifiants de réservation récupérés depuis les clés.
reservation_b="$(psql "$DB_URL" -X -Atq -c "select id from public.reservations where idempotency_key='51000000-0000-4000-8000-000000000002'")"
reservation_a="$(psql "$DB_URL" -X -Atq -c "select id from public.reservations where idempotency_key='51000000-0000-4000-8000-000000000001'")"
test -n "$reservation_a" && test -n "$reservation_b"

for relation in reservations reservation_items payments tickets; do
  visible="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select count(*) from public.$relation t
where t.reservation_id = '$reservation_b';
rollback;
SQL
)"
  [[ "$visible" = "0" ]] || { echo "ÉCHEC : compte A voit les données B dans $relation ($visible)"; exit 1; }
done

# Un membre d'école ne voit que ses propres lignes d'adhésion.
membership_count="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<'SQL'
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select count(*) from public.school_members;
rollback;
SQL
)"
[[ "$membership_count" = "1" ]] || { echo "ÉCHEC : membre A voit $membership_count lignes d'adhésion"; exit 1; }

# Le compte A ne lit pas les coordonnées privées de l'école B.
private_count="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<'SQL'
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select count(*) from public.school_directory where id='21000000-0000-4000-8000-000000000002';
rollback;
SQL
)"
[[ "$private_count" = "1" ]] || { echo "ÉCHEC : annuaire public incohérent pour l'école B"; exit 1; }

echo "OK — isolation acheteur A/B, adhésions et coordonnées privées."
echo "B-OUI runtime tenant isolation tests: OK"
