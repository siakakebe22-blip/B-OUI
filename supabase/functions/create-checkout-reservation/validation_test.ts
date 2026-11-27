import { assertEquals } from "jsr:@std/assert@1";
import { checkoutHttpStatus, cleanText, isUuid } from "./validation.ts";

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
