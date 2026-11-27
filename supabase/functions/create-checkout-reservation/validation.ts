export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}

export function cleanText(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length > 0 && result.length <= max ? result : null;
}

export function checkoutHttpStatus(wasExisting: boolean): 200 | 201 {
  return wasExisting ? 200 : 201;
}

export function checkoutRateLimitPolicies(input: {
  phone: string;
  userId: string | null;
  ip: string | null;
  deviceId: string | null;
}): Array<{ kind: string; value: string; limit: number; windowSeconds: number }> {
  const policies: Array<{ kind: string; value: string; limit: number; windowSeconds: number }> = [
    { kind: "phone", value: input.phone, limit: 5, windowSeconds: 900 },
  ];
  if (input.userId) policies.push({ kind: "account", value: input.userId, limit: 10, windowSeconds: 900 });
  if (input.ip) policies.push({ kind: "ip", value: input.ip, limit: 30, windowSeconds: 900 });
  if (input.deviceId) policies.push({ kind: "device", value: input.deviceId, limit: 12, windowSeconds: 900 });
  return policies;
}

export async function checkoutRateLimitBucket(secret: string, kind: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC", key, new TextEncoder().encode(`boui-checkout:${kind}:${value}`),
  );
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
