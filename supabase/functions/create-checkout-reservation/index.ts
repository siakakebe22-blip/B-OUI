import { createClient } from "npm:@supabase/supabase-js@2";
import { cleanText, isUuid } from "./validation.ts";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-idempotency-key, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Vary": "Origin",
};

function json(status: number, payload: Record<string, unknown>, origin: string | null, allowed: Set<string>) {
  const headers = new Headers(corsHeaders);
  if (origin && allowed.has(origin)) headers.set("Access-Control-Allow-Origin", origin);
  return new Response(JSON.stringify(payload), { status, headers });
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  const origins = (Deno.env.get("CHECKOUT_ALLOWED_ORIGINS") ?? "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  const allowed = new Set(origins);

  if (request.method === "OPTIONS") {
    if (!origin || !allowed.has(origin)) return new Response(null, { status: 403 });
    const headers = new Headers(corsHeaders);
    headers.set("Access-Control-Allow-Origin", origin);
    return new Response("ok", { headers });
  }
  if (request.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" }, origin, allowed);
  if (!origin || !allowed.has(origin)) return json(403, { error: "ORIGIN_NOT_ALLOWED" }, origin, allowed);

  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return json(415, { error: "UNSUPPORTED_MEDIA_TYPE" }, origin, allowed);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 16_384) return json(413, { error: "REQUEST_TOO_LARGE" }, origin, allowed);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(503, { error: "CHECKOUT_UNAVAILABLE" }, origin, allowed);
  }

  let body: Record<string, unknown>;
  try {
    const raw = await request.text();
    if (new TextEncoder().encode(raw).length > 16_384) {
      return json(413, { error: "REQUEST_TOO_LARGE" }, origin, allowed);
    }
    body = JSON.parse(raw);
    if (!body || Array.isArray(body) || typeof body !== "object") throw new Error("invalid");
  } catch {
    return json(400, { error: "INVALID_REQUEST" }, origin, allowed);
  }

  if (Object.keys(body).some((key) =>
    !["items", "buyer_name", "buyer_phone", "buyer_email", "turnstile_token"].includes(key)
  )) {
    return json(400, { error: "INVALID_CHECKOUT_INPUT" }, origin, allowed);
  }

  const idempotencyKey = request.headers.get("x-idempotency-key");
  const name = cleanText(body.buyer_name, 160);
  const phone = cleanText(body.buyer_phone, 16);
  const email = body.buyer_email === undefined || body.buyer_email === null || body.buyer_email === ""
    ? null : cleanText(body.buyer_email, 254);
  const items = body.items;

  if (!isUuid(idempotencyKey) || !name || name.length < 2 || !phone ||
      !/^\+[1-9][0-9]{7,14}$/.test(phone) ||
      (body.buyer_email !== undefined && body.buyer_email !== null && body.buyer_email !== "" && !email) ||
      !Array.isArray(items) || items.length < 1 || items.length > 10) {
    return json(400, { error: "INVALID_CHECKOUT_INPUT" }, origin, allowed);
  }

  let total = 0;
  for (const item of items) {
    if (!item || typeof item !== "object" || Array.isArray(item) ||
        !isUuid(item.ticket_type_id) || !Number.isSafeInteger(item.quantity) ||
        item.quantity < 1 || item.quantity > 10 ||
        Object.keys(item).some((key) => !["ticket_type_id", "quantity"].includes(key))) {
      return json(400, { error: "INVALID_CHECKOUT_ITEMS" }, origin, allowed);
    }
    total += item.quantity;
    if (total > 10) return json(400, { error: "CHECKOUT_QUANTITY_LIMIT" }, origin, allowed);
  }

  let buyerUserId: string | null = null;
  const authorization = request.headers.get("authorization");
  if (authorization) {
    const match = authorization.match(/^Bearer\s+(.+)$/i);
    if (!match) return json(401, { error: "AUTHENTICATION_REQUIRED" }, origin, allowed);
    const authClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${match[1]}` } },
    });
    const { data, error } = await authClient.auth.getUser(match[1]);
    if (error || !data.user) return json(401, { error: "AUTHENTICATION_REQUIRED" }, origin, allowed);
    buyerUserId = data.user.id;
  } else {
    // Les achats invités exigent une preuve anti-robot vérifiée côté serveur.
    const turnstileSecret = Deno.env.get("TURNSTILE_SECRET_KEY");
    const turnstileToken = cleanText(body.turnstile_token, 2048);
    if (!turnstileSecret || !turnstileToken) {
      return json(503, { error: "GUEST_CHECKOUT_PROTECTION_UNAVAILABLE" }, origin, allowed);
    }
    const verification = new URLSearchParams({
      secret: turnstileSecret,
      response: turnstileToken,
    });
    try {
      const verifyResponse = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: verification,
        signal: AbortSignal.timeout(5000),
      });
      const result: { success?: boolean; hostname?: string; action?: string } =
        await verifyResponse.json();
      const expectedHostname = new URL(origin).hostname;
      if (!verifyResponse.ok || result.success !== true ||
          result.hostname !== expectedHostname || result.action !== "boui_checkout_guest") {
        return json(400, { error: "ANTI_BOT_VERIFICATION_FAILED" }, origin, allowed);
      }
    } catch {
      return json(503, { error: "GUEST_CHECKOUT_PROTECTION_UNAVAILABLE" }, origin, allowed);
    }
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await serviceClient.rpc("create_checkout_reservation", {
    p_items: items,
    p_idempotency_key: idempotencyKey,
    p_buyer_user_id: buyerUserId,
    p_buyer_name: name,
    p_buyer_phone: phone,
    p_buyer_email: email,
    p_hold_minutes: 10,
  });

  if (error) {
    const known = new Set([
      "INVALID_CHECKOUT_INPUT", "INVALID_CHECKOUT_ITEMS", "CHECKOUT_QUANTITY_LIMIT",
      "IDEMPOTENCY_KEY_CONFLICT", "TICKET_TYPE_UNAVAILABLE", "INSUFFICIENT_QUOTA",
      "SALES_NOT_STARTED", "SALES_CLOSED", "EVENT_NOT_AVAILABLE",
      "ONE_EVENT_PER_CHECKOUT", "SCHOOL_NOT_VERIFIED", "PROFILE_REQUIRED",
    ]);
    const message = error.message ?? "";
    const code = [...known].find((value) => message.includes(value));
    if (code) {
      const status = code.startsWith("INVALID_") || code === "CHECKOUT_QUANTITY_LIMIT"
        ? 400
        : code === "PROFILE_REQUIRED"
        ? 403
        : 409;
      return json(status, { error: code }, origin, allowed);
    }
    // Ne jamais exposer les détails PostgreSQL ou les données internes au client.
    return json(503, { error: "CHECKOUT_TEMPORARILY_UNAVAILABLE" }, origin, allowed);
  }

  const reservation = Array.isArray(data) ? data[0] : null;
  if (!reservation) return json(503, { error: "CHECKOUT_TEMPORARILY_UNAVAILABLE" }, origin, allowed);

  // Une répétition idempotente renvoie la réservation existante sans la recréer.
  const responseStatus = reservation.was_existing === true ? 200 : 201;
  return json(responseStatus, {
    reservation_id: reservation.reservation_id,
    reference: reservation.reservation_reference,
    total_amount_gnf: reservation.total_amount_gnf,
    expires_at: reservation.expires_at,
    existing: reservation.was_existing,
    currency: "GNF",
    next_step: "PAYMENT_NOT_ENABLED",
  }, origin, allowed);
});
