import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { HIT_THRESHOLD_HALF_STARS } from "../src/outcomes/store";
import { claudeReply, clearAll, film, mockWorld, pick, question, recs, seedLibrary } from "./conversations-helpers";
import { BASE, authed, call, count, expectError, ok, range, send, tick } from "./helpers";

const DASH = String.fromCodePoint(0x2014);
const STAR = String.fromCodePoint(0x2605);
const SONNET = "claude-sonnet-5";
const OPUS = "claude-opus-5-5";
const HAIKU = "claude-haiku-4-5-20251001";
const HEADING = "## Harbinger picks they've since rated (how past recommendations landed)";
const GUIDANCE = `Direct evidence of where earlier reads of their taste were right or wrong. ${STAR}3.5 or higher counts as a hit.`;

const CATALOG = [film(201, "Noroi", 2005), film(202, "Kairo", 2001), film(203, "Lake Mungo", 2008), film(204, "Pulse", 2001)];

interface PickRow {
  tmdb_id: number;
  title: string;
  year: number | null;
  model: string;
  conversation_id: string;
  first_recommended_at: string;
}

interface TurnBody {
  conversation: { id: string };
  messages: { recommendations?: { tmdb_id: number }[] }[];
}

interface Stats {
  hit_threshold_half_stars: number;
  recommended: number;
  rated: number;
  hits: number;
  hit_rate: number | null;
  average_half_stars: number | null;
  by_model: { model: string; recommended: number; rated: number; hits: number; hit_rate: number | null }[];
  recent: {
    tmdb_id: number;
    title: string;
    year: number | null;
    half_stars: number;
    hit: boolean;
    model: string;
    first_recommended_at: string;
  }[];
}

const pickLog = async () => (await env.DB.prepare("SELECT * FROM pick_log ORDER BY tmdb_id").all<PickRow>()).results;
const start = (body: unknown) => send("POST", "/conversations", body);
const reply = (id: string, body: unknown) => send("POST", `/conversations/${id}/messages`, body);
const stats = async () => ok<Stats>(await authed("/stats/outcomes"));

/** `minute` orders the picks: a larger minute = recommended more recently. */
const at = (minute: number) => new Date(Date.UTC(2026, 8, 1, 0, minute)).toISOString();

interface LoggedPick {
  tmdb_id: number;
  title?: string;
  year?: number | null;
  model?: string;
  minute?: number;
}

async function logPicks(picks: LoggedPick[]): Promise<void> {
  const rows = picks.map((p) => ({
    tmdb_id: p.tmdb_id,
    title: p.title ?? `Pick ${p.tmdb_id}`,
    year: p.year === undefined ? 2020 : p.year,
    model: p.model ?? SONNET,
    at: at(p.minute ?? p.tmdb_id),
  }));
  await env.DB.prepare(
    `INSERT INTO pick_log (tmdb_id, title, year, model, conversation_id, first_recommended_at)
     SELECT json_extract(value, '$.tmdb_id'), json_extract(value, '$.title'), json_extract(value, '$.year'),
            json_extract(value, '$.model'), 'c-gone', json_extract(value, '$.at')
     FROM json_each(?)`,
  )
    .bind(JSON.stringify(rows))
    .run();
}

/** Rated library films, as an import would leave them: `[tmdb_id, half_stars]`. */
const rate = (...ratings: [number, number][]) =>
  seedLibrary(
    ratings.map(([tmdb_id, half_stars]) => ({
      name: `Library ${tmdb_id}`,
      year: 2020,
      tmdb_id,
      horror: true,
      half_stars,
      watched: true,
    })),
  );

function section(system: string): string {
  const startAt = system.indexOf(HEADING);
  expect(startAt).toBeGreaterThan(-1);
  const rest = system.slice(startAt + HEADING.length);
  return rest.slice(0, rest.indexOf("\n## ")).trim();
}

const lines = (system: string) => section(system).split("\n").slice(1);

async function systemPrompt(): Promise<string> {
  const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
  await ok(await start({ text: "hi" }));
  return world.claudeCalls[0]!.body.system;
}

