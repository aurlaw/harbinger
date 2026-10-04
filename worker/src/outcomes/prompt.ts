import { MOST_RECENT_FIRST, OUTCOME_JOIN, isHit } from "./store";

// The "Harbinger picks they've since rated" section of the recommendation system prompt.

export interface OutcomeLine {
  title: string;
  year: number | null;
  half_stars: number;
}

const MAX_OUTCOMES = 30;

// Cache-safe: picks made in the current conversation are unrated, so the
// section only changes when ratings do (on import).
export const PROMPT_OUTCOMES = `
  SELECT p.title, p.year, r.half_stars
  ${OUTCOME_JOIN}
  ${MOST_RECENT_FIRST}
  LIMIT ${MAX_OUTCOMES}`;

function line(outcome: OutcomeLine): string {
  const name = outcome.year === null ? outcome.title : `${outcome.title} (${outcome.year})`;
  return `${name} — ★${outcome.half_stars / 2} — ${isHit(outcome.half_stars) ? "hit" : "miss"}`;
}

export function outcomesSection(outcomes: OutcomeLine[]): string {
  return `## Harbinger picks they've since rated (how past recommendations landed)
Direct evidence of where earlier reads of their taste were right or wrong. ★3.5 or higher counts as a hit.
${outcomes.length > 0 ? outcomes.map(line).join("\n") : "(none yet)"}`;
}
