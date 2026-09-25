import { withJsonBody } from "../body";
import { errorResponse, json } from "../http";
import { integer, letterboxdUri, nonEmptyString, object, oneOf, uniqueItems } from "../validate";
import { FILM_COLUMNS, type Film } from "./shared";

// GET /library/films

export async function listFilms(_request: Request, env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(`SELECT ${FILM_COLUMNS} FROM films ORDER BY letterboxd_uri`).all<Film>();
  return json(200, { films: results });
}

// POST /library/films

interface FilmInput {
  letterboxd_uri: string;
  name: string;
  year: number;
}

function validateUpsert(body: unknown): FilmInput[] {
  const obj = object(body, "body");
  return uniqueItems(obj.films, "films", (item, path) => ({
    letterboxd_uri: letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`),
    name: nonEmptyString(item.name, `${path}.name`),
    year: integer(item.year, `${path}.year`, 1, 9999),
  }));
}

// Both statements expand the whole payload from one bound JSON parameter, so
// statement and parameter counts are fixed regardless of payload size.
const INCOMING = `SELECT json_extract(value, '$.letterboxd_uri') AS letterboxd_uri,
                         json_extract(value, '$.name') AS name,
                         json_extract(value, '$.year') AS year
                  FROM json_each(?1)`;

const COUNT_CHANGES = `
  SELECT TOTAL(f.letterboxd_uri IS NULL) AS inserted,
         TOTAL(f.letterboxd_uri IS NOT NULL AND (f.name IS NOT i.name OR f.year IS NOT i.year)) AS updated
  FROM (${INCOMING}) AS i
  LEFT JOIN films AS f ON f.letterboxd_uri = i.letterboxd_uri`;

// `WHERE true` is required: SQLite can't parse ON CONFLICT directly after SELECT ... FROM.
const UPSERT = `
  INSERT INTO films (letterboxd_uri, name, year, match_status, created_at)
  SELECT letterboxd_uri, name, year, 'pending', ?2 FROM (${INCOMING}) WHERE true
  ON CONFLICT (letterboxd_uri) DO UPDATE SET name = excluded.name, year = excluded.year
  WHERE films.name IS NOT excluded.name OR films.year IS NOT excluded.year`;

export const upsertFilms = withJsonBody(validateUpsert, async (films, env) => {
  const payload = JSON.stringify(films);
  const now = new Date().toISOString();
  // One batch = one transaction, so the counts describe exactly what the upsert changed.
  const [counts] = await env.DB.batch<{ inserted: number; updated: number }>([
    env.DB.prepare(COUNT_CHANGES).bind(payload),
    env.DB.prepare(UPSERT).bind(payload, now),
  ]);
  const row = counts?.results[0];
  return json(200, { inserted: row?.inserted ?? 0, updated: row?.updated ?? 0 });
});

// PUT /library/films/override

const OVERRIDES = ["include", "exclude"] as const;

function validateOverride(body: unknown) {
  const obj = object(body, "body");
  return {
    letterboxd_uri: letterboxdUri(obj.letterboxd_uri, "letterboxd_uri"),
    genre_override: obj.genre_override === null ? null : oneOf(obj.genre_override, "genre_override", OVERRIDES),
  };
}

export const setOverride = withJsonBody(validateOverride, async (input, env) => {
  const film = await env.DB.prepare(
    `UPDATE films SET genre_override = ? WHERE letterboxd_uri = ? RETURNING ${FILM_COLUMNS}`,
  )
    .bind(input.genre_override, input.letterboxd_uri)
    .first<Film>();
  if (!film) {
    return errorResponse(404, "not_found", `Unknown Letterboxd URI: ${input.letterboxd_uri}`);
  }
  return json(200, film);
});
