import { errorResponse } from "../http";

// The only code that talks to TMDB. W4 reuses tmdbGet for recommendation validation.

const BASE_URL = "https://api.themoviedb.org/3";
const TIMEOUT_MS = 10_000;

/** A TMDB failure already mapped to the harbinger error it becomes. */
export class TmdbError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers?: HeadersInit,
  ) {
    super(message);
  }

  toResponse(): Response {
    return errorResponse(this.status, this.code, this.message, this.headers);
  }
}

const unavailable = () => new TmdbError(502, "tmdb_unavailable", "TMDB is unavailable");

/**
 * GETs `path` (fixed by the caller, e.g. `/search/movie`) with `params` and
 * returns the parsed JSON body. Throws TmdbError on any failure; TMDB's own
 * body and status text are never forwarded.
 */
export async function tmdbGet(env: Env, path: string, params: Record<string, string> = {}): Promise<unknown> {
  const token = env.TMDB_READ_TOKEN;
  if (!token) {
    // Fail closed without making an outbound request.
    console.error("TMDB_READ_TOKEN is not configured");
    throw new TmdbError(500, "internal_error", "Internal server error");
  }

  const url = new URL(`${BASE_URL}${path}`);
  url.searchParams.set("language", "en-US");
  for (const [name, value] of Object.entries(params)) url.searchParams.set(name, value);

  let res: Response;
  try {
    res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    console.error(`TMDB ${path}: request failed`, err);
    throw unavailable();
  }

  if (!res.ok) {
    await res.body?.cancel();
    if (res.status === 404) throw new TmdbError(404, "not_found", "Not found");
    if (res.status === 401 || res.status === 403) {
      console.error("TMDB auth failed; check TMDB_READ_TOKEN");
      throw unavailable();
    }
    if (res.status === 429) {
      const retryAfter = res.headers.get("Retry-After");
      throw new TmdbError(
        503,
        "tmdb_rate_limited",
        "TMDB rate limit reached",
        retryAfter ? { "Retry-After": retryAfter } : undefined,
      );
    }
    console.error(`TMDB ${path}: unexpected status ${res.status}`);
    throw unavailable();
  }

  try {
    return await res.json();
  } catch (err) {
    console.error(`TMDB ${path}: response body is not JSON`, err);
    throw unavailable();
  }
}

/** Runs a TMDB-backed handler body, turning TmdbError into its response. */
export async function withTmdbErrors(run: () => Promise<Response>): Promise<Response> {
  try {
    return await run();
  } catch (err) {
    if (err instanceof TmdbError) return err.toResponse();
    throw err;
  }
}

/** Guards against a 200 whose JSON isn't the shape we map from. */
export function expectObject(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    console.error(`TMDB ${path}: unexpected response shape`);
    throw unavailable();
  }
  return value as Record<string, unknown>;
}