beforeEach(async () => {
  await clearAll();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("migration 0006", () => {
  it("creates pick_log", async () => {
    const row = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'pick_log'").first();
    expect(row).toStrictEqual({ name: "pick_log" });
  });

  it("backfills each film's earliest recommendation with its conversation's model, deterministically", async () => {
    const db = env.DB;
    const conversation = (id: string, model: string, deletedAt: string | null) =>
      db
        .prepare("INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at, deleted_at) VALUES (?1, ?2, 't', 0, ?3, ?3, ?4)")
        .bind(id, model, at(0), deletedAt);
    const message = (id: string, conversationId: string) =>
      db
        .prepare("INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES (?, ?, 1, 'assistant', 'recommendations', '{}', ?)")
        .bind(id, conversationId, at(0));
    const rec = (id: string, conversationId: string, position: number, tmdbId: number, title: string, minute: number) =>
      db
        .prepare(
          `INSERT INTO recommendations (id, conversation_id, message_id, position, tmdb_id, title, year, why_short, why_full, tmdb_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, 2020, 's', 'f', '{}', ?)`,
        )
        .bind(id, conversationId, `m-${conversationId}`, position, tmdbId, title, at(minute));

    await db.batch([
      conversation("a", SONNET, null),
      conversation("b", OPUS, null),
      conversation("gone", HAIKU, at(9)),
      message("m-a", "a"),
      message("m-b", "b"),
      message("m-gone", "gone"),
      // Film 1: recommended in both; a's is earlier.
      rec("r1", "a", 1, 1, "First in A", 1),
      rec("r2", "b", 1, 1, "First in A (later)", 5),
      // Film 2: same created_at in both; the smaller id (b's) wins.
      rec("r4", "a", 2, 2, "Tie from A", 3),
      rec("r3", "b", 2, 2, "Tie from B", 3),
      // Film 3: only in b.
      rec("r5", "b", 3, 3, "Only B", 4),
      // Film 4: only in a deleted conversation (an orphan; real deletes remove these).
      rec("r6", "gone", 1, 4, "Deleted", 0),
    ]);

    const migration = env.TEST_MIGRATIONS.find((m) => m.name.startsWith("0006"));
    expect(migration).toBeDefined();
    const run = async () => {
      await db.prepare("DROP TABLE pick_log").run();
      await db.batch(migration!.queries.map((q) => db.prepare(q)));
      return pickLog();
    };

    const first = await run();
    expect(first).toStrictEqual([
      { tmdb_id: 1, title: "First in A", year: 2020, model: SONNET, conversation_id: "a", first_recommended_at: at(1) },
      { tmdb_id: 2, title: "Tie from B", year: 2020, model: OPUS, conversation_id: "b", first_recommended_at: at(3) },
      { tmdb_id: 3, title: "Only B", year: 2020, model: OPUS, conversation_id: "b", first_recommended_at: at(4) },
    ]);
    expect(await run()).toStrictEqual(first);
  });
});

describe("log writes", () => {
  it("a recommendations turn adds pick_log rows matching the stored recommendations", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))]);
    const body = await ok<TurnBody>(await start({ text: "slow dread", model: OPUS }));

    const stored = (
      await env.DB.prepare("SELECT tmdb_id, created_at FROM recommendations ORDER BY tmdb_id").all<{ tmdb_id: number; created_at: string }>()
    ).results;
    expect(await pickLog()).toStrictEqual([
      { tmdb_id: 201, title: "Noroi", year: 2005, model: OPUS, conversation_id: body.conversation.id, first_recommended_at: stored[0]!.created_at },
      { tmdb_id: 202, title: "Kairo", year: 2001, model: OPUS, conversation_id: body.conversation.id, first_recommended_at: stored[1]!.created_at },
    ]);
    // No conversation content in the log.
    const columns = (await env.DB.prepare("SELECT name FROM pragma_table_info('pick_log')").all<{ name: string }>()).results;
    expect(columns.map((c) => c.name)).toEqual(["tmdb_id", "title", "year", "model", "conversation_id", "first_recommended_at"]);
  });

  it("a later turn in the same conversation adds only the new films", async () => {
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005)))]);
    const first = await ok<TurnBody>(await start({ text: "hi" }));
    await tick();
    world.replies.push(claudeReply(recs(pick("Pulse", 2001))));
    await ok(await reply(first.conversation.id, { text: "more" }));

    expect((await pickLog()).map((p) => p.tmdb_id)).toEqual([201, 204]);
  });

  it("a film recommended again later keeps its original row", async () => {
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005)))]);
    await ok(await start({ text: "hi", model: SONNET }));
    const original = await pickLog();
    await tick();

    world.replies.push(claudeReply(recs(pick("Noroi", 2005), pick("Lake Mungo", 2008))));
    const second = await ok<TurnBody>(await start({ text: "again", model: OPUS }));
    expect(second.messages[1]!.recommendations!.map((r) => r.tmdb_id)).toEqual([201, 203]);

    const log = await pickLog();
    expect(log[0]).toStrictEqual(original[0]);
    expect(log[0]!.model).toBe(SONNET);
    expect(log[1]).toMatchObject({ tmdb_id: 203, model: OPUS, conversation_id: second.conversation.id });
    expect(await count("recommendations")).toBe(3);
  });

  it("a turn discarded by mid-turn deletion writes no pick_log rows", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("How long?"))]);
    const first = await ok<TurnBody>(await start({ text: "hi" }));
    const id = first.conversation.id;
    await tick();

    world.replies.push(async () => {
      expect((await authed(`/conversations/${id}`, { method: "DELETE" })).status).toBe(204);
      await tick();
      return claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))();
    });
    await expectError(await reply(id, { text: "Short" }), 404, "not_found");

    expect(await count("recommendations")).toBe(0);
    expect(await count("pick_log")).toBe(0);
  });

  it("deleting a conversation leaves its pick_log rows intact", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))]);
    const body = await ok<TurnBody>(await start({ text: "hi" }));
    const before = await pickLog();
    expect(before).toHaveLength(2);

    expect((await authed(`/conversations/${body.conversation.id}`, { method: "DELETE" })).status).toBe(204);
    expect(await count("recommendations")).toBe(0);
    expect(await pickLog()).toStrictEqual(before);
  });

  it("a question-only turn writes nothing", async () => {
    mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: "hi" }));
    expect(await count("messages")).toBe(2);
    expect(await count("pick_log")).toBe(0);
  });
});

