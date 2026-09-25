import { errorResponse } from "../http";

/** Columns returned for a film by GET /library/films and PUT /library/films/override. */
export const FILM_COLUMNS = "letterboxd_uri, name, year, tmdb_id, match_status, is_horror, genre_override";

export interface Film {
  letterboxd_uri: string;
  name: string;
  year: number;
  tmdb_id: number | null;
  match_status: string;
  is_horror: number | null;
  genre_override: string | null;
}

/** Returns the URIs not present in `films`, using one statement regardless of count. */
export async function unknownUris(db: D1Database, uris: string[]): Promise<string[]> {
  const { results } = await db
    .prepare("SELECT value FROM json_each(?) WHERE value NOT IN (SELECT letterboxd_uri FROM films)")
    .bind(JSON.stringify(uris))
    .all<{ value: string }>();
  return results.map((r) => r.value);
}

export function unknownFilmsResponse(uris: string[]): Response {
  const shown = uris.slice(0, 10).join(", ");
  const more = uris.length > 10 ? ` (and ${uris.length - 10} more)` : "";
  return errorResponse(422, "unknown_films", `Unknown Letterboxd URIs: ${shown}${more}`);
}
