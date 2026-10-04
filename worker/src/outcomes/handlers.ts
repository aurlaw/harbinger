import { json } from "../http";
import { HIT_THRESHOLD_HALF_STARS, MOST_RECENT_FIRST, OUTCOME_JOIN, isHit } from "./store";

// GET /stats/outcomes — the track record of recommended films that have since
// been rated, overall and per model. Read-only.

const MAX_RECENT = 20;

const RECOMMENDED_BY_MODEL = "SELECT model, COUNT(*) AS recommended FROM pick_log GROUP BY model";

const RATED_BY_MODEL = `
  SELECT p.model, COUNT(*) AS rated, SUM(r.half_stars >= ?1) AS hits, SUM(r.half_stars) AS half_stars
  ${OUTCOME_JOIN}
  GROUP BY p.model`;

const RECENT = `
  SELECT p.tmdb_id, p.title, p.year, r.half_stars, p.model, p.first_recommended_at
  ${OUTCOME_JOIN}
  ${MOST_RECENT_FIRST}
  LIMIT ${MAX_RECENT}`;

interface RecommendedRow {
  model: string;
  recommended: number;
}

interface RatedRow {
  model: string;
  rated: number;
  hits: number;
  half_stars: number;
}

interface RecentRow {
  tmdb_id: number;
  title: string;
  year: number | null;
  half_stars: number;
  model: string;
  first_recommended_at: string;
}

const round = (value: number, decimals: number) => Math.round(value * 10 ** decimals) / 10 ** decimals;
/** null when nothing is rated — never divide by zero. */
const hitRate = (hits: number, rated: number) => (rated === 0 ? null : round(hits / rated, 3));
const sum = (values: number[]) => values.reduce((total, v) => total + v, 0);

export async function outcomeStats(_request: Request, env: Env): Promise<Response> {
  const [recommendedRows, ratedRows, recentRows] = await env.DB.batch([
    env.DB.prepare(RECOMMENDED_BY_MODEL),
    env.DB.prepare(RATED_BY_MODEL).bind(HIT_THRESHOLD_HALF_STARS),
    env.DB.prepare(RECENT),
  ]);
  const recommended = (recommendedRows?.results ?? []) as RecommendedRow[];
  const ratedByModel = new Map(((ratedRows?.results ?? []) as RatedRow[]).map((r) => [r.model, r]));
  const outcomes = [...ratedByModel.values()];

  const rated = sum(outcomes.map((r) => r.rated));
  const hits = sum(outcomes.map((r) => r.hits));

  return json(200, {
    hit_threshold_half_stars: HIT_THRESHOLD_HALF_STARS,
    recommended: sum(recommended.map((r) => r.recommended)),
    rated,
    hits,
    hit_rate: hitRate(hits, rated),
    average_half_stars: rated === 0 ? null : round(sum(outcomes.map((r) => r.half_stars)) / rated, 1),
    by_model: recommended
      .map(({ model, recommended }) => {
        const r = ratedByModel.get(model);
        return { model, recommended, rated: r?.rated ?? 0, hits: r?.hits ?? 0, hit_rate: hitRate(r?.hits ?? 0, r?.rated ?? 0) };
      })
      .sort((a, b) => b.recommended - a.recommended || (a.model < b.model ? -1 : a.model > b.model ? 1 : 0)),
    recent: ((recentRows?.results ?? []) as RecentRow[]).map((r) => ({
      tmdb_id: r.tmdb_id,
      title: r.title,
      year: r.year,
      half_stars: r.half_stars,
      hit: isHit(r.half_stars),
      model: r.model,
      first_recommended_at: r.first_recommended_at,
    })),
  });
}
