import { errorResponse, json } from "../http";
import { expectObject, tmdbGet, withTmdbErrors } from "./client";

// GET /tmdb/movie/{id} — the response is exactly what the CLI stores as films.tmdb_json.

/** The single server-side definition of the horror rule. */
export const HORROR_GENRE_ID = 27;

interface TmdbGenre {
  id: number;
  name: string;
}

interface TmdbMovie {
  id: number;
  title: string;
  original_title: string;
  release_date?: string;
  genres?: TmdbGenre[];
  runtime?: number | null;
  overview: string;
  poster_path?: string | null;
}

export interface MovieDetails {
  tmdb_id: number;
  title: string;
  original_title: string;
  release_date: string | null;
  genres: TmdbGenre[];
  is_horror: boolean;
  runtime: number | null;
  overview: string;
  poster_path: string | null;
}

export function toMovieDetails(raw: unknown): MovieDetails {
  const movie = expectObject(raw, "/movie/{id}") as unknown as TmdbMovie;
  const genres = (movie.genres ?? []).map(({ id, name }) => ({ id, name }));
  return {
    tmdb_id: movie.id,
    title: movie.title,
    original_title: movie.original_title,
    release_date: movie.release_date || null,
    genres,
    is_horror: genres.some((g) => g.id === HORROR_GENRE_ID),
    runtime: movie.runtime || null,
    overview: movie.overview,
    poster_path: movie.poster_path ?? null,
  };
}

// Positive integer: digits only, no leading zero, at most 10 digits.
const TMDB_ID = /^[1-9]\d{0,9}$/;

export async function movieDetails(_request: Request, env: Env, params: Record<string, string>): Promise<Response> {
  const id = params.id ?? "";
  if (!TMDB_ID.test(id)) {
    return errorResponse(400, "invalid_request", "id must be a positive integer of at most 10 digits");
  }
  return withTmdbErrors(async () => json(200, toMovieDetails(await tmdbGet(env, `/movie/${id}`))));
}
