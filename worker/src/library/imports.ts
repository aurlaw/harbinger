import { withJsonBody } from "../body";
import { errorResponse, json } from "../http";
import { boolean, integer, isoDate, letterboxdUri, nonEmptyString, object, uniqueItems } from "../validate";
import { unknownFilmsResponse, unknownUris } from "./shared";

// POST /library/import

export interface ImportInput {
  source_filename: string;
  force: boolean;
  ratings: { letterboxd_uri: string; half_stars: number; rated_on: string }[];
  watched: { letterboxd_uri: string; logged_on: string }[];
  watchlist: { letterboxd_uri: string; added_on: string }[];
  likes: { letterboxd_uri: string }[];
}

const SNAPSHOT_TABLES = ["ratings", "watched", "watchlist", "likes"] as const;

function validateImport(body: unknown): ImportInput {
  const obj = object(body, "body");
  return {
    source_filename: nonEmptyString(obj.source_filename, "source_filename"),
    force: obj.force === undefined ? false : boolean(obj.force, "force"),
    ratings: uniqueItems(obj.ratings, "ratings", (item, path) => ({
      letterboxd_uri: letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`),
      half_stars: integer(item.half_stars, `${path}.half_stars`, 1, 10),
      rated_on: isoDate(item.rated_on, `${path}.rated_on`),
    })),
    watched: uniqueItems(obj.watched, "watched", (item, path) => ({
      letterboxd_uri: letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`),
      logged_on: isoDate(item.logged_on, `${path}.logged_on`),
    })),
    watchlist: uniqueItems(obj.watchlist, "watchlist", (item, path) => ({
      letterboxd_uri: letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`),
      added_on: isoDate(item.added_on, `${path}.added_on`),
    })),
    likes: uniqueItems(obj.likes, "likes", (item, path) => ({
      letterboxd_uri: letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`),
    })),
  };
}

const COUNT_SNAPSHOTS = `
  SELECT (SELECT COUNT(*) FROM ratings)   AS ratings,
         (SELECT COUNT(*) FROM watched)   AS watched,
         (SELECT COUNT(*) FROM watchlist) AS watchlist,
         (SELECT COUNT(*) FROM likes)     AS likes`;

// new_films_count: films first seen after the previous import (all films if none).
// SQLite evaluates the SELECT before inserting, so the subquery sees the previous row.
const INSERT_IMPORT = `
  INSERT INTO imports (imported_at, source_filename, ratings_count, watched_count,
                       watchlist_count, likes_count, new_films_count)
  SELECT ?1, ?2,
         (SELECT COUNT(*) FROM ratings),
         (SELECT COUNT(*) FROM watched),
         (SELECT COUNT(*) FROM watchlist),
         (SELECT COUNT(*) FROM likes),
         (SELECT COUNT(*) FROM films
           WHERE created_at > COALESCE((SELECT imported_at FROM imports ORDER BY id DESC LIMIT 1), ''))
  RETURNING id, ratings_count, watched_count, watchlist_count, likes_count, new_films_count`;

interface ImportRow {
  id: number;
  ratings_count: number;
  watched_count: number;
  watchlist_count: number;
  likes_count: number;
  new_films_count: number;
}

/**
 * Replaces all four snapshot tables and records the import in one atomic
 * batch. Any failure rolls back every statement. Exported for testing.
 */
export async function replaceSnapshots(db: D1Database, input: ImportInput, now: string): Promise<ImportRow> {
  const results = await db.batch<ImportRow>([
    ...SNAPSHOT_TABLES.map((table) => db.prepare(`DELETE FROM ${table}`)),
    db
      .prepare(
        `INSERT INTO ratings (letterboxd_uri, half_stars, rated_on)
         SELECT json_extract(value, '$.letterboxd_uri'), json_extract(value, '$.half_stars'), json_extract(value, '$.rated_on')
         FROM json_each(?)`,
      )
      .bind(JSON.stringify(input.ratings)),
    db
      .prepare(
        `INSERT INTO watched (letterboxd_uri, logged_on)
         SELECT json_extract(value, '$.letterboxd_uri'), json_extract(value, '$.logged_on')
         FROM json_each(?)`,
      )
      .bind(JSON.stringify(input.watched)),
    db
      .prepare(
        `INSERT INTO watchlist (letterboxd_uri, added_on)
         SELECT json_extract(value, '$.letterboxd_uri'), json_extract(value, '$.added_on')
         FROM json_each(?)`,
      )
      .bind(JSON.stringify(input.watchlist)),
    db
      .prepare(`INSERT INTO likes (letterboxd_uri) SELECT json_extract(value, '$.letterboxd_uri') FROM json_each(?)`)
      .bind(JSON.stringify(input.likes)),
    db.prepare(INSERT_IMPORT).bind(now, input.source_filename),
  ]);
  const row = results.at(-1)?.results[0];
  if (!row) throw new Error("imports insert returned no row");
  return row;
}

export const runImport = withJsonBody(validateImport, async (input, env) => {
  const uris = new Set(SNAPSHOT_TABLES.flatMap((table) => input[table].map((item) => item.letterboxd_uri)));
  const unknown = await unknownUris(env.DB, [...uris]);
  if (unknown.length > 0) return unknownFilmsResponse(unknown);

  if (!input.force) {
    const current = await env.DB.prepare(COUNT_SNAPSHOTS).first<Record<(typeof SNAPSHOT_TABLES)[number], number>>();
    const emptied = SNAPSHOT_TABLES.filter((table) => (current?.[table] ?? 0) > 0 && input[table].length === 0);
    if (emptied.length > 0) {
      return errorResponse(
        409,
        "empty_snapshot",
        `Import would empty tables that currently have rows: ${emptied.join(", ")}. Resend with force: true to allow.`,
      );
    }
  }

  const row = await replaceSnapshots(env.DB, input, new Date().toISOString());
  return json(200, {
    import_id: row.id,
    ratings: row.ratings_count,
    watched: row.watched_count,
    watchlist: row.watchlist_count,
    likes: row.likes_count,
    new_films: row.new_films_count,
  });
});

// GET /library/imports/latest

export async function latestImport(_request: Request, env: Env): Promise<Response> {
  const row = await env.DB.prepare("SELECT * FROM imports ORDER BY id DESC LIMIT 1").first();
  if (!row) return errorResponse(404, "no_imports", "No imports yet");
  return json(200, row);
}
