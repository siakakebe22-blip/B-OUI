#!/usr/bin/env bash
set -euo pipefail
: "\${DB_URL:?DB_URL doit pointer vers PostgreSQL local}"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
 ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','boui-race-a@example.test','',now(),now(),now()),
 ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','boui-race-b@example.test','',now(),now(),now())
on conflict (id) do nothing;
insert into public.profiles (id, full_name) values
 ('10000000-0000-4000-8000-000000000001','B-OUI Test A'),
 ('10000000-0000-4000-8000-000000000002','B-OUI Test B')
on conflict (id) do nothing;
insert into public.schools (id,name,slug,city,status,verified_at)
values ('20000000-0000-4000-8000-000000000001','École test concurrence','ecole-test-concurrence','Conakry','verified',now())
on conflict (id) do nothing;
insert into public.events (id,school_id,title,slug,city,venue,starts_at,status,published_at)
values ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Événement test concurrence','event-test-concurrence','Conakry','Site test',now()+interval '7 days','published',now())
on conflict (id) do nothing;
insert into public.ticket_types (id,event_id,name,price_gnf,quantity_total,quantity_reserved,quantity_sold,active)
values
 ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','Quota idempotence',10000,10,0,0,true),
 ('40000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','Dernier billet',15000,1,0,0,true),
 ('40000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','Course suspension',20000,5,0,0,true)
on conflict (id) do nothing;
SQL
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
reserve_as() {
  user_id="$1"; ticket_id="$2"; idem="$3"; qty="$4"; output="$5"
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq >"$output" 2>&1 <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$user_id', true);
select set_config('request.jwt.claims', '{"sub":"$user_id","role":"authenticated"}', true);
select pg_sleep(0.35);
select reservation_id from public.create_reservation('$ticket_id', $qty, '$idem', 5);
commit;
SQL
}
# 1. Même clé globale, deux comptes : un succès, un conflit.
key_same="50000000-0000-4000-8000-000000000001"
reserve_as 10000000-0000-4000-8000-000000000001 40000000-0000-4000-8000-000000000001 "$key_same" 1 "$tmp/same-a" & pid_a=$!
reserve_as 10000000-0000-4000-8000-000000000002 40000000-0000-4000-8000-000000000001 "$key_same" 1 "$tmp/same-b" & pid_b=$!
set +e
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e
if ! { [[ "$status_a" -eq 0 && "$status_b" -ne 0 ]] || [[ "$status_b" -eq 0 && "$status_a" -ne 0 ]]; }; then
  echo "ÉCHEC : même clé, il faut exactement un succès et un conflit."
  cat "$tmp/same-a" "$tmp/same-b"; exit 1
fi
same_count="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.reservations where idempotency_key='$key_same'")"
[[ "$same_count" = "1" ]] || { echo "ÉCHEC : nombre de réservations pour la clé=$same_count"; exit 1; }
echo "OK — idempotence globale concurrente."
# 2. Deux clés différentes pour le dernier billet.
key_a="50000000-0000-4000-8000-000000000002"; key_b="50000000-0000-4000-8000-000000000003"
reserve_as 10000000-0000-4000-8000-000000000001 40000000-0000-4000-8000-000000000002 "$key_a" 1 "$tmp/last-a" & pid_a=$!
reserve_as 10000000-0000-4000-8000-000000000002 40000000-0000-4000-8000-000000000002 "$key_b" 1 "$tmp/last-b" & pid_b=$!
set +e
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e
if ! { [[ "$status_a" -eq 0 && "$status_b" -ne 0 ]] || [[ "$status_b" -eq 0 && "$status_a" -ne 0 ]]; }; then
  echo "ÉCHEC : le dernier billet doit être attribué une seule fois."
  cat "$tmp/last-a" "$tmp/last-b"; exit 1
fi
quota="$(psql "$DB_URL" -X -Atq -c "select quantity_reserved + quantity_sold from public.ticket_types where id='40000000-0000-4000-8000-000000000002'")"
count_last="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.reservations r join public.reservation_items i on i.reservation_id=r.id where i.ticket_type_id='40000000-0000-4000-8000-000000000002'")"
[[ "$quota" = "1" && "$count_last" = "1" ]] || { echo "ÉCHEC : quota=$quota, réservations=$count_last"; exit 1; }
echo "OK — aucun dépassement du dernier billet."
# 3. La suspension verrouille l'école avant que la réservation ne vérifie son statut.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<'SQL' &
begin;
update public.schools set status='suspended' where id='20000000-0000-4000-8000-000000000001';
select pg_sleep(2);
commit;
SQL
suspend_pid=$!
sleep 0.25
key_suspended="50000000-0000-4000-8000-000000000004"
set +e
reserve_as 10000000-0000-4000-8000-000000000001 40000000-0000-4000-8000-000000000003 "$key_suspended" 1 "$tmp/suspended"
suspend_status=$?
set -e
wait "$suspend_pid"
if [[ "$suspend_status" -eq 0 ]]; then echo "ÉCHEC : réservation malgré suspension"; cat "$tmp/suspended"; exit 1; fi
suspended_count="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.reservations where idempotency_key='$key_suspended'")"
[[ "$suspended_count" = "0" ]] || { echo "ÉCHEC : réservation créée pendant suspension"; exit 1; }
echo "OK — suspension concurrente respectée."
echo "B-OUI runtime reservation concurrency tests: OK"
