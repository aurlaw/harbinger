import { env } from "cloudflare:workers";
import { vi } from "vitest";
import { clearLibrary } from "./helpers";

// A fake outside world for conversation tests: Anthropic replies come from a
// queue, TMDB answers from a small in-memory catalog. Any other URL throws.

export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const TMDB = "https://api.themoviedb.org/3";

export interface CatalogFilm {
  id: number;
  title: string;
  original_title?: string;
  release_date: string;
  /** Other release years TMDB's `year` filter matches (not `primary_release_year`). */
  other_years?: number[];
  genres?: { id: number; name: string }[];
  runtime?: number;
  poster_path?: string;
  overview?: string;
  /** Sections returned with append_to_response (credits, videos, "watch/providers"); replaces the empty defaults. */
  appended?: Record<string, unknown>;
}

export interface ClaudeCall {
  body: {
    model: string;
    max_tokens: number;
    system: string;
    messages: { role: string; content: string }[];
    output_config: unknown;
    cache_control: unknown;
  };
  headers: Headers;
}

/**
 * A thunk, not a Response: workerd forbids reading a body created in another
 * request's context, so replies are built when the Worker asks for them.
 */
export type ClaudeReply = () => Response | Promise<Response>;

export const HORROR = { id: 27, name: "Horror" };

export function film(id: number, title: string, year: number, extra: Partial<CatalogFilm> = {}): CatalogFilm {
  return {
    id,
    title,
    release_date: `${year}-06-01`,
    genres: [HORROR],
    runtime: 90 + (id % 30),
    poster_path: `/p${id}.jpg`,
    overview: `Overview of ${title}.`,
    ...extra,
  };
}

const loose = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
const yearOf = (f: CatalogFilm) => Number(f.release_date.slice(0, 4));

export interface World {
  claudeCalls: ClaudeCall[];
  tmdbCalls: URL[];
  unexpected: string[];
  replies: ClaudeReply[];
  /** When set, every TMDB request returns this status. */
  tmdbStatus?: number;
}

export function mockWorld(catalog: CatalogFilm[], replies: ClaudeReply[]): World {
  const world: World = { claudeCalls: [], tmdbCalls: [], unexpected: [], replies: [...replies] };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const path = `${url.origin}${url.pathname}`;

    if (path === ANTHROPIC_URL) {
      world.claudeCalls.push({ body: JSON.parse(String(init?.body)), headers: new Headers(init?.headers) });
      const reply = world.replies.shift();
      if (!reply) throw new Error("no Claude reply queued");
      return reply();
    }

    if (path.startsWith(TMDB)) {
      world.tmdbCalls.push(url);
      if (world.tmdbStatus) return new Response("{}", { status: world.tmdbStatus });
      if (path === `${TMDB}/search/movie`) {
        const query = loose(url.searchParams.get("query") ?? "");
        const primary = url.searchParams.get("primary_release_year");
        const year = url.searchParams.get("year");
        const results = catalog
          .filter((f) => loose(f.title).includes(query) || loose(f.original_title ?? f.title).includes(query))
          .filter((f) => !primary || yearOf(f) === Number(primary))
          .filter((f) => !year || yearOf(f) === Number(year) || (f.other_years ?? []).includes(Number(year)))
          .map((f) => ({
            id: f.id,
            title: f.title,
            original_title: f.original_title ?? f.title,
            release_date: f.release_date,
            genre_ids: (f.genres ?? []).map((g) => g.id),
            overview: f.overview ?? "",
            popularity: 1,
            poster_path: f.poster_path ?? null,
          }));
        return jsonResponse({ page: 1, results, total_pages: 1, total_results: results.length });
      }
      const detail = /^\/3\/movie\/(\d+)$/.exec(url.pathname);
      const found = detail && catalog.find((f) => f.id === Number(detail[1]));
      if (found) {
        return jsonResponse({
          id: found.id,
          title: found.title,
          original_title: found.original_title ?? found.title,
          release_date: found.release_date,
          genres: found.genres ?? [],
          runtime: found.runtime ?? null,
          overview: found.overview ?? "",
          poster_path: found.poster_path ?? null,
          budget: 1,
          tagline: "extra field",
          ...(url.searchParams.has("append_to_response")
            ? (found.appended ?? { credits: { cast: [], crew: [] }, videos: { results: [] }, "watch/providers": { results: {} } })
            : {}),
        });
      }
      if (detail) return new Response("{}", { status: 404 });
    }

    world.unexpected.push(url.href);
    throw new Error(`unexpected fetch: ${url.href}`);
  });
  return world;
}

