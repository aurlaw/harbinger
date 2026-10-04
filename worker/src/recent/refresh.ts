import { TmdbError, expectObject, tmdbGet } from "../tmdb/client";
import { HORROR_GENRE_ID } from "../tmdb/movie";
import { RECENT_RELEASES_JOB, type RecentRelease, loadJobState, recordJobFailure, replaceRecentReleases } from "./store";

// The weekly recent-releases job: one TMDB discover fetch (two pages) replaces
// the list in D1. The list is only ever replaced by a successful, non-empty
// fetch — a failure leaves it exactly as it was.

/** Fridays 20:00 UTC; must match `triggers.crons` in wrangler.jsonc. */
export const RECENT_RELEASES_CRON = "0 20 * * 5";

const DISCOVER_PATH = "/discover/movie";
const PAGES = [1, 2];
const WINDOW_MONTHS = 18;
const STALE_AFTER_MS = 8 * 24 * 60 * 60 * 1000;

export type RefreshResult = { ok: true; count: number; last_success_at: string } | { ok: false; error: string };

const day = (date: Date) => date.toISOString().slice(0, 10);

/** `months` before `now` (UTC), clamped to the month's last day: 2026-08-31 → 2025-02-28. */
export function monthsBefore(now: Date, months: number): string {
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth() - months;
  const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return day(new Date(Date.UTC(year, month, Math.min(now.getUTCDate(), lastDay))));
}

interface TmdbDiscoverMovie {
  id?: unknown;
  title?: unknown;
  release_date?: unknown;
  overview?: unknown;
  genre_ids?: unknown;
  popularity?: unknown;
}

/** De-duplicates by tmdb_id across pages (TMDB pagination can shift between calls) and ranks 1..n. */
function toRecentReleases(pages: unknown[]): RecentRelease[] {
  const seen = new Set<number>();
  const releases: RecentRelease[] = [];
  for (const page of pages) {
    const body = expectObject(page, DISCOVER_PATH);
    const results = Array.isArray(body.results) ? (body.results as TmdbDiscoverMovie[]) : [];
    for (const raw of results) {
      if (typeof raw?.id !== "number" || !Number.isInteger(raw.id)) continue;
      if (typeof raw.title !== "string" || raw.title.length === 0) continue;
      if (seen.has(raw.id)) continue;
      seen.add(raw.id);
      const date = typeof raw.release_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(raw.release_date) ? raw.release_date : null;
      const genreIds = Array.isArray(raw.genre_ids) ? raw.genre_ids.filter((g) => Number.isInteger(g)) : [];
      releases.push({
        tmdb_id: raw.id,
        title: raw.title,
        release_date: date,
        year: date === null ? null : Number(date.slice(0, 4)),
        overview: typeof raw.overview === "string" ? raw.overview : "",
        genre_ids: JSON.stringify(genreIds),
        popularity: typeof raw.popularity === "number" ? raw.popularity : 0,
        rank: releases.length + 1,
      });
    }
  }
  return releases;
}

/**
 * Refreshes the list as of `now`. Never throws: every failure is logged,
 * recorded in job_state.last_error, and returned.
 */
export async function refreshRecentReleases(env: Env, now: Date): Promise<RefreshResult> {
  const from = monthsBefore(now, WINDOW_MONTHS);
  const to = day(now);
  const at = now.toISOString();
  const summary = (outcome: string, extra: Record<string, unknown>) =>
    console.log(JSON.stringify({ event: "recent_releases_refresh", outcome, from, to, ...extra }));

  try {
    const pages = await Promise.all(
      PAGES.map((page) =>
        tmdbGet(env, DISCOVER_PATH, {
          with_genres: String(HORROR_GENRE_ID),
          "primary_release_date.gte": from,
          "primary_release_date.lte": to,
          sort_by: "popularity.desc",
          "vote_count.gte": "25",
          "with_runtime.gte": "60",
          include_adult: "false",
          include_video: "false",
          page: String(page),
        }),
      ),
    );
    const releases = toRecentReleases(pages);
    if (releases.length === 0) throw new EmptyResult();

    await replaceRecentReleases(env.DB, releases, at);
    summary("success", { count: releases.length });
    return { ok: true, count: releases.length, last_success_at: at };
  } catch (err) {
    const error = err instanceof EmptyResult ? "empty result" : err instanceof TmdbError ? err.code : "internal error";
    if (error === "internal error") console.error("recent releases refresh failed", err);
    try {
      await recordJobFailure(env.DB, RECENT_RELEASES_JOB, error, at);
    } catch (dbErr) {
      console.error("recent releases: could not record the failure", dbErr);
    }
    summary("failure", { count: 0, error });
    return { ok: false, error };
  }
}

class EmptyResult extends Error {}

/**
 * Stale fallback for the conversation flow: refreshes inline when the last
 * success is missing or older than 8 days. At most one attempt, and it never
 * throws — the turn continues with whatever list exists.
 */
export async function refreshRecentReleasesIfStale(env: Env, now: Date): Promise<void> {
  try {
    const state = await loadJobState(env.DB, RECENT_RELEASES_JOB);
    const last = state?.last_success_at ? Date.parse(state.last_success_at) : Number.NaN;
    if (now.getTime() - last <= STALE_AFTER_MS) return;
  } catch (err) {
    console.error("recent releases: could not read job state", err);
    return;
  }
  await refreshRecentReleases(env, now);
}
