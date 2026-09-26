import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { OVERLAP_MS } from "../src/sync/handlers";
import { clearAll } from "./conversations-helpers";
import { BASE, authed, call, expectError, ok } from "./helpers";

/** 2026-09-26T12:MM:00.000Z */
const T = (minute: number) => new Date(Date.UTC(2026, 8, 26, 12, minute)).toISOString();

interface SyncBody {
  server_time: string;
  next_since: string;
  conversations: { id: string; updated_at: string }[];
  messages: { id: string; conversation_id: string; seq: number; content: unknown }[];
  recommendations: Record<string, unknown>[];
  decisions: { tmdb_id: number; decision: string }[];
  taste_profile: { content: string; based_on_import_id: number | null; updated_at: string } | null;
  last_import_at: string | null;
}

const pull = async (since?: string) =>
  ok<SyncBody>(await authed(since === undefined ? "/sync" : `/sync?${new URLSearchParams({ since })}`));

const ENRICHED = {
  tmdb_id: 11,
  title: "Noroi",
  original_title: "Noroi",
  release_date: "2005-08-20",
  genres: [{ id: 27, name: "Horror" }],
  is_horror: true,
  runtime: 115,
  overview: "A curse.",
  poster_path: "/n.jpg",
  director: "Koji Shiraishi",
  providers: [{ name: "Shudder", type: "flatrate", logo_path: "/s.png" }],
  providers_link: "https://tmdb/11",
  trailer_key: "abc",
};
// A W4a-era row: no enrichment fields.
const { director: _d, providers: _p, providers_link: _l, trailer_key: _t, ...W4A_ERA } = { ...ENRICHED, tmdb_id: 12 };

async function insertConversation(id: string, updatedAt: string, createdAt = T(0)) {
  await env.DB.prepare(
    "INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES (?, 'claude-sonnet-5', ?, 0, ?, ?)",
  )
    .bind(id, `Title ${id}`, createdAt, updatedAt)
    .run();
}

