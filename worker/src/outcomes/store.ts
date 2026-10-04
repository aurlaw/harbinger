// Pick outcomes: films Harbinger recommended (pick_log) that have since been
// rated. Ratings change only on import, so outcomes change only on import.

/** A rating at or above this (half-stars; 7 = ★3.5) is a hit. */
export const HIT_THRESHOLD_HALF_STARS = 7;

export const isHit = (halfStars: number) => halfStars >= HIT_THRESHOLD_HALF_STARS;

// Any logged film counts, whatever its decision. No date check: a film already
// rated could never have been recommended, so its rating came after the pick.
export const OUTCOME_JOIN = `
  FROM pick_log p
  JOIN films f   ON f.tmdb_id = p.tmdb_id
  JOIN ratings r ON r.letterboxd_uri = f.letterboxd_uri`;

/** Most recent first; total, so the same state always yields the same order. */
export const MOST_RECENT_FIRST = "ORDER BY p.first_recommended_at DESC, p.tmdb_id, f.letterboxd_uri";
