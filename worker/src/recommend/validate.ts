import { normalizeTitle } from "./normalize";
import type { ResolvedPick } from "./resolve";

// The exclusion set and per-pick checks. Every pick that reaches the app is
// horror, feature-length, unseen, not on the watchlist, not already decided,
// and not already shown in this conversation.

export type RejectReason = "not_horror" | "not_feature" | "excluded" | "duplicate" | "unresolved" | "invalid";

/** Shorter than this (minutes) is not a feature. Unknown runtime passes. */
export const MIN_FEATURE_RUNTIME = 40;

export interface ExclusionSet {
  tmdbIds: Set<number>;
  /** Watched / watchlist films with no tmdb_id, as normalized name + year. */
  unmatched: { title: string; year: number }[];
}

// Global: watched or watchlist (any genre), plus yes / no decisions.
const GLOBAL_IDS = `
  SELECT tmdb_id FROM films
   WHERE tmdb_id IS NOT NULL
     AND letterboxd_uri IN (SELECT letterboxd_uri FROM watched
                            UNION SELECT letterboxd_uri FROM watchlist)
  UNION
  SELECT tmdb_id FROM decisions WHERE decision IN ('yes','no')`;

// This conversation: its maybe decisions and everything already shown in it.
const CONVERSATION_IDS = `
  SELECT tmdb_id FROM decisions WHERE decision = 'maybe' AND conversation_id = ?1
  UNION
  SELECT tmdb_id FROM recommendations WHERE conversation_id = ?1`;

// Library films that can't be excluded by id (ambiguous / unmatched).
const UNMATCHED = `
  SELECT name, year FROM films
   WHERE tmdb_id IS NULL
     AND letterboxd_uri IN (SELECT letterboxd_uri FROM watched
                            UNION SELECT letterboxd_uri FROM watchlist)`;

/**
 * Loads the exclusion set once per request. `conversationId` is null for a
 * brand-new conversation, whose conversation-scoped parts are empty.
 */
export async function loadExclusionSet(db: D1Database, conversationId: string | null): Promise<ExclusionSet> {
  const statements = [db.prepare(GLOBAL_IDS), db.prepare(UNMATCHED)];
  if (conversationId !== null) statements.push(db.prepare(CONVERSATION_IDS).bind(conversationId));
  const [global, unmatched, conversation] = await db.batch(statements);

  const ids = [...(global?.results ?? []), ...(conversation?.results ?? [])] as { tmdb_id: number }[];
  return {
    tmdbIds: new Set(ids.map((r) => r.tmdb_id)),
    unmatched: ((unmatched?.results ?? []) as { name: string; year: number }[]).map((f) => ({
      title: normalizeTitle(f.name),
      year: f.year,
    })),
  };
}

function isExcluded(pick: ResolvedPick, exclusions: ExclusionSet): boolean {
  if (exclusions.tmdbIds.has(pick.tmdb_id)) return true;
  if (pick.year === null) return false;
  const titles = [normalizeTitle(pick.details.title), normalizeTitle(pick.details.original_title)];
  return exclusions.unmatched.some(
    (f) => titles.includes(f.title) && Math.abs(f.year - (pick.year as number)) <= 1,
  );
}

/**
 * Returns the first failing reason for a resolved pick, or null to accept it.
 * `accepted` / `rejected` are the tmdb_ids seen so far in this request: a pick
 * matching an earlier rejection is a duplicate (Claude repeated it), and so is
 * a second pick of an already-accepted film.
 */
export function checkPick(
  pick: ResolvedPick,
  exclusions: ExclusionSet,
  seen: { accepted: Set<number>; rejected: Set<number> },
): RejectReason | null {
  if (seen.rejected.has(pick.tmdb_id)) return "duplicate";
  if (!pick.details.is_horror) return "not_horror";
  if (pick.details.runtime !== null && pick.details.runtime < MIN_FEATURE_RUNTIME) return "not_feature";
  if (isExcluded(pick, exclusions)) return "excluded";
  if (seen.accepted.has(pick.tmdb_id)) return "duplicate";
  return null;
}