describe("outcomes", () => {
  it("a logged film that appears in ratings after an import is an outcome; an unrated one isn't", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))]);
    await ok(await start({ text: "hi" }));
    expect(await stats()).toMatchObject({ recommended: 2, rated: 0, recent: [] });

    // The import: Noroi watched and rated; an unrelated rated film is not an outcome.
    await seedLibrary([
      { name: "Noroi: The Curse", year: 2005, tmdb_id: 201, horror: true, half_stars: 9, watched: true },
      { name: "Hereditary", year: 2018, tmdb_id: 900, horror: true, half_stars: 10, watched: true },
      // Watched but not rated: not an outcome.
      { name: "Kairo", year: 2001, tmdb_id: 202, horror: true, watched: true },
    ]);
    const body = await stats();
    expect(body).toMatchObject({ recommended: 2, rated: 1, hits: 1 });
    // The log's title (TMDB's), not the library's.
    expect(body.recent.map((r) => [r.tmdb_id, r.title, r.half_stars])).toEqual([[201, "Noroi", 9]]);
  });

  it("half_stars 7 is a hit; 6 is a miss", async () => {
    expect(HIT_THRESHOLD_HALF_STARS).toBe(7);
    await logPicks([{ tmdb_id: 1 }, { tmdb_id: 2 }]);
    await rate([1, 7], [2, 6]);

    const body = await stats();
    expect(body.recent.map((r) => [r.tmdb_id, r.hit])).toEqual([
      [2, false],
      [1, true],
    ]);
    expect(body.hits).toBe(1);
    expect(lines(await systemPrompt())).toEqual([
      `Pick 2 (2020) ${DASH} ${STAR}3 ${DASH} miss`,
      `Pick 1 (2020) ${DASH} ${STAR}3.5 ${DASH} hit`,
    ]);
  });

  it("counts an outcome regardless of decision (yes / maybe / no / none)", async () => {
    await logPicks([{ tmdb_id: 1 }, { tmdb_id: 2 }, { tmdb_id: 3 }, { tmdb_id: 4 }]);
    await rate([1, 8], [2, 8], [3, 8], [4, 8]);
    const now = at(50);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES ('c-d', ?1, 't', 0, ?2, ?2)").bind(SONNET, now),
      ...(["yes", "maybe", "no"] as const).map((decision, i) =>
        env.DB.prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (?, ?, 'c-d', ?)").bind(i + 1, decision, now),
      ),
    ]);

    const body = await stats();
    expect(body).toMatchObject({ rated: 4, hits: 4 });
    expect(body.recent.map((r) => r.tmdb_id)).toEqual([4, 3, 2, 1]);
  });
});

