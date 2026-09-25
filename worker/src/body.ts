import { errorResponse } from "./http";

export const MAX_BODY_BYTES = 5 * 1024 * 1024;

/** Thrown by validators; becomes a 400 `invalid_request` with this message. */
export class InvalidRequest extends Error {}

type JsonHandler<T> = (input: T, env: Env) => Promise<Response>;

/**
 * Wraps a handler that takes a JSON body: enforces the size cap, parses, and
 * runs `validate` before `handle` sees anything.
 */
export function withJsonBody<T>(
  validate: (body: unknown) => T,
  handle: JsonHandler<T>,
): (request: Request, env: Env) => Promise<Response> {
  return async (request, env) => {
    const text = await readBody(request);
    if (text === null) {
      return errorResponse(413, "payload_too_large", `Request body exceeds ${MAX_BODY_BYTES} bytes`);
    }

    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return errorResponse(400, "invalid_json", "Request body is not valid JSON");
    }

    let input: T;
    try {
      input = validate(body);
    } catch (err) {
      if (err instanceof InvalidRequest) {
        return errorResponse(400, "invalid_request", err.message);
      }
      throw err;
    }
    return handle(input, env);
  };
}

/** Returns the body as text, or null if it exceeds MAX_BODY_BYTES. */
async function readBody(request: Request): Promise<string | null> {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && Number(declared) > MAX_BODY_BYTES) return null;
  if (request.body === null) return "";

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
