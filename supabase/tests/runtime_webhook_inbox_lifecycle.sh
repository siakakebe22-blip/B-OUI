# Déclenche la recette PostgreSQL locale sur la branche dédiée.
#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "ÉCHEC runtime webhook lifecycle ligne ${LINENO} (code ${rc})" >&2; exit "$rc"' ERR
: "${DB_URL:?DB_URL doit pointer vers PostgreSQL local}"

psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "select 1" >/dev/null
event_id="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  insert into public.payment_webhook_events
    (provider, deduplication_key, event_type, payload_sha256, payload_redacted)
  values ('orange_money_gn', 'runtime-lifecycle-' || gen_random_uuid()::text,
          'payment.status', decode(repeat('a',64),'hex'), '{}'::jsonb)
  returning id
")"

claim_as() {
  local worker="$1"
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -AtF '|' -c "
    set role service_role;
    select event_id::text || '|' || lease_token::text
    from public.claim_payment_webhook_events('$worker'::uuid, 10, 30)
    where event_id = '$event_id'::uuid;
    reset role;
  "
}

echo "Étape 1 : première réservation du bail"
first="$(claim_as '11111111-1111-4111-8111-111111111111')"
test -n "$first"
IFS='|' read -r claimed_id first_token <<< "$first"
test "$claimed_id" = "$event_id"

echo "Étape 2 : refus du second worker"
second="$(claim_as '22222222-2222-4222-8222-222222222222')"
test -z "$second"

# Simule un worker disparu : le bail expire, puis un second worker reprend l'événement.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -c "
  update public.payment_webhook_events
  set lease_expires_at = now() - interval '1 second'
  where id = '$event_id'::uuid;
"
echo "Étape 3 : reprise après expiration"
reclaimed="$(claim_as '22222222-2222-4222-8222-222222222222')"
test -n "$reclaimed"
IFS='|' read -r reclaimed_id second_token <<< "$reclaimed"
test "$reclaimed_id" = "$event_id"
test "$second_token" != "$first_token"

# Un ancien détenteur ne peut plus accuser réception.
echo "Étape 4 : rejet de l’ancien jeton"
if psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -c "
  set role service_role;
  select public.finish_payment_webhook_event(
    '$event_id'::uuid, '$first_token'::uuid, 'processed', 'OK', null, false
  );
  reset role;
" >/dev/null 2>&1; then
  echo "ERREUR : un ancien bail a pu terminer l'événement" >&2
  exit 1
fi

echo "Étape 5 : clôture avec le jeton courant"
result="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  set role service_role;
  select public.finish_payment_webhook_event(
    '$event_id'::uuid, '$second_token'::uuid, 'processed', 'OK', null, false
  );
  reset role;
")"
test "$result" = "processed"

status="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  select processing_status || '|' || (processed_at is not null)::text
  from public.payment_webhook_events where id = '$event_id'::uuid
")"
test "$status" = "processed|true"

# Vérifie retry borné puis dead-letter à la limite configurée.
echo "Étape 6 : préparation des tentatives de reprise"
retry_id="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  insert into public.payment_webhook_events
    (provider, deduplication_key, event_type, payload_sha256, payload_redacted, max_attempts)
  values ('orange_money_gn', 'runtime-retry-' || gen_random_uuid()::text,
          'payment.status', decode(repeat('b',64),'hex'), '{}'::jsonb, 2)
  returning id
")"
retry_claim="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -AtF '|' -c "
  set role service_role;
  select event_id::text || '|' || lease_token::text
  from public.claim_payment_webhook_events('33333333-3333-4333-8333-333333333333'::uuid,10,30)
  where event_id = '$retry_id'::uuid;
  reset role;
")"
IFS='|' read -r retry_claimed_id retry_token <<< "$retry_claim"
test "$retry_claimed_id" = "$retry_id"

retry_result="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  set role service_role;
  select public.finish_payment_webhook_event(
    '$retry_id'::uuid, '$retry_token'::uuid, 'failed', null, 'TEMPORARY_PROVIDER_ERROR', true
  );
  reset role;
")"
test "$retry_result" = "failed"

psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -c "
  update public.payment_webhook_events
  set next_attempt_at = now()
  where id = '$retry_id'::uuid;
"
retry_claim2="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -AtF '|' -c "
  set role service_role;
  select event_id::text || '|' || lease_token::text
  from public.claim_payment_webhook_events('44444444-4444-4444-8444-444444444444'::uuid,10,30)
  where event_id = '$retry_id'::uuid;
  reset role;
")"
IFS='|' read -r retry_claimed_id2 retry_token2 <<< "$retry_claim2"
test "$retry_claimed_id2" = "$retry_id"

dead_result="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -Atqc "
  set role service_role;
  select public.finish_payment_webhook_event(
    '$retry_id'::uuid, '$retry_token2'::uuid, 'failed', null, 'RETRY_LIMIT_REACHED', true
  );
  reset role;
")"
test "$dead_result" = "dead_letter"

echo "B-OUI runtime webhook inbox lifecycle: OK"
