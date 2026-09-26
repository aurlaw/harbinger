import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MAX_REPLACEMENT_ROUNDS } from "../src/recommend/replace";
import {
  type CatalogFilm,
  type ClaudeReply,
  claudeReply,
  claudeStatus,
  clearAll,
  film,
  mockWorld,
  pick,
  question,
  recs,
  seedLibrary,
} from "./conversations-helpers";
import { count, expectError, ok, send } from "./helpers";

const RECOMMEND_NOW = "Recommend now — do not ask a question.";

// 4xx ids pass every check; 5xx ids fail one (see names).
const CATALOG: CatalogFilm[] = [
  film(401, "Noroi", 2005),
  film(402, "Lake Mungo", 2008),
  film(403, "Kairo", 2001),
  film(404, "Session 9", 2001),
  film(405, "The Wailing", 2016),
  film(406, "Pulse", 2006),
  film(407, "Hagazussa", 2017),
  film(408, "Unknown Runtime", 2010, { runtime: undefined }),
  film(501, "Heat Wave", 2010, { genres: [{ id: 18, name: "Drama" }] }),
  film(502, "Short Scare", 2012, { runtime: 25 }),
  film(503, "Seen Before", 2003), // watched (library says drama)
  film(504, "Listed Later", 2019), // on the watchlist
  film(505, "Said Yes", 2011),
  film(506, "Said No", 2012),
  film(507, "Said Maybe", 2013),
  film(508, "Lost Letterbox", 1999), // library film with no tmdb_id
];

interface Body {
  conversation: { id: string };
  messages: { kind: string; content: Record<string, unknown>; recommendations?: { position: number; tmdb_id: number; title: string }[] }[];
}

const start = (text = "hi") => send("POST", "/conversations", { text });
const append = (id: string, body: unknown) => send("POST", `/conversations/${id}/messages`, body);

/** Two zero-pick replacement rounds, for tests that only look at round 0. */
const noReplacements = (): ClaudeReply[] => [claudeReply(question("?")), claudeReply(question("?"))];

let log: ReturnType<typeof vi.spyOn>;

function logged(event: string): Record<string, unknown>[] {
  return log.mock.calls
    .map(([line]: unknown[]) => (typeof line === "string" && line.startsWith("{") ? JSON.parse(line) : null))
    .filter((l: Record<string, unknown> | null) => l?.event === event);
}

const reasons = () => logged("pick_rejected").map((r) => [r.title, r.reason]);
const titles = (body: Body) => body.messages[1]!.recommendations!.map((r) => r.title);

