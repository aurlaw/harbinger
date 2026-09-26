import { ClaudeError } from "../claude/client";

// The structured-output schema and the Worker-side validation of Claude's JSON.

/**
 * One constant schema for every call. Changing output_config.format invalidates
 * the prompt cache, so question-vs-recommend is steered by instructions, never
 * by swapping schemas. Structured outputs don't support maxItems / minLength /
 * minimum etc. — those rules are enforced in parseReply.
 */
export const OUTPUT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "question", "chips", "picks"],
  properties: {
    kind: { type: "string", enum: ["question", "recommendations"] },
    question: { type: "string" },
    chips: { type: "array", items: { type: "string" } },
    picks: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["title", "year", "why_short", "why_full"],
        properties: {
          title: { type: "string" },
          year: { type: "integer" },
          why_short: { type: "string" },
          why_full: { type: "string" },
        },
      },
    },
  },
} as const;

export const MAX_PICKS = 5;
export const MAX_CHIPS = 4;

export interface FilmPick {
  title: string;
  year: number;
  why_short: string;
  why_full: string;
}

/** A pick that failed shape validation; title / year kept when usable, to name it back to Claude. */
export interface InvalidPick {
  title: string | null;
  year: number | null;
}

export type Reply =
  | { kind: "question"; question: string; chips: string[] }
  /** `picks` may be empty; `invalid` are dropped by validation (reported as dropped). */
  | { kind: "recommendations"; picks: FilmPick[]; invalid: InvalidPick[] };

export const recommendationFailed = (message: string) =>
  new ClaudeError(502, "recommendation_failed", message);

function malformed(detail: string): ClaudeError {
  console.error(`Claude: reply does not match the output schema: ${detail}`);
  return new ClaudeError(502, "claude_error", "Claude request failed");
}

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

/**
 * Validates Claude's structured output. A reply that breaks the schema itself
 * → claude_error; an empty question → recommendation_failed. Zero valid picks
 * is returned as-is — the caller decides whether that fails the request.
 */
export function parseReply(raw: unknown): Reply {
  if (!isObject(raw)) throw malformed("not an object");
  // Structured outputs don't guarantee enum capitalization.
  const kind = typeof raw.kind === "string" ? raw.kind.toLowerCase() : null;

  if (kind === "question") {
    if (typeof raw.question !== "string") throw malformed("question");
    const question = raw.question.trim();
    if (question.length === 0) throw recommendationFailed("Claude asked an empty question");
    const chips = Array.isArray(raw.chips)
      ? raw.chips
          .filter((c): c is string => typeof c === "string")
          .map((c) => c.trim())
          .filter((c) => c.length > 0)
          .slice(0, MAX_CHIPS)
      : [];
    return { kind: "question", question, chips };
  }

  if (kind === "recommendations") {
    if (!Array.isArray(raw.picks)) throw malformed("picks");
    if (raw.picks.length > MAX_PICKS) {
      console.log(`Claude returned ${raw.picks.length} picks; using the first ${MAX_PICKS}`);
    }
    const picks: FilmPick[] = [];
    const invalid: InvalidPick[] = [];
    for (const item of raw.picks.slice(0, MAX_PICKS)) {
      const pick = toPick(item);
      if (pick) picks.push(pick);
      else invalid.push(describeInvalid(item));
    }
    return { kind: "recommendations", picks, invalid };
  }

  throw malformed("kind");
}

function describeInvalid(raw: unknown): InvalidPick {
  const title = isObject(raw) && typeof raw.title === "string" && raw.title.trim() ? raw.title.trim() : null;
  const year = isObject(raw) && typeof raw.year === "number" && Number.isInteger(raw.year) ? raw.year : null;
  return { title, year };
}

function toPick(raw: unknown): FilmPick | null {
  if (!isObject(raw)) return null;
  const { title, year, why_short, why_full } = raw;
  if (
    typeof title !== "string" ||
    typeof why_short !== "string" ||
    typeof why_full !== "string" ||
    typeof year !== "number" ||
    !Number.isInteger(year) ||
    year < 1870 ||
    year > 2100
  ) {
    return null;
  }
  const pick = { title: title.trim(), year, why_short: why_short.trim(), why_full: why_full.trim() };
  if (!pick.title || !pick.why_short || !pick.why_full) return null;
  return pick;
}
