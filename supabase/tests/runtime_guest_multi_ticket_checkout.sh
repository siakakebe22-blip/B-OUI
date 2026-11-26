#!/usr/bin/env bash
set -euo pipefail
: "${DB_URL:?DB_URL requis}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

psql "$DB_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values ('12000000-0000-4000-8000-000000000001','authenticated','authenticated','boui-checkout-user@example.test','',now(),now(),now())
on conflict (id) do nothing;
insert into public.profiles (id,full_name)
values ('12000000-0000-4000-8000-000000000001','Acheteur connecté')
on conflict (id) do nothing;
insert into public.schools (id,name,slug,city,status,verified_at)
values ('22000000-0000-4000-8000-000000000001','École checkout','ecole-checkout','Conakry','verified',now())
on conflict (id) do nothing;
insert into public.events (id,school_id,title,slug,city,venue,starts_at,status,published_at)
values
 ('32000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','Événement checkout','event-checkout','Conakry','Site test',now()+interval '7 days','published',now()),
 ('32000000-0000-4000-8000-000000000002','22000000-0000-4000-8000-000000000001','Autre événement checkout','autre-event-checkout','Conakry','Autre site',now()+interval '8 days','published',now())
on conflict (id) do nothing;
insert into public.ticket_types (id,event_id,name,price_gnf,quantity_total,quantity_reserved,quantity_sold,active)
values
 ('42000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001','Standard',10000,10,0,0,true),
 ('42000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001','VIP',25000,10,0,0,true),
 ('42000000-0000-4000-8000-000000000003','32000000-0000-4000-8000-000000000002','Autre événement',5000,10,0,0,true),
 ('42000000-0000-4000-8000-000000000004','32000000-0000-4000-8000-000000000001','Quota limité',30000,1,0,0,true)
on conflict (id) do nothing;
SQL

# 1. Achat invité avec deux catégories, sans création de compte.
guest_result="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<'SQL'
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true) \gset
select reservation_id || '|' || total_amount_gnf || '|' || was_existing
from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":2},{"ticket_type_id":"42000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000001',
 'Acheteur invité test',
 '+224620000001',
 null,
 5
);
commit;
SQL
)"
IFS='|' read -r guest_id guest_total guest_existing <<<"$guest_result"
[[ "$guest_total" = "45000" && "$guest_existing" = "f" ]] || {
  echo "ÉCHEC : montant ou état initial invité incorrect : $guest_result"; exit 1;
}
guest_owner="$(psql "$DB_URL" -X -Atq -c "select coalesce(buyer_user_id::text,'NULL') from public.reservations where id='$guest_id'")"
guest_items="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.reservation_items where reservation_id='$guest_id'")"
[[ "$guest_owner" = "NULL" && "$guest_items" = "2" ]] || {
  echo "ÉCHEC : commande invitée incorrecte (buyer=$guest_owner, items=$guest_items)"; exit 1;
}
echo "OK — achat invité multi-catégories."

# 2. Même clé et même contenu : même réservation, sans nouveau quota.
replay="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq <<'SQL'
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true) \gset
select was_existing
from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":2},{"ticket_type_id":"42000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000001',
 'Acheteur invité test',
 '+224620000001',
 null,
 5
);
commit;
SQL
)"
[[ "$replay" = "t" ]] || { echo "ÉCHEC : rejeu idempotent non reconnu"; exit 1; }
reserved="$(psql "$DB_URL" -X -Atq -c "select quantity_reserved from public.ticket_types where id='42000000-0000-4000-8000-000000000001'")"
[[ "$reserved" = "2" ]] || { echo "ÉCHEC : le rejeu a modifié le quota ($reserved)"; exit 1; }
echo "OK — idempotence et absence de double réservation."

# 3. La même clé avec une identité différente doit échouer.
if psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true) \gset
select * from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":2},{"ticket_type_id":"42000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000001',
 'Autre acheteur',
 '+224620000001',
 null,
 5
);
commit;
SQL
then
  echo "ÉCHEC : une clé d'idempotence a accepté une identité différente"; exit 1
fi
echo "OK — conflit d'idempotence refusé."

# 4. Une commande ne peut pas mélanger plusieurs événements.
if psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true) \gset
select * from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":1},{"ticket_type_id":"42000000-0000-4000-8000-000000000003","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000002',
 'Acheteur invité test',
 '+224620000001',
 null,
 5
);
commit;
SQL
then
  echo "ÉCHEC : panier multi-événements accepté"; exit 1
fi
echo "OK — panier limité à un événement."

# 5. L'acheteur connecté est correctement rattaché à son profil.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL'
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','12000000-0000-4000-8000-000000000001',true) \gset
select set_config('request.jwt.claims','{"sub":"12000000-0000-4000-8000-000000000001","role":"authenticated"}',true) \gset
select * from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000003',
 'Acheteur connecté',
 '+224620000002',
 'connecte@example.test',
 5
);
commit;
SQL
connected_owner="$(psql "$DB_URL" -X -Atq -c "select buyer_user_id::text from public.reservations where idempotency_key='52000000-0000-4000-8000-000000000003'")"
[[ "$connected_owner" = "12000000-0000-4000-8000-000000000001" ]] || {
  echo "ÉCHEC : acheteur connecté non rattaché au profil"; exit 1;
}
echo "OK — achat avec compte."

# 6. Le total de la commande est plafonné à dix billets.
if psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>&1
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true) \gset
select * from public.create_checkout_reservation(
 '[{"ticket_type_id":"42000000-0000-4000-8000-000000000001","quantity":10},{"ticket_type_id":"42000000-0000-4000-8000-000000000002","quantity":1}]'::jsonb,
 '52000000-0000-4000-8000-000000000004',
 'Acheteur invité test',
 '+224620000001',
 null,
 5
);
commit;
SQL
then
  echo "ÉCHEC : limite de dix billets dépassée"; exit 1
fi
echo "OK — limite de quantité appliquée."
echo "B-OUI runtime guest multi-ticket checkout tests: OK"