beforeEach(async () => {
  await clearAll();
  await seedLibrary([
    { name: "Hereditary", year: 2018, horror: true, half_stars: 10, watched: true },
    { name: "Seen Before", year: 2003, horror: false, watched: true, tmdb_id: 503 },
    { name: "Listed Later", year: 2019, horror: true, watchlist: true, tmdb_id: 504 },
    { name: "LOST  LETTERBOX", year: 2000, watched: true, tmdb_id: null },
  ]);
  log = vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("per-pick validation", () => {
  it("rejects not_horror and not_feature; unknown runtime passes", async () => {
    mockWorld(CATALOG, [
      claudeReply(recs(pick("Heat Wave", 2010), pick("Short Scare", 2012), pick("Unknown Runtime", 2010))),
      ...noReplacements(),
    ]);
    const body = await ok<Body>(await start());
    expect(titles(body)).toEqual(["Unknown Runtime"]);
    expect(reasons()).toEqual([
      ["Heat Wave", "not_horror"],
      ["Short Scare", "not_feature"],
    ]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 2 });
  });

  it("rejects watched (any genre), watchlist, and unmatched library films by normalized title ± 1 year", async () => {
    mockWorld(CATALOG, [
      claudeReply(
        recs(pick("Seen Before", 2003), pick("Listed Later", 2019), pick("Lost Letterbox", 1999), pick("Noroi", 2005)),
      ),
      ...noReplacements(),
    ]);
    const body = await ok<Body>(await start());
    expect(titles(body)).toEqual(["Noroi"]);
    expect(reasons()).toEqual([
      ["Seen Before", "excluded"],
      ["Listed Later", "excluded"],
      ["Lost Letterbox", "excluded"],
    ]);
  });

  it("applies yes / no decisions everywhere and maybe only in its own conversation", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    const a = await ok<Body>(await start());
    const decided = "2026-09-26T00:00:00.000Z";
    await env.DB.batch(
      (
        [
          [505, "yes"],
          [506, "no"],
          [507, "maybe"],
        ] as const
      ).map(([id, decision]) =>
        env.DB.prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (?, ?, ?, ?)").bind(
          id,
          decision,
          a.conversation.id,
          decided,
        ),
      ),
    );
    const three = recs(pick("Said Yes", 2011), pick("Said No", 2012), pick("Said Maybe", 2013));

    // A different conversation: yes / no excluded, maybe allowed.
    world.replies.push(claudeReply(three), ...noReplacements());
    const b = await ok<Body>(await start());
    expect(titles(b)).toEqual(["Said Maybe"]);

    // The maybe's own conversation: all three excluded.
    world.replies.push(claudeReply(three), ...noReplacements());
    await expectError(await append(a.conversation.id, { just_pick: true }), 502, "recommendation_failed");
    expect(reasons().slice(-3)).toEqual([
      ["Said Yes", "excluded"],
      ["Said No", "excluded"],
      ["Said Maybe", "excluded"],
    ]);
  });

  it("rejects a film already shown in this conversation; allows it in another", async () => {
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005)))]);
    const a = await ok<Body>(await start());

    world.replies.push(claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001))), ...noReplacements());
    const again = await ok<Body>(await append(a.conversation.id, { text: "more" }));
    expect(titles(again)).toEqual(["Kairo"]);
    expect(reasons()).toEqual([["Noroi", "excluded"]]);

    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    const other = await ok<Body>(await start());
    expect(titles(other)).toEqual(["Noroi"]);
  });

  it("rejects a second pick resolving to the same tmdb_id as duplicate", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Kairo", 2001), pick("KAIRO", 2001))), ...noReplacements()]);
    const body = await ok<Body>(await start());
    expect(body.messages[1]!.recommendations!.map((r) => r.tmdb_id)).toEqual([403]);
    expect(reasons()).toEqual([["KAIRO", "duplicate"]]);
  });
});