export const jsonResponse = (body: unknown, init: ResponseInit = {}) =>
  new Response(JSON.stringify(body), { ...init, headers: { "Content-Type": "application/json", ...init.headers } });

export const USAGE = {
  input_tokens: 120,
  cache_creation_input_tokens: 0,
  cache_read_input_tokens: 4800,
  output_tokens: 300,
};

/** A successful Messages API response carrying `output` as the structured JSON text block. */
export function claudeReply(output: unknown, stopReason = "end_turn"): ClaudeReply {
  return () => jsonResponse({
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-sonnet-5",
    // Adaptive thinking puts a thinking block before the text block.
    content: [
      { type: "thinking", thinking: "", signature: "sig" },
      { type: "text", text: typeof output === "string" ? output : JSON.stringify(output) },
    ],
    stop_reason: stopReason,
    stop_sequence: null,
    usage: USAGE,
  });
}

/** A non-2xx Anthropic reply. */
export const claudeStatus = (status: number, body: unknown = {}, headers: HeadersInit = {}): ClaudeReply => () =>
  jsonResponse(body, { status, headers });

export const question = (text: string, chips: string[] = []) => ({ kind: "question", question: text, chips, picks: [] });

export const pick = (title: string, year: number) => ({
  title,
  year,
  why_short: `Short why for ${title}.`,
  why_full: `Full why for ${title}. Relates to Hereditary.`,
});

export const recs = (...picks: unknown[]) => ({ kind: "recommendations", question: "", chips: [], picks });

/** Each conversation-test file starts from empty tables. */
export async function clearAll(): Promise<void> {
  await env.DB.batch(
    ["decisions", "recommendations", "messages", "conversations"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)),
  );
  await clearLibrary();
}

interface SeedFilm {
  name: string;
  year: number;
  /** Defaults to a unique id far from test catalogs; null = unmatched. */
  tmdb_id?: number | null;
  horror?: boolean;
  half_stars?: number;
  watched?: boolean;
  watchlist?: boolean;
}

/** Seeds films + snapshots with a fixed number of statements (json_each). */
export async function seedLibrary(films: SeedFilm[]): Promise<void> {
  const rows = films.map((f, i) => ({ ...f, uri: `https://boxd.it/s${i}`, horror: f.horror ? 1 : 0 }));
  const payload = JSON.stringify(rows);
  const now = "2026-09-26T00:00:00.000Z";
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO films (letterboxd_uri, name, year, tmdb_id, match_status, is_horror, created_at)
       SELECT json_extract(value, '$.uri'), json_extract(value, '$.name'), json_extract(value, '$.year'),
              CASE json_type(value, '$.tmdb_id')
                WHEN 'null' THEN NULL
                WHEN 'integer' THEN json_extract(value, '$.tmdb_id')
                ELSE key + 100001
              END,
              CASE json_type(value, '$.tmdb_id') WHEN 'null' THEN 'unmatched' ELSE 'matched' END,
              json_extract(value, '$.horror'), ?
       FROM json_each(?)`,
    ).bind(now, payload),
    env.DB.prepare(
      `INSERT INTO ratings (letterboxd_uri, half_stars)
       SELECT json_extract(value, '$.uri'), json_extract(value, '$.half_stars')
       FROM json_each(?) WHERE json_extract(value, '$.half_stars') IS NOT NULL`,
    ).bind(payload),
    env.DB.prepare(
      `INSERT INTO watched (letterboxd_uri)
       SELECT json_extract(value, '$.uri') FROM json_each(?) WHERE json_extract(value, '$.watched')`,
    ).bind(payload),
    env.DB.prepare(
      `INSERT INTO watchlist (letterboxd_uri)
       SELECT json_extract(value, '$.uri') FROM json_each(?) WHERE json_extract(value, '$.watchlist')`,
    ).bind(payload),
  ]);
}