describe("prompt section", () => {
  const HEADINGS = [
    "## Taste profile",
    "## Horror ratings",
    HEADING,
    "## Recent releases you may not know (optional candidates)",
    "## Never recommend (already seen)",
    "## Never recommend (already on watchlist)",
  ];

  it("sits after ratings and before recent releases, with header, guidance, lines and the instruction", async () => {
    await logPicks([
      { tmdb_id: 1, title: "Older Hit", year: 2019, minute: 1 },
      { tmdb_id: 2, title: "Newer Miss", year: 2024, minute: 2 },
      { tmdb_id: 3, title: "No Year", year: null, minute: 3 },
      { tmdb_id: 4, title: "Unrated", minute: 4 },
    ]);
    await rate([1, 9], [2, 4], [3, 10]);
    const system = await systemPrompt();

    const positions = HEADINGS.map((h) => system.indexOf(`\n${h}`));
    expect(positions.every((p) => p > 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
    expect(section(system)).toBe(
      [
        GUIDANCE,
        `No Year ${DASH} ${STAR}5 ${DASH} hit`,
        `Newer Miss (2024) ${DASH} ${STAR}2 ${DASH} miss`,
        `Older Hit (2019) ${DASH} ${STAR}4.5 ${DASH} hit`,
      ].join("\n"),
    );
    expect(system.slice(0, system.indexOf("\n## "))).toContain(
      `The "Harbinger picks they've since rated" section is direct feedback on your earlier recommendations ${DASH} repeat what hit, avoid what missed.`,
    );
  });

  it("orders most recent first (then tmdb_id) and caps at 30", async () => {
    const picks = range(35).map((i) => ({ tmdb_id: i + 1, minute: i + 1 }));
    // Two picks from one turn share a timestamp: tmdb_id breaks the tie.
    picks[34]!.minute = 34;
    await logPicks(picks);
    await rate(...range(35).map((i): [number, number] => [i + 1, 8]));

    const titles = lines(await systemPrompt()).map((l) => l.split(" (")[0]);
    expect(titles).toHaveLength(30);
    expect(titles.slice(0, 3)).toEqual(["Pick 34", "Pick 35", "Pick 33"]);
    expect(titles.at(-1)).toBe("Pick 6");
  });

  it("no outcomes yet → (none yet)", async () => {
    await logPicks([{ tmdb_id: 1 }]);
    expect(section(await systemPrompt())).toBe(`${GUIDANCE}\n(none yet)`);
  });

  it("is byte-identical across two turns, even though the first turn added pick_log rows", async () => {
    await logPicks([{ tmdb_id: 1 }, { tmdb_id: 2 }]);
    await rate([1, 9], [2, 5]);
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001)))]);
    const first = await ok<TurnBody>(await start({ text: "hi" }));
    expect(await count("pick_log")).toBe(4);
    await tick();
    world.replies.push(claudeReply(question("More?")));
    await ok(await reply(first.conversation.id, { text: "more" }));

    const [a, b] = world.claudeCalls.map((c) => c.body.system);
    expect(lines(a!)).toHaveLength(2);
    expect(b).toBe(a);
  });

  it("the taste-profile draft prompt is unchanged by outcomes", async () => {
    await logPicks([{ tmdb_id: 1, title: "Past Pick" }]);
    await rate([1, 9]);
    const world = mockWorld([], [claudeReply({ content: "## Loves\nDread.", changes: [] })]);
    await ok(await send("POST", "/taste-profile/draft", {}));

    const draft = world.claudeCalls[0]!.body;
    expect(JSON.stringify(draft)).not.toContain("Harbinger picks");
    expect(JSON.stringify(draft)).not.toContain("Past Pick");
    expect(draft.messages[0]!.content).toContain(`<horror_ratings>\nLibrary 1 (2020) ${DASH} ${STAR}4.5\n</horror_ratings>`);
  });
});

