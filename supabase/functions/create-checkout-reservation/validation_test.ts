import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
// Teste le statut HTTP choisi pour une création ou un rejeu idempotent.
import {
  checkoutHttpStatus,
  checkoutRateLimitBucket,
  checkoutRateLimitPolicies,
  cleanText,
  isUuid,
} from "./validation.ts";

Deno.test("isUuid accepts a canonical UUID v4", () => {
  assertEquals(isUuid("550e8400-e29b-41d4-a716-446655440000"), true);
});

Deno.test("isUuid rejects malformed values", () => {
  assertEquals(isUuid("not-a-uuid"), false);
  assertEquals(isUuid(null), false);
  assertEquals(isUuid("00000000-0000-0000-0000-000000000000"), false);
});

Deno.test("cleanText trims valid text and enforces maximum length", () => {
  assertEquals(cleanText("  Acheteur  ", 20), "Acheteur");
  assertEquals(cleanText("trop-long", 3), null);
});

Deno.test("cleanText rejects empty and non-string values", () => {
  assertEquals(cleanText("   ", 20), null);
  assertEquals(cleanText(123, 20), null);
  assertEquals(cleanText(undefined, 20), null);
});

Deno.test("checkout returns 201 for a new reservation", () => {
  assertEquals(checkoutHttpStatus(false), 201);
});

Deno.test("checkout returns 200 for an idempotent replay", () => {
  assertEquals(checkoutHttpStatus(true), 200);
});

Deno.test("checkout rate limits phone, account, IP and device independently", () => {
  const policies = checkoutRateLimitPolicies({
    phone: "+224620000000",
    userId: "00000000-0000-4000-8000-000000000001",
    ip: "203.0.113.10",
    deviceId: "00000000-0000-4000-8000-000000000002",
  });
  assertEquals(policies.map((policy) => policy.kind), ["phone", "account", "ip", "device"]);
  assertEquals(policies.map((policy) => policy.limit), [5, 10, 30, 12]);
});

Deno.test("guest checkout always has phone rate limiting", () => {
  const policies = checkoutRateLimitPolicies({
    phone: "+224620000000", userId: null, ip: null, deviceId: null,
  });
  assertEquals(policies.length, 1);
  assertEquals(policies[0].kind, "phone");
});

Deno.test("rate limit bucket is stable, opaque and keyed by secret", async () => {
  const secret = "a-secret-that-is-at-least-32-characters";
  const first = await checkoutRateLimitBucket(secret, "phone", "+224620000000");
  const same = await checkoutRateLimitBucket(secret, "phone", "+224620000000");
  const otherSecret = await checkoutRateLimitBucket("another-secret-at-least-32-characters", "phone", "+224620000000");
  assertEquals(first, same);
  assertEquals(first.length, 64);
  assertNotEquals(first, otherSecret);
  if (first.includes("224620000000")) throw new Error("Raw phone leaked into bucket key");
});
