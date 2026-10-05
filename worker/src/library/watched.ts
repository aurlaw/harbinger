import { json } from "../http";

// GET /library/watched — every watched film (all genres) for the app's Watched
// screen, cross-referenced here so the app only renders rows. Read-only.

// One row per `watched` row: `ratings` and `pick_log` are keyed by the join
// columns, so the LEFT JOINs never multiply. Horror uses the `horror_films`
// view (override wins, else TMDB genre) rather than re-implementing its rule.
// The poster is the TMDB details the CLI stored at match time — no TMDB calls.
const WATCHED = `
  SELECT f.letterboxd_uri, f.tmdb_id, f.name AS title, f.year, r.half_stars, w.logged_on,
         json_extract(f.tmdb_json, '$.poster_path') AS poster_path,
         f.letterboxd_uri IN (SELECT letterboxd_uri FROM horror_films) AS is_horror,
         p.tmdb_id IS NOT NULL AS harbinger_pick,
         p.first_recommended_at
  FROM watched w
  JOIN films f ON f.letterboxd_uri = w.letterboxd_uri
  LEFT JOIN ratings r ON r.letterboxd_uri = w.letterboxd_uri
  LEFT JOIN pick_log p ON p.tmdb_id = f.tmdb_id
  ORDER BY w.logged_on DESC, f.name, f.letterboxd_uri`;

const LAST_IMPORT = "SELECT imported_at FROM imports ORDER BY id DESC LIMIT 1";

interface WatchedRow {
  letterboxd_uri: string;
  tmdb_id: number | null;
  title: string;
  year: number;
  half_stars: number | null;
  /** The date it was marked watched on Letterboxd — not a viewing date. */
  logged_on: string | null;
  poster_path: string | null;
  is_horror: number;
  harbinger_pick: number;
  first_recommended_at: string | null;
}

export async function listWatched(_request: Request, env: Env): Promise<Response> {
  const [watched, lastImport] = await env.DB.batch([env.DB.prepare(WATCHED), env.DB.prepare(LAST_IMPORT)]);
  return json(200, {
    last_import_at: (lastImport?.results[0] as { imported_at: string } | undefined)?.imported_at ?? null,
    films: ((watched?.results ?? []) as WatchedRow[]).map((row) => ({
      letterboxd_uri: row.letterboxd_uri,
      tmdb_id: row.tmdb_id,
      title: row.title,
      year: row.year,
      half_stars: row.half_stars,
      logged_on: row.logged_on,
      // A stored poster_path that isn't a string (absent, or JSON null) reads as none.
      poster_path: typeof row.poster_path === "string" ? row.poster_path : null,
      // SQLite has no booleans; never return 0 / 1.
      is_horror: row.is_horror === 1,
      harbinger_pick: row.harbinger_pick === 1,
      first_recommended_at: row.first_recommended_at,
    })),
  });
}
