import { tmdbGet } from "./client";
import { type MovieDetails, toMovieDetails } from "./movie";

// Enriched details for recommendations: MovieDetails plus director, US watch
// providers, and a trailer, from ONE details request. toMovieDetails and
// GET /tmdb/movie/{id} are untouched — that shape is the CLI's films.tmdb_json.

export const WATCH_REGION = "US";
export const APPEND_TO_RESPONSE = "credits,videos,watch/providers";

/** Best first: a film on a subscription service beats one only for rent. */
const PROVIDER_TYPES = ["flatrate", "free", "ads", "rent", "buy"] as const;
type ProviderType = (typeof PROVIDER_TYPES)[number];

export interface Provider {
  name: string;
  type: ProviderType;
  logo_path: string | null;
}

export interface EnrichedDetails extends MovieDetails {
  director: string | null;
  providers: Provider[];
  providers_link: string | null;
  trailer_key: string | null;
}

type Obj = Record<string, unknown>;
const isObject = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const objects = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isObject) : []);
const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null);

/** GET /movie/{id} with credits, videos, and watch providers appended. Throws TmdbError. */
export async function fetchEnrichedDetails(env: Env, tmdbId: number): Promise<EnrichedDetails> {
  return toEnrichedDetails(await tmdbGet(env, `/movie/${tmdbId}`, { append_to_response: APPEND_TO_RESPONSE }));
}

/**
 * Maps an appended details response. Any appended section that is absent or
 * malformed maps to empty — missing enrichment never fails resolution.
 */
export function toEnrichedDetails(raw: unknown): EnrichedDetails {
  const details = toMovieDetails(raw);
  const body = raw as Obj;
  return {
    ...details,
    director: director(body.credits),
    // TMDB keys the appended section by the literal path "watch/providers".
    ...providers(body["watch/providers"]),
    trailer_key: trailerKey(body.videos),
  };
}

function director(credits: unknown): string | null {
  if (!isObject(credits)) return null;
  const names = objects(credits.crew)
    .filter((c) => c.job === "Director")
    .map((c) => str(c.name))
    .filter((n): n is string => n !== null);
  const unique = [...new Set(names)];
  return unique.length > 0 ? unique.join(", ") : null;
}

function providers(section: unknown): Pick<EnrichedDetails, "providers" | "providers_link"> {
  const region = isObject(section) && isObject(section.results) ? section.results[WATCH_REGION] : undefined;
  if (!isObject(region)) return { providers: [], providers_link: null };

  const seen = new Set<string>();
  const list: Provider[] = [];
  for (const type of PROVIDER_TYPES) {
    for (const entry of objects(region[type])) {
      const name = str(entry.provider_name);
      if (name === null || seen.has(name)) continue;
      seen.add(name);
      list.push({ name, type, logo_path: str(entry.logo_path) });
    }
  }
  return { providers: list, providers_link: str(region.link) };
}

function trailerKey(videos: unknown): string | null {
  if (!isObject(videos)) return null;
  const tier = (v: Obj) => {
    if (v.type === "Trailer") return v.official === true ? 0 : 1;
    if (v.type === "Teaser") return 2;
    return null;
  };
  let best: { tier: number; published: string; key: string } | null = null;
  for (const video of objects(videos.results)) {
    const key = str(video.key);
    const t = tier(video);
    if (video.site !== "YouTube" || key === null || t === null) continue;
    const published = str(video.published_at) ?? "";
    // Lower tier wins; within a tier, the latest published_at (ISO 8601 sorts as text).
    if (!best || t < best.tier || (t === best.tier && published > best.published)) {
      best = { tier: t, published, key };
    }
  }
  return best?.key ?? null;
}
