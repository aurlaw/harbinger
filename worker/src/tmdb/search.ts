import { InvalidRequest } from "../body";
import { errorResponse, json } from "../http";
import { expectObject, tmdbGet, withTmdbErrors } from "./client";

// GET /tmdb/search — thin 1:1 proxy to TMDB /search/movie. Year fallback belongs to the CLI.

interface TmdbSearchMovie {
  id: number;
  title: string;
  original_title: string;
  release_date?: string;
  genre_ids?: number[];
  overview: string;
  popularity: number;
  poster_path?: string | null;
}

export interface SearchResult {
  tmdb_id: number;
  title: string;
  original_title: string;
  release_date: string | null;
  genre_ids: number[];
  overview: string;
  popularity: number;
  poster_path: string | null;
}

export interface SearchPage {
  page: number;
  total_pages: number;
  total_results: number;
  results: SearchResult[];
}

export function toSearchResult(raw: TmdbSearchMovie): SearchResult {
  return {
    tmdb_id: raw.id,
    title: raw.title,
    original_title: raw.original_title,
    release_date: raw.release_date || null,
    genre_ids: raw.genre_ids ?? [],
    overview: raw.overview,
    popularity: raw.popularity,
    poster_path: raw.poster_path ?? null,
  };
}

export function toSearchPage(raw: unknown): SearchPage {
  const body = expectObject(raw, "/search/movie");
  const results = Array.isArray(body.results) ? (body.results as TmdbSearchMovie[]) : [];
  return {
    page: body.page as number,
    total_pages: body.total_pages as number,
    total_results: body.total_results as number,
    results: results.map(toSearchResult),
  };
}

const MAX_QUERY_LENGTH = 200;

/** Validates the query string and returns only the TMDB params that were supplied. */
function searchParams(query: URLSearchParams): Record<string, string> {
  const title = query.get("query")?.trim() ?? "";
  if (title.length === 0 || title.length > MAX_QUERY_LENGTH) {
    throw new InvalidRequest(`query must be a non-empty string of at most ${MAX_QUERY_LENGTH} characters`);
  }

  const params: Record<string, string> = { query: title, include_adult: "false" };
  const ranges: [string, number, number][] = [
    ["primary_release_year", 1870, 2100],
    ["year", 1870, 2100],
    ["page", 1, 10],
  ];
  for (const [name, min, max] of ranges) {
    const value = query.get(name);
    if (value === null) continue;
    const n = /^\d+$/.test(value) ? Number(value) : NaN;
    if (!(n >= min && n <= max)) {
      throw new InvalidRequest(`${name} must be an integer between ${min} and ${max}`);
    }
    params[name] = String(n);
  }
  return params;
}

export async function searchMovies(request: Request, env: Env): Promise<Response> {
  let params: Record<string, string>;
  try {
    params = searchParams(new URL(request.url).searchParams);
  } catch (err) {
    if (err instanceof InvalidRequest) return errorResponse(400, "invalid_request", err.message);
    throw err;
  }
  return withTmdbErrors(async () => json(200, toSearchPage(await tmdbGet(env, "/search/movie", params))));
}