async function insertMessage(id: string, conversationId: string, seq: number, content: unknown, createdAt: string) {
  const role = seq % 2 === 1 ? "user" : "assistant";
  const kind = role === "user" ? "text" : "recommendations";
  await env.DB.prepare(
    "INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(id, conversationId, seq, role, kind, JSON.stringify(content), createdAt)
    .run();
}

async function insertRecommendation(
  id: string,
  conversationId: string,
  messageId: string,
  position: number,
  details: { tmdb_id: number; title: string },
  createdAt: string,
) {
  await env.DB.prepare(
    `INSERT INTO recommendations (id, conversation_id, message_id, position, tmdb_id, title, year, why_short, why_full, tmdb_json, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 2005, 'short', 'full', ?, ?)`,
  )
    .bind(id, conversationId, messageId, position, details.tmdb_id, details.title, JSON.stringify(details), createdAt)
    .run();
}

async function insertDecision(tmdbId: number, decision: string, conversationId: string, decidedAt: string) {
  await env.DB.prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (?, ?, ?, ?)")
    .bind(tmdbId, decision, conversationId, decidedAt)
    .run();
}

async function insertImport(importedAt: string): Promise<number> {
  const row = await env.DB.prepare(
    `INSERT INTO imports (imported_at, source_filename, ratings_count, watched_count, watchlist_count, likes_count, new_films_count)
     VALUES (?, 'x.zip', 0, 0, 0, 0, 0) RETURNING id`,
  )
    .bind(importedAt)
    .first<{ id: number }>();
  return row!.id;
}

async function saveProfile(updatedAt: string, importId: number | null) {
  await env.DB.prepare(
    "INSERT INTO taste_profile (id, content, based_on_import_id, updated_at) VALUES (1, '## Loves\nDread.', ?, ?)",
  )
    .bind(importId, updatedAt)
    .run();
}

/**
 * A (updated 12:30) with two exchanges — its first messages created at 12:01,
 * its latest user message stamped 12:15 but committed with A at 12:30 (the
 * slow-Claude trap) — and B (updated 12:10). Decisions at 12:05 and 12:25,
 * profile at 12:25, imports at 12:02 and 12:03.
 */
async function seed(): Promise<void> {
  await insertConversation("A", T(30));
  await insertMessage("a1", "A", 1, { text: "hi", just_pick: false }, T(1));
  await insertMessage("a2", "A", 2, { dropped: 0 }, T(1));
  await insertRecommendation("ra1", "A", "a2", 1, ENRICHED, T(1));
  await insertRecommendation("ra2", "A", "a2", 2, W4A_ERA, T(1));
  await insertMessage("a3", "A", 3, { text: null, just_pick: true }, T(15));
  await insertMessage("a4", "A", 4, { dropped: 1 }, T(30));

  await insertConversation("B", T(10));
  await insertMessage("b1", "B", 1, { text: "old", just_pick: false }, T(9));

  await insertDecision(11, "maybe", "A", T(5));
  await insertDecision(12, "no", "A", T(25));
  await insertImport(T(2));
  const latest = await insertImport(T(3));
  await saveProfile(T(25), latest);
}

beforeEach(async () => {
  await clearAll();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /sync — access", () => {
  it("requires auth and only allows GET", async () => {
    await expectError(await call("/sync"), 401, "unauthorized");
    const res = await authed("/sync", { method: "POST" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
  });

  it("works with ANTHROPIC_API_KEY and TMDB_READ_TOKEN unset, with no outbound fetch", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new Error("fetch must not be called");
    });
    const request = new Request(`${BASE}/sync`, {
      headers: { Authorization: `Bearer ${env.API_KEY}` },
    }) as Parameters<typeof worker.fetch>[0];
    const res = await worker.fetch(request, { ...env, ANTHROPIC_API_KEY: "", TMDB_READ_TOKEN: "" } as Env);
    expect(res.status).toBe(200);
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("GET /sync — full pull", () => {
  it("empty DB → empty arrays, null profile and import, both timestamps", async () => {
    const body = await pull();
    expect(body).toStrictEqual({
      server_time: expect.any(String),
      next_since: expect.any(String),
      conversations: [],
      messages: [],
      recommendations: [],
      decisions: [],
      taste_profile: null,
      last_import_at: null,
    });
  });

  it("returns every row, flat, in the documented order and shapes", async () => {
    await seed();
    const body = await pull();

    // Ordered by updated_at.
    expect(body.conversations).toStrictEqual([
      { id: "B", title: "Title B", model: "claude-sonnet-5", question_rounds: 0, created_at: T(0), updated_at: T(10) },
      { id: "A", title: "Title A", model: "claude-sonnet-5", question_rounds: 0, created_at: T(0), updated_at: T(30) },
    ]);
    // By conversation_id, seq; content parsed; conversation_id present.
    expect(body.messages.map((m) => m.id)).toEqual(["a1", "a2", "a3", "a4", "b1"]);
    expect(body.messages[0]).toStrictEqual({
      id: "a1",
      conversation_id: "A",
      seq: 1,
      role: "user",
      kind: "text",
      content: { text: "hi", just_pick: false },
      created_at: T(1),
    });
    expect(body.messages[1]).not.toHaveProperty("recommendations");

    // Flat, full W4b field set; W4a-era row renders null / [] / null.
    expect(body.recommendations).toStrictEqual([
      {
        id: "ra1",
        conversation_id: "A",
        message_id: "a2",
        position: 1,
        tmdb_id: 11,
        title: "Noroi",
        year: 2005,
        why_short: "short",
        why_full: "full",
        poster_path: "/n.jpg",
        runtime: 115,
        overview: "A curse.",
        director: "Koji Shiraishi",
        providers: [{ name: "Shudder", type: "flatrate", logo_path: "/s.png" }],
        providers_link: "https://tmdb/11",
        trailer_key: "abc",
        created_at: T(1),
      },
      expect.objectContaining({
        id: "ra2",
        position: 2,
        director: null,
        providers: [],
        providers_link: null,
        trailer_key: null,
      }),
    ]);

    expect(body.decisions).toStrictEqual([
      { tmdb_id: 11, decision: "maybe", conversation_id: "A", decided_at: T(5) },
      { tmdb_id: 12, decision: "no", conversation_id: "A", decided_at: T(25) },
    ]);
    expect(body.taste_profile).toStrictEqual({
      content: "## Loves\nDread.",
      based_on_import_id: expect.any(Number),
      updated_at: T(25),
    });
    expect(body.last_import_at).toBe(T(3));
  });
});

describe("GET /sync — delta", () => {
  it("since after all activity → empty arrays, null profile, import time still present", async () => {
    await seed();
    const body = await pull(T(40));
    expect(body).toMatchObject({
      conversations: [],
      messages: [],
      recommendations: [],
      decisions: [],
      taste_profile: null,
      last_import_at: T(3),
    });
  });

  it("a changed conversation returns all of its messages and recommendations; nothing from others", async () => {
    await seed();
    const body = await pull(T(20));
    expect(body.conversations.map((c) => c.id)).toEqual(["A"]);
    expect(body.messages.map((m) => m.id)).toEqual(["a1", "a2", "a3", "a4"]);
    expect(body.recommendations.map((r) => r.id)).toEqual(["ra1", "ra2"]);
    expect(body.messages.some((m) => m.conversation_id === "B")).toBe(false);
    expect(body.last_import_at).toBe(T(3));
  });

  it("the trap: a message created before since, committed with its conversation after, is returned", async () => {
    await seed();
    // a3 was stamped 12:15 (before the Claude call) but committed at 12:30 with A.
    const body = await pull(T(20));
    const trapped = body.messages.find((m) => m.id === "a3");
    expect(trapped).toMatchObject({ conversation_id: "A", seq: 3, content: { text: null, just_pick: true } });
  });

  it("returns decisions and the profile only when changed after since", async () => {
    await seed();
    const mid = await pull(T(20));
    expect(mid.decisions).toStrictEqual([{ tmdb_id: 12, decision: "no", conversation_id: "A", decided_at: T(25) }]);
    expect(mid.taste_profile?.updated_at).toBe(T(25));

    const late = await pull(T(26));
    expect(late.decisions).toEqual([]);
    expect(late.taste_profile).toBeNull();
    expect(late.conversations.map((c) => c.id)).toEqual(["A"]);
  });

  it("is read-only", async () => {
    await seed();
    const before = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM conversations) + (SELECT COUNT(*) FROM messages) + (SELECT COUNT(*) FROM decisions) AS n",
    ).first();
    await pull();
    await pull(T(20));
    const after = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM conversations) + (SELECT COUNT(*) FROM messages) + (SELECT COUNT(*) FROM decisions) AS n",
    ).first();
    expect(after).toStrictEqual(before);
  });
});

describe("GET /sync — cursor", () => {
  it("next_since = server_time − 120 s", async () => {
    const body = await pull();
    expect(Date.parse(body.server_time) - Date.parse(body.next_since)).toBe(OVERLAP_MS);
    expect(OVERLAP_MS).toBe(120_000);
    expect(new Date(body.next_since).toISOString()).toBe(body.next_since);
  });

  it("normalizes a non-UTC offset before comparing", async () => {
    await insertConversation("early", T(19));
    await insertConversation("late", T(21));
    // 08:20-04:00 is 12:20Z. Compared as a raw string it would include both.
    const body = await pull("2026-09-26T08:20:00-04:00");
    expect(body.conversations.map((c) => c.id)).toEqual(["late"]);
  });

  it("invalid since → 400", async () => {
    for (const since of ["yesterday", "2026-13-01", "", "not-a-date"]) {
      await expectError(await authed(`/sync?${new URLSearchParams({ since })}`), 400, "invalid_request");
    }
  });
});
