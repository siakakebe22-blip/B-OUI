#!/usr/bin/env bash
set -euo pipefail
: "$DB_URL"
test -n "$DB_URL"

buyer="10000000-0000-4000-8000-000000000001"
school="20000000-0000-4000-8000-000000000002"
event="30000000-0000-4000-8000-000000000002"
ticket_type="40000000-0000-4000-8000-000000000004"

psql "$DB_URL" -X -v ON_ERROR_STOP=1 <<SQL
insert into public.schools (id,name,slug,city,status,verified_at)
values ('$school','École paiement test','ecole-paiement-test','Conakry','verified',now());
insert into public.events (id,school_id,title,slug,city,venue,starts_at,status,published_at)
values ('$event','$school','Événement paiement test','event-paiement-test','Conakry','Site test',now()+interval '7 days','published',now());
insert into public.ticket_types (id,event_id,name,price_gnf,quantity_total,active)
values ('$ticket_type','$event','Billet paiement',25000,10,true);
SQL

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
create_reservation() {
  local key="$1" output="$2"
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq >"$output" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$buyer', true);
select set_config('request.jwt.claims', '{"sub":"$buyer","role":"authenticated"}', true);
select reservation_id from public.create_reservation('$ticket_type', 1, '$key', 5);
commit;
SQL
}
# Deux confirmations simultanées du même paiement doivent émettre un seul billet.
reservation_key="60000000-0000-4000-8000-000000000001"
create_reservation "$reservation_key" "$tmp/reservation"
reservation_id="$(tail -n1 "$tmp/reservation" | tr -d '[:space:]')"
[[ -n "$reservation_id" ]] || { cat "$tmp/reservation"; echo "Réservation de test non créée"; exit 1; }
item_id="$(psql "$DB_URL" -X -Atq -c "select id from public.reservation_items where reservation_id='$reservation_id'")"
payment_id="70000000-0000-4000-8000-000000000001"
payment_key="60000000-0000-4000-8000-000000000002"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -c \
  "insert into public.payments(id,reservation_id,provider,idempotency_key,amount_gnf,currency) values ('$payment_id','$reservation_id','orange_money_gn','$payment_key',25000,'GNF')"
confirm_sql="begin; set local role service_role; select * from public.confirm_verified_payment('$payment_id','OM-GN-TEST-0001',25000,'GNF','{\"source\":\"runtime-test\"}'::jsonb,'[{\"reservation_item_id\":\"$item_id\",\"ticket_number\":\"BOUI-RUNTIME-0001\",\"qr_token_hash_hex\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"qr_key_version\":1}]'::jsonb); commit;"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq -c "$confirm_sql" >"$tmp/confirm-a" 2>&1 & pid_a=$!
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq -c "$confirm_sql" >"$tmp/confirm-b" 2>&1 & pid_b=$!
wait "$pid_a"
wait "$pid_b"
ticket_count="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.tickets where reservation_id='$reservation_id'")"
payment_status="$(psql "$DB_URL" -X -Atq -c "select status from public.payments where id='$payment_id'")"
reservation_status="$(psql "$DB_URL" -X -Atq -c "select status from public.reservations where id='$reservation_id'")"
quota="$(psql "$DB_URL" -X -Atq -c "select quantity_reserved || ':' || quantity_sold from public.ticket_types where id='$ticket_type'")"
[[ "$ticket_count" = "1" && "$payment_status" = "confirmed" && "$reservation_status" = "paid" && "$quota" = "0:1" ]] || {
  echo "ÉCHEC confirmation idempotente: billets=$ticket_count paiement=$payment_status réservation=$reservation_status quota=$quota"
  cat "$tmp/confirm-a" "$tmp/confirm-b"; exit 1;
}
echo "OK — confirmations simultanées : un seul billet émis."

# Paiement tardif : refus, expiration de la réservation et libération du quota.
late_key="60000000-0000-4000-8000-000000000003"
create_reservation "$late_key" "$tmp/late-reservation"
late_reservation="$(tail -n1 "$tmp/late-reservation" | tr -d '[:space:]')"
late_item="$(psql "$DB_URL" -X -Atq -c "select id from public.reservation_items where reservation_id='$late_reservation'")"
late_payment="70000000-0000-4000-8000-000000000002"
late_payment_key="60000000-0000-4000-8000-000000000004"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<SQL
update public.reservations set expires_at=now()-interval '1 second' where id='$late_reservation';
insert into public.payments(id,reservation_id,provider,idempotency_key,amount_gnf,currency)
values ('$late_payment','$late_reservation','orange_money_gn','$late_payment_key',25000,'GNF');
SQL
late_sql="begin; set local role service_role; select * from public.confirm_verified_payment('$late_payment','OM-GN-TEST-LATE',25000,'GNF','{\"source\":\"runtime-test\"}'::jsonb,'[{\"reservation_item_id\":\"$late_item\",\"ticket_number\":\"BOUI-RUNTIME-LATE\",\"qr_token_hash_hex\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"qr_key_version\":1}]'::jsonb); commit;"
set +e
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atq -c "$late_sql" >"$tmp/late-confirm" 2>&1
late_status=$?
set -e
[[ "$late_status" -ne 0 ]] || { echo "ÉCHEC : paiement tardif accepté"; exit 1; }
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -c "set role service_role; select public.expire_pending_reservations(100)" >/dev/null
late_state="$(psql "$DB_URL" -X -Atq -c "select r.status || ':' || p.status || ':' || (select count(*) from public.tickets t where t.reservation_id=r.id) from public.reservations r join public.payments p on p.reservation_id=r.id where r.id='$late_reservation'")"
[[ "$late_state" = "expired:pending:0" ]] || { echo "ÉCHEC état après paiement tardif: $late_state"; cat "$tmp/late-confirm"; exit 1; }
echo "OK — paiement tardif refusé, réservation expirée, aucun billet émis."

# L'inbox refuse un doublon du même événement fournisseur.
webhook_key="runtime-duplicate-event-0001"
webhook_id="80000000-0000-4000-8000-000000000001"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q <<SQL
insert into public.payment_webhook_events
(id,provider,provider_event_id,deduplication_key,event_type,payload_sha256,payload_redacted)
values ('$webhook_id','orange_money_gn','evt-runtime-0001','$webhook_key','payment.success',decode(repeat('c',64),'hex'),'{}'::jsonb)
on conflict (provider,deduplication_key) do nothing;
insert into public.payment_webhook_events
(provider,provider_event_id,deduplication_key,event_type,payload_sha256,payload_redacted)
values ('orange_money_gn','evt-runtime-0001','$webhook_key','payment.success',decode(repeat('c',64),'hex'),'{}'::jsonb)
on conflict (provider,deduplication_key) do nothing;
SQL
webhook_count="$(psql "$DB_URL" -X -Atq -c "select count(*) from public.payment_webhook_events where provider='orange_money_gn' and deduplication_key='$webhook_key'")"
[[ "$webhook_count" = "1" ]] || { echo "ÉCHEC déduplication webhook: $webhook_count"; exit 1; }
echo "OK — doublon webhook dédupliqué par contrainte unique."
echo "B-OUI runtime payment idempotency tests: OK"
