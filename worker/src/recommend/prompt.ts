import type { ClaudeMessage } from "../claude/client";
import { MAX_CHIPS, MAX_PICKS } from "./schema";

// System prompt + message assembly. The system prompt depends only on library
// state, so it stays byte-identical across a conversation's turns (cache hits).
// Per-turn steering (recommend now) goes on the user turn, never in here.

export interface LibraryPrompt {
  horrorRatings: { name: string; year: number; half_stars: number }[];
  seen: { name: string; year: number }[];
  watchlist: { name: string; year: number }[];
}

// Every ORDER BY is total so identical library state yields an identical prompt.
const HORROR_RATINGS = `
  SELECT f.name, f.year, r.half_stars
  FROM horror_films f JOIN ratings r ON r.letterboxd_uri = f.letterboxd_uri
  ORDER BY r.half_stars DESC, f.name, f.year, f.letterboxd_uri`;

// Seen = watched or rated, any genre, minus the horror ratings listed above.
const SEEN = `
  SELECT f.name, f.year
  FROM films f
  WHERE f.letterboxd_uri IN (SELECT letterboxd_uri FROM watched UNION SELECT letterboxd_uri FROM ratings)
    AND f.letterboxd_uri NOT IN (SELECT h.letterboxd_uri FROM horror_films h
                                 JOIN ratings r ON r.letterboxd_uri = h.letterboxd_uri)
  ORDER BY f.name, f.year, f.letterboxd_uri`;

const WATCHLIST = `
  SELECT f.name, f.year
  FROM watchlist w JOIN films f ON f.letterboxd_uri = w.letterboxd_uri
  ORDER BY f.name, f.year, f.letterboxd_uri`;

export async function loadLibraryPrompt(db: D1Database): Promise<LibraryPrompt> {
  const [ratings, seen, watchlist] = await db.batch([
    db.prepare(HORROR_RATINGS),
    db.prepare(SEEN),
    db.prepare(WATCHLIST),
  ]);
  return {
    horrorRatings: (ratings?.results ?? []) as LibraryPrompt["horrorRatings"],
    seen: (seen?.results ?? []) as LibraryPrompt["seen"],
    watchlist: (watchlist?.results ?? []) as LibraryPrompt["watchlist"],
  };
}

const INSTRUCTIONS = `You recommend horror films to one person. Base every recommendation only on their ratings listed below — they are the sole signal of this person's taste.

Each reply is exactly one of:
- kind "question": one clarifying question in "question", with 2–${MAX_CHIPS} short tappable answers in "chips" (a few words each). Leave "picks" empty.
- kind "recommendations": up to ${MAX_PICKS} films in "picks". Leave "question" empty and "chips" empty.
Never both in the same reply.

Ask a question only when the request is genuinely too vague to recommend well. Ask at most one question per reply. When in doubt, recommend.

Recommendations:
- At most ${MAX_PICKS} films. Only feature-length horror films (horror may be one of several genres) — no shorts, no TV series or episodes.
- Never recommend a film from either "Never recommend" list below, or any film already recommended earlier in this conversation.
- "title" and "year": the exact title and original release year as listed on TMDB.
- "why_short": one line, about 120 characters, for a card.
- "why_full": 2–4 sentences grounded in specific patterns in their ratings. Name the rated films the pick relates to.
- Prefer less obvious picks over the most famous titles in the genre, unless the request calls for classics.`;

const film = (f: { name: string; year: number }) => `${f.name} (${f.year})`;
const stars = (halfStars: number) => `★${halfStars / 2}`;
const list = (lines: string[]) => (lines.length > 0 ? lines.join("\n") : "(none)");

/**
 * Builds the system prompt. `tasteProfile` is the W5 hook: when present it
 * becomes its own section after the exclusion lists; absent, it is omitted.
 */
export function buildSystemPrompt(library: LibraryPrompt, tasteProfile?: string): string {
  const sections = [
    INSTRUCTIONS,
    `## Horror ratings (their taste — ★0.5 to ★5)\n${list(
      library.horrorRatings.map((f) => `${film(f)} — ${stars(f.half_stars)}`),
    )}`,
    `## Never recommend (already seen)\n${list(library.seen.map(film))}`,
    `## Never recommend (already on watchlist)\nExclusion only — not a signal of taste.\n${list(
      library.watchlist.map(film),
    )}`,
  ];
  if (tasteProfile) sections.push(`## Taste profile\n${tasteProfile}`);
  return sections.join("\n\n");
}

export const RECOMMEND_NOW = "Recommend now — do not ask a question.";
export const RECOMMEND_NOW_FIRM =
  'Recommend now. A question is not allowed in this reply: respond with kind "recommendations" and at least one pick.';
const JUST_PICK = "Just pick for me.";

/** The user turn as sent to Claude. Deterministic, so replayed turns match what was cached. */
export function userTurnText(text: string | null, justPick: boolean, mustRecommend: boolean, firm = false): string {
  const parts = [text ?? (justPick ? JUST_PICK : "")];
  if (mustRecommend) parts.push(firm ? RECOMMEND_NOW_FIRM : RECOMMEND_NOW);
  return parts.filter((p) => p.length > 0).join("\n\n");
}

export type Turn =
  | { role: "user"; text: string | null; just_pick: boolean }
  | { role: "assistant"; kind: "question"; question: string; chips: string[] }
  | {
      role: "assistant";
      kind: "recommendations";
      picks: { title: string; year: number | null; why_short: string; why_full: string }[];
    };

/**
 * Replays stored turns in seq order. Assistant turns are re-serialized as JSON
 * in the output schema with a fixed key order; recommendation turns come from
 * the stored (TMDB-resolved) rows. A user turn gets the recommend-now line if
 * it had it when sent (just_pick, or two questions already asked).
 */
export function replayTurns(turns: Turn[]): ClaudeMessage[] {
  let questions = 0;
  return turns.map((turn): ClaudeMessage => {
    if (turn.role === "user") {
      const mustRecommend = turn.just_pick || questions >= 2;
      return { role: "user", content: userTurnText(turn.text, turn.just_pick, mustRecommend) };
    }
    if (turn.kind === "question") {
      questions++;
      return {
        role: "assistant",
        content: JSON.stringify({ kind: "question", question: turn.question, chips: turn.chips, picks: [] }),
      };
    }
    return {
      role: "assistant",
      content: JSON.stringify({
        kind: "recommendations",
        question: "",
        chips: [],
        picks: turn.picks.map((p) => ({ title: p.title, year: p.year, why_short: p.why_short, why_full: p.why_full })),
      }),
    };
  });
}
