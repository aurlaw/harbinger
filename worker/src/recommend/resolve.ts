import { TmdbError, tmdbGet } from "../tmdb/client";
import { type MovieDetails, toMovieDetails } from "../tmdb/movie";
import { type SearchResult, toSearchPage } from "../tmdb/search";
import { normalizeTitle } from "./normalize";
import type { FilmPick } from "./schema";

// Pick → TMDB film, via the W3 client in-process. W4a drops unresolvable picks;
// the horror check, exclusion set, and replacement loop arrive in W4b.

export interface ResolvedPick {
  tmdb_id: number;
  /** From TMDB, not Claude. */
  title: string;
  year: number | null;
  why_short: string;
  why_full: string;
  details: MovieDetails;
}

const releaseYear = (date: string | null) => (date ? Number(date.slice(0, 4)) || null : null);

function matches(result: SearchResult, pick: FilmPick): boolean {
  const title = normalizeTitle(pick.title);
  const year = releaseYear(result.release_date);
  return (
    (normalizeTitle(result.title) === title || normalizeTitle(result.original_title) === title) &&
    year !== null &&
    Math.abs(year - pick.year) <= 1
  );
}

async function search(env: Env, pick: FilmPick): Promise<SearchResult | null> {
  // Primary release year first, then TMDB's looser `year` filter.
  for (const yearParam of ["primary_release_year", "year"]) {
    const page = toSearchPage(
      await tmdbGet(env, "/search/movie", { query: pick.title, include_adult: "false", [yearParam]: String(pick.year) }),
    );
    const hit = page.results.find((r) => matches(r, pick));
    if (hit) return hit;
  }
  return null;
}

/** Resolves one pick, or null when TMDB has no matching film. TMDB outages throw TmdbError. */
export async function resolvePick(env: Env, pick: FilmPick): Promise<ResolvedPick | null> {
  const hit = await search(env, pick);
  if (!hit) return null;

  let details: MovieDetails;
  try {
    details = toMovieDetails(await tmdbGet(env, `/movie/${hit.tmdb_id}`));
  } catch (err) {
    // Listed in search but gone from details: treat as unresolvable.
    if (err instanceof TmdbError && err.code === "not_found") return null;
    throw err;
  }
  return {
    tmdb_id: details.tmdb_id,
    title: details.title,
    year: releaseYear(details.release_date) ?? releaseYear(hit.release_date),
    why_short: pick.why_short,
    why_full: pick.why_full,
    details,
  };
}

/** Resolves picks concurrently, keeping Claude's order; unresolved picks are dropped. */
export async function resolvePicks(env: Env, picks: FilmPick[]): Promise<{ resolved: ResolvedPick[]; unresolved: number }> {
  const results = await Promise.all(picks.map((pick) => resolvePick(env, pick)));
  const resolved = results.filter((r): r is ResolvedPick => r !== null);
  return { resolved, unresolved: picks.length - resolved.length };
}