describe("replacement loop", () => {
  it("replaces 2 rejected of 5 in one round; originals first, then replacements, positions 1–5", async () => {
    const world = mockWorld(CATALOG, [
      claudeReply(
        recs(
          pick("Noroi", 2005),
          pick("Heat Wave", 2010),
          pick("Lake Mungo", 2008),
          pick("Seen Before", 2003),
          pick("Kairo", 2001),
        ),
      ),
      claudeReply(recs(pick("Session 9", 2001), pick("The Wailing", 2016))),
    ]);
    const body = await ok<Body>(await start("classic slow burn"));

    expect(world.claudeCalls).toHaveLength(2);
    expect(body.messages[1]!.recommendations!.map((r) => [r.position, r.title])).toEqual([
      [1, "Noroi"],
      [2, "Lake Mungo"],
      [3, "Kairo"],
      [4, "Session 9"],
      [5, "The Wailing"],
    ]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 2 });

    const [first, replacement] = world.claudeCalls.map((c) => c.body);
    expect(replacement!.system).toBe(first!.system);
    expect(JSON.stringify(replacement!.output_config)).toBe(JSON.stringify(first!.output_config));
    expect(replacement!.model).toBe(first!.model);
    const messages = replacement!.messages;
    expect(messages.slice(0, 1)).toStrictEqual(first!.messages);
    expect(messages[1]!.role).toBe("assistant");
    expect(JSON.parse(messages[1]!.content)).toMatchObject({ kind: "recommendations" });
    expect(messages[2]).toStrictEqual({
      role: "user",
      content:
        "These picks can't be used: Heat Wave (2010) — not a horror film; " +
        "Seen Before (2003) — already seen, on the watchlist, or already decided. " +
        "Recommend 2 different films for the same request. " +
        `Don't repeat any film recommended or rejected in this conversation. ${RECOMMEND_NOW}`,
    });

    expect(logged("pick_summary")).toStrictEqual([
      { event: "pick_summary", target: 5, accepted: 5, rejected: 2, rounds: 1 },
    ]);
    // Only the user message and the final assistant message are stored.
    expect(await count("messages")).toBe(2);
    expect(await count("recommendations")).toBe(5);
  });

  it("lists rejections cumulatively; a repeated rejected film is a duplicate", async () => {
    const world = mockWorld(CATALOG, [
      claudeReply(recs(pick("Noroi", 2005), pick("Heat Wave", 2010), pick("Kairo", 2001))),
      claudeReply(recs(pick("Heat Wave", 2010))),
      claudeReply(recs(pick("Short Scare", 2012), pick("Session 9", 2001))),
    ]);
    const body = await ok<Body>(await start());

    expect(world.claudeCalls).toHaveLength(1 + MAX_REPLACEMENT_ROUNDS);
    expect(titles(body)).toEqual(["Noroi", "Kairo", "Session 9"]);
    expect(reasons()).toEqual([
      ["Heat Wave", "not_horror"],
      ["Heat Wave", "duplicate"],
      ["Short Scare", "not_feature"],
    ]);
    const round2 = world.claudeCalls[2]!.body.messages;
    expect(round2.map((m) => m.role)).toEqual(["user", "assistant", "user", "assistant", "user"]);
    expect(round2.at(-1)!.content).toBe(
      "These picks can't be used: Heat Wave (2010) — not a horror film; Heat Wave (2010) — duplicate. " +
        "Recommend 1 different film for the same request. " +
        `Don't repeat any film recommended or rejected in this conversation. ${RECOMMEND_NOW}`,
    );
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 3 });
  });

  it("doesn't pad a deliberate 2-pick reply", async () => {
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))]);
    const body = await ok<Body>(await start());
    expect(world.claudeCalls).toHaveLength(1);
    expect(titles(body)).toEqual(["Noroi", "Kairo"]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 0 });
  });

  it("stores what it has after the cap, with dropped = total rejected; a question round counts as zero picks", async () => {
    const world = mockWorld(CATALOG, [
      claudeReply(recs(pick("Noroi", 2005), pick("Heat Wave", 2010), pick("Short Scare", 2012))),
      claudeReply(question("Which decade?", ["70s"])),
      claudeReply(recs(pick("Seen Before", 2003), pick("Not Real", 2000))),
    ]);
    const body = await ok<Body>(await start());
    expect(world.claudeCalls).toHaveLength(3);
    expect(titles(body)).toEqual(["Noroi"]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 4 });
    expect(logged("pick_summary")).toStrictEqual([
      { event: "pick_summary", target: 3, accepted: 1, rejected: 4, rounds: 2 },
    ]);
    // The replacement turn after the question still asks for 2.
    expect(world.claudeCalls[2]!.body.messages.at(-1)!.content).toContain("Recommend 2 different films");
  });

  it("0 accepted after the cap → 502 recommendation_failed, nothing stored", async () => {
    mockWorld(CATALOG, [
      claudeReply(recs(pick("Heat Wave", 2010))),
      claudeReply(recs(pick("Short Scare", 2012))),
      claudeReply(recs(pick("Seen Before", 2003))),
    ]);
    await expectError(await start(), 502, "recommendation_failed");
    expect(await count("conversations")).toBe(0);
    expect(await count("messages")).toBe(0);
  });

  it("discards over-delivery in a replacement round", async () => {
    mockWorld(CATALOG, [
      claudeReply(recs(pick("Noroi", 2005), pick("Heat Wave", 2010))),
      claudeReply(recs(pick("Kairo", 2001), pick("Session 9", 2001), pick("The Wailing", 2016))),
    ]);
    const body = await ok<Body>(await start());
    expect(titles(body)).toEqual(["Noroi", "Kairo"]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 1 });
  });

  it("Claude 529 during a replacement round → 503, nothing stored", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Heat Wave", 2010))), claudeStatus(529)]);
    await expectError(await start(), 503, "claude_unavailable");
    expect(await count("conversations")).toBe(0);
    expect(await count("messages")).toBe(0);
  });

  it("invalid picks don't raise the target but are named in the replacement turn", async () => {
    const badYear = { title: "Bad Year", year: 3000, why_short: "s", why_full: "f" };
    const world = mockWorld(CATALOG, [
      claudeReply(recs(pick("Noroi", 2005), badYear, pick("Heat Wave", 2010))),
      claudeReply(recs(pick("Kairo", 2001))),
    ]);
    const body = await ok<Body>(await start());
    // Target = 2 valid-shaped picks; one rejected → one round asking for 1.
    expect(world.claudeCalls).toHaveLength(2);
    expect(world.claudeCalls[1]!.body.messages.at(-1)!.content).toMatch(
      /^These picks can't be used: Bad Year \(3000\) — invalid; Heat Wave \(2010\) — not a horror film\. Recommend 1 different film /,
    );
    expect(titles(body)).toEqual(["Noroi", "Kairo"]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 2 });
  });
});
