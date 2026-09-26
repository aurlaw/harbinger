import { ClaudeError } from "../claude/client";
import { type LibraryPrompt, formatRatings } from "../recommend/prompt";

// Taste-profile draft: constant schema, instructions, user turn, and the
// deterministic Notes handling (the Worker's job, not Claude's).

// Thinking tokens count against this. 2048 (the brief's value) ran out on
// claude-sonnet-5's adaptive thinking before the JSON was finished.
export const DRAFT_MAX_TOKENS = 8192;

/** Constant, all fields required — same structured-output rules as recommendations. */
export const DRAFT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["content", "changes"],
  properties: {
    content: { type: "string" },
    changes: { type: "array", items: { type: "string" } },
  },
} as const;

export const DRAFT_INSTRUCTIONS = `You write a short taste profile for one person's horror film taste, from their ratings. The profile is fed into future recommendation prompts alongside the ratings, so it must add interpretation, not repeat data.

Write "content" as Markdown with exactly these four "##" sections, in this order:
## Loves
## Enjoys
## Mixed on
## Tends to dislike

- Summarize patterns, not titles: subgenres, settings, tone, pacing, themes, eras, craft — what the high ratings share and why the low ones missed. An occasional example title is fine; lists of titles are not.
- Short prose per section, about 150–300 words in total.
- Do not write a "Notes" section. It belongs to the person and is handled separately.

When a current profile is provided, revise it rather than starting over:
- Keep the person's wording wherever the ratings still support it. Change only where the ratings clearly show a different pattern.
- Where the current profile contradicts the ratings, keep the profile's version — the person's edits win — and mention the conflict in "changes".

"changes": short lines naming what moved and why, e.g. "Moved found footage from Mixed on to Enjoys — 6 recent 4+ ratings". Leave it empty when there is no current profile.`;

/** The user turn: horror ratings (same format as recommendations), plus the current profile when saved. */
export function draftUserTurn(ratings: LibraryPrompt["horrorRatings"], current: string | null): string {
  const parts = [`<horror_ratings>\n${formatRatings(ratings)}\n</horror_ratings>`];
  if (current !== null) {
    parts.push(
      `<current_profile>\nThe person's saved taste profile. Revise it; don't start over.\n\n${current}\n</current_profile>`,
    );
    parts.push("Revise the current profile against the ratings.");
  } else {
    parts.push("There is no current profile. Draft one from the ratings.");
  }
  return parts.join("\n\n");
}

const NOTES_HEADING = /^##[ \t]+notes[ \t]*\r?$/i;

/** Splits Markdown into chunks: any preamble, then one chunk per "## " section (heading + body, verbatim). */
function sections(content: string): string[] {
  const starts = [0];
  for (const match of content.matchAll(/^## /gm)) {
    if (match.index > 0) starts.push(match.index);
  }
  return starts.map((start, i) => content.slice(start, starts[i + 1] ?? content.length)).filter((c) => c.length > 0);
}

const isNotes = (section: string) => NOTES_HEADING.test(section.split("\n", 1)[0] ?? "");

/**
 * Final draft content: Claude's content with any Notes section stripped, then
 * the current profile's Notes section(s) appended verbatim (heading + body;
 * only trailing whitespace before the next section is dropped).
 */
export function mergeNotes(draft: string, current: string | null): string {
  const body = sections(draft)
    .filter((s) => !isNotes(s))
    .join("")
    .trim();
  const notes = current === null ? [] : sections(current).filter(isNotes).map((s) => s.replace(/\s+$/, ""));
  return notes.length > 0 ? `${body}\n\n${notes.join("\n\n")}` : body;
}

const claudeError = (detail: string) => {
  console.error(`Claude: taste-profile draft invalid: ${detail}`);
  return new ClaudeError(502, "claude_error", "Claude request failed");
};

/** Validates Claude's draft JSON and applies the Notes rules. */
export function parseDraft(raw: unknown, current: string | null): { content: string; changes: string[] } {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw claudeError("not an object");
  const { content, changes } = raw as Record<string, unknown>;
  if (typeof content !== "string" || content.trim().length === 0) throw claudeError("empty content");

  // Claude wrote nothing but Notes: there's no draft.
  if (sections(content.trim()).every(isNotes)) throw claudeError("content was only a Notes section");

  return {
    content: mergeNotes(content, current),
    changes:
      current === null || !Array.isArray(changes)
        ? []
        : changes
            .filter((c): c is string => typeof c === "string")
            .map((c) => c.trim())
            .filter((c) => c.length > 0),
  };
}
