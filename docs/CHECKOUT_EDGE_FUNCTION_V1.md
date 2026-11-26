# Edge Function — create-checkout-reservation

## Purpose
Serve as the only public HTTP entry point for the private SQL RPC
`public.create_checkout_reservation(...)`. The browser must never receive or use
`SUPABASE_SERVICE_ROLE_KEY`.

## Request
- Method: POST, JSON only.
- Header: `x-idempotency-key` (UUID).
- Body: `items` (1–10 category lines), `buyer_name`, `buyer_phone` (E.164),
  optional `buyer_email`.
- Guest only: `turnstile_token` from a Turnstile widget configured with action `boui_checkout_guest`.
- Authenticated: `Authorization: Bearer <access-token>`; the function validates
  it with Supabase Auth and derives the buyer UUID from the verified user, never
  from request JSON.

## Required function secrets/configuration
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY` (server-side function secret only)
- `CHECKOUT_ALLOWED_ORIGINS` (comma-separated exact HTTPS origins)
- `TURNSTILE_SECRET_KEY` (required for guest checkout)

The Cloudflare Turnstile site key belongs in the frontend public configuration.
Do not put the Turnstile secret or Supabase service-role key in the frontend,
Git repository, or build-time public variables.

## Security behavior
- Exact origin allowlist; no wildcard CORS.
- POST only; bounded request size; strict input validation.
- Guest requests fail closed if Turnstile is not configured or verification fails; returned hostname must match the allowed request origin and action must equal `boui_checkout_guest`.
- Authenticated buyer identity comes only from a validated access token.
- Server derives all prices and passes a fixed 10-minute hold to the SQL function.
- Service-role RPC call is server-side only.
- Database error details are not exposed to clients.
- No payment is created and no ticket/QR is issued by this endpoint.

## Important launch blockers
This is a first secure gateway implementation, not a production-ready public
checkout. Before public exposure, add and test persistent rate limits for both
guest and authenticated traffic (per IP/device and per account/phone), abuse
monitoring, operational alerts, and a retention policy for buyer contact data.
Do not rely on process-memory counters in an edge runtime. Configure Turnstile
and the exact production origin before deployment. Add integration tests against
a local Supabase Edge Runtime, including invalid JWT, guest challenge failure,
CORS rejection, body-size limits, idempotent replay, and RPC error mapping.

## Deployment
Not deployed by this change. Do not apply migrations remotely or configure
production secrets as part of this PR. Deploy only to a disposable local/test
Supabase environment after the Deno checks and integration tests pass.
