import { describe, expect, it, vi } from "vitest";
import { titleFrom } from "../src/conversations/handlers";
import { normalizeTitle } from "../src/recommend/normalize";
import { buildSystemPrompt, replayTurns } from "../src/recommend/prompt";
import { parseReply } from "../src/recommend/schema";

const cp = (...codes: number[]) => String.fromCodePoint(...codes);
const EN_DASH = cp(0x2013);
const EM_DASH = cp(0x2014);
const RSQUO = cp(0x2019);
const NBSP = cp(0xa0);

describe("normalizeTitle (mirrors the CLI's normalize.Title)", () => {
  it.each([
    [`Mission: Impossible ${EN_DASH} Fallout`, "mission: impossible - fallout"],
    [`Alien${EM_DASH}Covenant`, "alien-covenant"],
    [`Rosemary${RSQUO}s Baby`, "rosemary's baby"],
    [`The ${cp(0x201c)}Thing${cp(0x201d)}`, 'the "thing"'],
    [`  The\t\tWitch ${NBSP} (2015)\n`, "the witch (2015)"],
    [`${NBSP}As Above,${cp(0x2003)}So Below `, "as above, so below"],
    [`a${EN_DASH}${EM_DASH}b`, "a--b"],
    ["   ", ""],
  ])("%j → %j", (input, expected) => {
    expect(normalizeTitle(input)).toBe(expected);
  });
});

describe("parseReply", () => {
  const pick = (title: string, year: unknown = 2015) => ({ title, year, why_short: "s", why_full: "f" });

  it("accepts kind in any case", () => {
    expect(parseReply({ kind: "Recommendations", question: "", chips: [], picks: [pick("A")] }).kind).toBe(
      "recommendations",
    );
    expect(parseReply({ kind: "QUESTION", question: "Why?", chips: [], picks: [] }).kind).toBe("question");
  });

  it("trims chips, drops empties, keeps at most 4", () => {
    const reply = parseReply({ kind: "question", question: " Q? ", chips: [" a ", "", "  ", "b", "c", "d", "e"], picks: [] });
    expect(reply).toEqual({ kind: "question", question: "Q?", chips: ["a", "b", "c", "d"] });
  });

  it("uses only the first 5 picks and counts invalid ones", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const reply = parseReply({
      kind: "recommendations",
      question: "ignored",
      chips: ["ignored"],
      picks: [pick("A"), pick(""), pick("C", 1869), pick("D", 2015.5), pick("E"), pick("F"), pick("G")],
    });
    expect(reply).toEqual({
      kind: "recommendations",
      picks: [pick("A"), pick("E")],
      invalid: 3,
    });
    expect(log).toHaveBeenCalled();
    log.mockRestore();
  });

  it("fails recommendation_failed with no valid picks or an empty question", () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(() => parseReply({ kind: "recommendations", question: "", chips: [], picks: [] })).toThrow(
      expect.objectContaining({ code: "recommendation_failed" }),
    );
    expect(() => parseReply({ kind: "question", question: "  ", chips: [], picks: [] })).toThrow(
      expect.objectContaining({ code: "recommendation_failed" }),
    );
    expect(() => parseReply({ kind: "banana" })).toThrow(expect.objectContaining({ code: "claude_error" }));
    expect(() => parseReply([])).toThrow(expect.objectContaining({ code: "claude_error" }));
    err.mockRestore();
  });
});

describe("titleFrom", () => {
  it("keeps short text and cuts long text at a word boundary within 60 characters", () => {
    expect(titleFrom("Something slow")).toBe("Something slow");
    const long = "Something slow and unsettling, under two hours, ideally folk horror from the seventies";
    const title = titleFrom(long);
    expect(title.length).toBeLessThanOrEqual(60);
    expect(long.startsWith(title)).toBe(true);
    expect(long[title.length]).toBe(" ");
    expect(titleFrom("x".repeat(80))).toBe("x".repeat(60));
    const ghost = String.fromCodePoint(0x1f47b);
    expect(titleFrom(ghost.repeat(80))).toBe(ghost.repeat(60));
    expect(titleFrom(`${"a".repeat(60)} tail`)).toBe("a".repeat(60));
  });
});

describe("prompt", () => {
  it("formats ratings as half-star values and marks empty lists", () => {
    const system = buildSystemPrompt({
      horrorRatings: [{ name: "Hereditary", year: 2018, half_stars: 9 }],
      seen: [],
      watchlist: [],
    });
    expect(system).toContain("Hereditary (2018) — ★4.5");
    expect(system).toContain("## Never recommend (already seen)\n(none)");
    expect(system).not.toContain("Taste profile");
    expect(buildSystemPrompt({ horrorRatings: [], seen: [], watchlist: [] }, "Likes dread.")).toContain(
      "## Taste profile\nLikes dread.",
    );
  });

  it("replays the recommend-now line on a user turn sent after two questions", () => {
    const q = { role: "assistant", kind: "question", question: "Q", chips: [] as string[] } as const;
    const messages = replayTurns([
      { role: "user", text: "a", just_pick: false },
      q,
      { role: "user", text: "b", just_pick: false },
      q,
      { role: "user", text: "c", just_pick: false },
    ]);
    expect(messages.map((m) => m.content)).toEqual([
      "a",
      JSON.stringify({ kind: "question", question: "Q", chips: [], picks: [] }),
      "b",
      JSON.stringify({ kind: "question", question: "Q", chips: [], picks: [] }),
      "c\n\nRecommend now — do not ask a question.",
    ]);
  });
});