describe("GET /stats/outcomes", () => {
  it("unauthenticated → 401", async () => {
    await expectError(await call("/stats/outcomes"), 401, "unauthorized");
  });

  it("wrong method → 405", async () => {
    const res = await send("POST", "/stats/outcomes", {});
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
  });

  it("empty → zero counts, null rates, empty lists", async () => {
    expect(await stats()).toStrictEqual({
      hit_threshold_half_stars: 7,
      recommended: 0,
      rated: 0,
      hits: 0,
      hit_rate: null,
      average_half_stars: null,
      by_model: [],
      recent: [],
    });
  });

  it("mixed data → totals, per-model breakdown, rounding, and ordering", async () => {
    await logPicks([
      ...range(5).map((i) => ({ tmdb_id: i + 1, model: SONNET })),
      { tmdb_id: 11, model: OPUS },
      { tmdb_id: 12, model: OPUS },
      { tmdb_id: 21, model: HAIKU },
      { tmdb_id: 22, model: HAIKU },
    ]);
    await rate([1, 9], [2, 7], [3, 6], [11, 5]);

    expect(await stats()).toStrictEqual({
      hit_threshold_half_stars: 7,
      recommended: 9,
      rated: 4,
      hits: 2,
      hit_rate: 0.5,
      // 27 / 4 = 6.75
      average_half_stars: 6.8,
      by_model: [
        { model: SONNET, recommended: 5, rated: 3, hits: 2, hit_rate: 0.667 },
        // Tied on recommended: by model name.
        { model: HAIKU, recommended: 2, rated: 0, hits: 0, hit_rate: null },
        { model: OPUS, recommended: 2, rated: 1, hits: 0, hit_rate: 0 },
      ],
      recent: [
        { tmdb_id: 11, title: "Pick 11", year: 2020, half_stars: 5, hit: false, model: OPUS, first_recommended_at: at(11) },
        { tmdb_id: 3, title: "Pick 3", year: 2020, half_stars: 6, hit: false, model: SONNET, first_recommended_at: at(3) },
        { tmdb_id: 2, title: "Pick 2", year: 2020, half_stars: 7, hit: true, model: SONNET, first_recommended_at: at(2) },
        { tmdb_id: 1, title: "Pick 1", year: 2020, half_stars: 9, hit: true, model: SONNET, first_recommended_at: at(1) },
      ],
    });
  });

  it("caps recent at the 20 most recent outcomes while totals cover them all", async () => {
    await logPicks(range(25).map((i) => ({ tmdb_id: i + 1 })));
    await rate(...range(25).map((i): [number, number] => [i + 1, i % 2 === 0 ? 8 : 4]));

    const body = await stats();
    expect(body).toMatchObject({ recommended: 25, rated: 25, hits: 13, hit_rate: 0.52 });
    expect(body.recent.map((r) => r.tmdb_id)).toEqual(range(20).map((i) => 25 - i));
  });

  it("works with ANTHROPIC_API_KEY and TMDB_READ_TOKEN unset, with no outbound request", async () => {
    await logPicks([{ tmdb_id: 1 }]);
    const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new Error("fetch must not be called");
    });
    const request = new Request(`${BASE}/stats/outcomes`, {
      headers: { Authorization: `Bearer ${env.API_KEY}` },
    }) as Parameters<typeof worker.fetch>[0];
    const res = await worker.fetch(request, { ...env, ANTHROPIC_API_KEY: "", TMDB_READ_TOKEN: "" } as Env);

    expect(await ok(res)).toMatchObject({ recommended: 1, rated: 0 });
    expect(spy).not.toHaveBeenCalled();
  });
});
