// D1 access for the recent-releases list and the generic job_state table.

export const RECENT_RELEASES_JOB = "recent_releases";

export interface RecentRelease {
  tmdb_id: number;
  title: string;
  /** YYYY-MM-DD, or null when TMDB has no date. */
  release_date: string | null;
  year: number | null;
  overview: string;
  /** JSON array text, exactly as stored. */
  genre_ids: string;
  popularity: number;
  /** 1..n in TMDB popularity order. */
  rank: number;
}

export interface JobState {
  last_success_at: string | null;
  last_error: string | null;
  updated_at: string;
}

export function loadJobState(db: D1Database, name: string): Promise<JobState | null> {
  return db
    .prepare("SELECT last_success_at, last_error, updated_at FROM job_state WHERE name = ?")
    .bind(name)
    .first<JobState>();
}

const INSERT_RELEASES = `
  INSERT INTO recent_releases (tmdb_id, title, release_date, year, overview, genre_ids, popularity, rank)
  SELECT json_extract(value, '$.tmdb_id'), json_extract(value, '$.title'), json_extract(value, '$.release_date'),
         json_extract(value, '$.year'), json_extract(value, '$.overview'), json_extract(value, '$.genre_ids'),
         json_extract(value, '$.popularity'), json_extract(value, '$.rank')
  FROM json_each(?)`;

const RECORD_SUCCESS = `
  INSERT INTO job_state (name, last_success_at, last_error, updated_at) VALUES (?1, ?2, NULL, ?2)
  ON CONFLICT(name) DO UPDATE SET last_success_at = excluded.last_success_at, last_error = NULL,
                                  updated_at = excluded.updated_at`;

// last_success_at is left alone on conflict: a failure never hides the last good run.
const RECORD_FAILURE = `
  INSERT INTO job_state (name, last_success_at, last_error, updated_at) VALUES (?1, NULL, ?2, ?3)
  ON CONFLICT(name) DO UPDATE SET last_error = excluded.last_error, updated_at = excluded.updated_at`;

/** Replaces the whole list and records the success, atomically. */
export async function replaceRecentReleases(db: D1Database, releases: RecentRelease[], now: string): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM recent_releases"),
    db.prepare(INSERT_RELEASES).bind(JSON.stringify(releases)),
    db.prepare(RECORD_SUCCESS).bind(RECENT_RELEASES_JOB, now),
  ]);
}

export async function recordJobFailure(db: D1Database, name: string, error: string, now: string): Promise<void> {
  await db.prepare(RECORD_FAILURE).bind(name, error, now).run();
}
