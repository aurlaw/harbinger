const BASE_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
} as const;

export function json(status: number, body: unknown, headers?: HeadersInit): Response {
  const merged = new Headers(BASE_HEADERS);
  if (headers) {
    new Headers(headers).forEach((value, name) => merged.set(name, value));
  }
  return new Response(JSON.stringify(body), { status, headers: merged });
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
  headers?: HeadersInit,
): Response {
  return json(status, { error: { code, message } }, headers);
}
