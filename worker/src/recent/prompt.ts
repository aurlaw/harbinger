// The "Recent releases" section of the recommendation system prompt.

export interface RecentReleaseLine {
  title: string;
  year: number | null;
  overview: string;
}

// Library films (watched / watchlist) are left out. Decisions are deliberately
// NOT filtered: a Yes / No mid-conversation would change the system prompt and
// break the prompt cache; pick validation already rejects decided films.
export const RECENT_RELEASES = `
  SELECT title, year, overview
  FROM recent_releases
  WHERE tmdb_id NOT IN (SELECT tmdb_id FROM films
                         WHERE tmdb_id IS NOT NULL
                           AND letterboxd_uri IN (SELECT letterboxd_uri FROM watched
                                                  UNION SELECT letterboxd_uri FROM watchlist))
  ORDER BY rank, tmdb_id`;

const OVERVIEW_LENGTH = 200;

/** One line, cut at a word boundary near 200 characters (code points). */
export function truncateOverview(overview: string): string {
  const chars = [...overview.replace(/\s+/g, " ").trim()];
  if (chars.length <= OVERVIEW_LENGTH) return chars.join("");
  // Include one extra character so a space right after the 200th counts as a boundary.
  const head = chars.slice(0, OVERVIEW_LENGTH + 1);
  const space = head.lastIndexOf(" ");
  return `${(space > 0 ? head.slice(0, space) : head.slice(0, OVERVIEW_LENGTH)).join("").trimEnd()}…`;
}

function line(release: RecentReleaseLine): string {
  const name = release.year === null ? release.title : `${release.title} (${release.year})`;
  const overview = truncateOverview(release.overview);
  return overview.length > 0 ? `${name} — ${overview}` : name;
}

export function recentReleasesSection(releases: RecentReleaseLine[]): string {
  return `## Recent releases you may not know (optional candidates)
These horror films came out in the last ~18 months and may be newer than your training data. Recommend one only when it genuinely fits their taste and the request — this is not a list you must use.
${releases.length > 0 ? releases.map(line).join("\n") : "(none)"}`;
}
