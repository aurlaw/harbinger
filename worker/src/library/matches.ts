import { InvalidRequest, withJsonBody } from "../body";
import { json } from "../http";
import { absent, integer, letterboxdUri, object, oneOf, uniqueItems } from "../validate";
import { unknownFilmsResponse, unknownUris } from "./shared";

// POST /library/films/matches

interface MatchInput {
  letterboxd_uri: string;
  match_status: "matched" | "ambiguous" | "unmatched";
  tmdb_id: number | null;
  is_horror: number | null;
  tmdb_json: string | null; // already JSON.stringify'd
}

const STATUSES = ["matched", "ambiguous", "unmatched"] as const;

function validateMatches(body: unknown): MatchInput[] {
  const obj = object(body, "body");
  return uniqueItems(obj.matches, "matches", (item, path) => {
    const letterboxd_uri = letterboxdUri(item.letterboxd_uri, `${path}.letterboxd_uri`);
    const match_status = oneOf(item.match_status, `${path}.match_status`, STATUSES);
    if (match_status !== "matched") {
      for (const key of ["tmdb_id", "is_horror", "tmdb_json"]) absent(item, key, path);
      return { letterboxd_uri, match_status, tmdb_id: null, is_horror: null, tmdb_json: null };
    }
    const tmdbJson = item.tmdb_json;
    if (typeof tmdbJson !== "object" || tmdbJson === null || Array.isArray(tmdbJson)) {
      throw new InvalidRequest(`${path}.tmdb_json must be an object`);
    }
    return {
      letterboxd_uri,
      match_status,
      tmdb_id: integer(item.tmdb_id, `${path}.tmdb_id`, 1, Number.MAX_SAFE_INTEGER),
      is_horror: integer(item.is_horror, `${path}.is_horror`, 0, 1),
      tmdb_json: JSON.stringify(tmdbJson),
    };
  });
}

// Non-matched statuses clear the match columns (a matched film can be re-marked).
// genre_override is never touched.
const APPLY_MATCHES = `
  UPDATE films SET
    match_status = m.match_status,
    tmdb_id      = m.tmdb_id,
    is_horror    = m.is_horror,
    tmdb_json    = m.tmdb_json,
    matched_at   = CASE WHEN m.match_status = 'matched' THEN ?2 ELSE NULL END
  FROM (SELECT json_extract(value, '$.letterboxd_uri') AS letterboxd_uri,
               json_extract(value, '$.match_status')   AS match_status,
               json_extract(value, '$.tmdb_id')        AS tmdb_id,
               json_extract(value, '$.is_horror')      AS is_horror,
               json_extract(value, '$.tmdb_json')      AS tmdb_json
        FROM json_each(?1)) AS m
  WHERE films.letterboxd_uri = m.letterboxd_uri`;

export const recordMatches = withJsonBody(validateMatches, async (matches, env) => {
  const unknown = await unknownUris(env.DB, matches.map((m) => m.letterboxd_uri));
  if (unknown.length > 0) return unknownFilmsResponse(unknown);

  const result = await env.DB.prepare(APPLY_MATCHES)
    .bind(JSON.stringify(matches), new Date().toISOString())
    .run();
  return json(200, { updated: result.meta.changes });
});
