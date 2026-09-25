import { errorResponse } from "./http";

const encoder = new TextEncoder();

/**
 * Gate for every request. Returns a response to send (500 or 401) when the
 * request must not proceed, or null when it is authenticated.
 */
export function authenticate(request: Request, env: Env): Response | null {
  const expected = env.API_KEY;
  if (!expected) {
    // Fail closed: a missing secret must never let requests through.
    console.error("API_KEY is not configured");
    return errorResponse(500, "internal_error", "Internal server error");
  }

  const token = bearerToken(request.headers.get("Authorization"));
  if (token === null || !timingSafeEqualStrings(token, expected)) {
    return errorResponse(401, "unauthorized", "Missing or invalid API key");
  }
  return null;
}

function bearerToken(header: string | null): string | null {
  if (header === null) return null;
  const match = /^Bearer +(.+)$/i.exec(header);
  return match?.[1] ?? null;
}

// Per Cloudflare's timing-attack guidance: never return early on a length
// mismatch; compare the input against itself and negate instead.
function timingSafeEqualStrings(provided: string, expected: string): boolean {
  const a = encoder.encode(provided);
  const b = encoder.encode(expected);
  if (a.byteLength !== b.byteLength) {
    return !crypto.subtle.timingSafeEqual(a, a);
  }
  return crypto.subtle.timingSafeEqual(a, b);
}
