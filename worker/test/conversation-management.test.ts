import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import {
  type CatalogFilm,
  type World,
  claudeReply,
  clearAll,
  film,
  mockWorld,
  pick,
  question,
  recs,
  seedLibrary,
} from "./conversations-helpers";
import { BASE, authed, call, count, expectError, ok, send, tick } from "./helpers";

// W7: DELETE /conversations/{id} (soft delete) and PATCH /conversations/{id} (rename).

const CATALOG: CatalogFilm[] = [film(601, "Noroi", 2005), film(602, "Kairo", 2001), film(603, "Lake Mungo", 2008)];

interface ApiConversation {
  id: string;
  title: string | null;
  model: string;
  question_rounds: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

interface TurnBody {
  conversation: ApiConversation;
  messages: { id: string; recommendations?: { title: string }[] }[];
}

interface SyncBody {
  conversations: ApiConversation[];
  messages: { id: string; conversation_id: string }[];
  recommendations: { id: string; conversation_id: string }[];
  decisions: { tmdb_id: number; decision: string; conversation_id: string }[];
}

type Row = Record<string, unknown>;

const remove = (id: string) => authed(`/conversations/${id}`, { method: "DELETE" });
const rename = (id: string, body: unknown) => send("PATCH", `/conversations/${id}`, body);
const decide = (tmdbId: number, decision: string, id: string) =>
  send("PUT", `/decisions/${tmdbId}`, { decision, conversation_id: id });
const pull = async (since?: string) =>
  ok<SyncBody>(await authed(since === undefined ? "/sync" : `/sync?${new URLSearchParams({ since })}`));

const conversationRow = (id: string) => env.DB.prepare("SELECT * FROM conversations WHERE id = ?").bind(id).first<Row>();

async function rowsOf(table: "messages" | "recommendations", id: string): Promise<Row[]> {
  const { results } = await env.DB.prepare(`SELECT * FROM ${table} WHERE conversation_id = ? ORDER BY id`)
    .bind(id)
    .all<Row>();
  return results;
}

const decisions = async () =>
  (await env.DB.prepare("SELECT * FROM decisions ORDER BY tmdb_id").all<Row>()).results;

/** Starts a conversation recommending the given catalog films. */
async function conversationWith(world: World, ...picks: [string, number][]): Promise<TurnBody> {
  world.replies.push(claudeReply(recs(...picks.map(([title, year]) => pick(title, year)))));
  return ok<TurnBody>(await send("POST", "/conversations", { text: "Something bleak and slow" }));
}

/** A timestamp strictly between the writes before and after it. */
async function between(): Promise<string> {
  await tick();
  const at = new Date().toISOString();
  await tick();
  return at;
}

let log: ReturnType<typeof vi.spyOn>;
const rejections = () =>
  log.mock.calls
    .map(([line]: unknown[]) => (typeof line === "string" && line.startsWith("{") ? JSON.parse(line) : null))
    .filter((l: Record<string, unknown> | null) => l?.event === "pick_rejected")
    .map((l: Record<string, unknown>) => [l.title, l.reason]);

beforeEach(async () => {
  await clearAll();
  await seedLibrary([{ name: "Hereditary", year: 2018, horror: true, half_stars: 10, watched: true }]);
  log = vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("migration 0004", () => {
  it("adds conversations.deleted_at, NULL unless set", async () => {
    await env.DB.prepare(
      "INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES ('old', 'm', 't', 0, 'x', 'x')",
    ).run();
    expect(await conversationRow("old")).toMatchObject({ id: "old", deleted_at: null });
  });
});

describe("access", () => {
  it("requires auth, and the route allows GET, PATCH, DELETE", async () => {
    await expectError(await call("/conversations/x", { method: "DELETE" }), 401, "unauthorized");
    await expectError(
      await call("/conversations/x", { method: "PATCH", body: JSON.stringify({ title: "t" }) }),
      401,
      "unauthorized",
    );
    const res = await authed("/conversations/x", { method: "PUT" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET, PATCH, DELETE");
  });

  it("delete and rename work with ANTHROPIC_API_KEY and TMDB_READ_TOKEN unset, with no outbound fetch", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    vi.restoreAllMocks();
    const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new Error("fetch must not be called");
    });
    const bare = (init: RequestInit) => {
      const request = new Request(`${BASE}/conversations/${conversation.id}`, {
        ...init,
        headers: { Authorization: `Bearer ${env.API_KEY}` },
      }) as Parameters<typeof worker.fetch>[0];
      return worker.fetch(request, { ...env, ANTHROPIC_API_KEY: "", TMDB_READ_TOKEN: "" } as Env);
    };
    expect((await bare({ method: "PATCH", body: JSON.stringify({ title: "Renamed" }) })).status).toBe(200);
    expect((await bare({ method: "DELETE" })).status).toBe(204);
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("DELETE /conversations/{id}", () => {
  it("removes the content, keeps a tombstone, and leaves decisions and other conversations alone", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005], ["Kairo", 2001], ["Lake Mungo", 2008]);
    const b = await conversationWith(world, ["Noroi", 2005]);
    const id = a.conversation.id;
    await ok(await decide(601, "yes", id));
    await ok(await decide(602, "no", id));
    await ok(await decide(603, "maybe", id));
    const decisionsBefore = await decisions();
    const otherMessages = await rowsOf("messages", b.conversation.id);
    const otherRecommendations = await rowsOf("recommendations", b.conversation.id);
    await tick();

    const res = await remove(id);
    expect(res.status).toBe(204);
    expect(await res.text()).toBe("");
    expect(res.headers.get("Cache-Control")).toBe("no-store");

    expect(await rowsOf("messages", id)).toEqual([]);
    expect(await rowsOf("recommendations", id)).toEqual([]);
    const tombstone = await conversationRow(id);
    expect(tombstone).toStrictEqual({
      id,
      model: a.conversation.model,
      title: null,
      question_rounds: 0,
      created_at: a.conversation.created_at,
      updated_at: expect.any(String),
      deleted_at: expect.any(String),
    });
    expect(tombstone!.updated_at).toBe(tombstone!.deleted_at);
    expect((tombstone!.updated_at as string) > a.conversation.updated_at).toBe(true);

    expect(decisionsBefore).toHaveLength(3);
    expect(await decisions()).toStrictEqual(decisionsBefore);
    expect(await rowsOf("messages", b.conversation.id)).toStrictEqual(otherMessages);
    expect(await rowsOf("recommendations", b.conversation.id)).toStrictEqual(otherRecommendations);
    expect(otherMessages).toHaveLength(2);
    expect(otherRecommendations).toHaveLength(1);
    expect(await conversationRow(b.conversation.id)).toMatchObject({ deleted_at: null, title: b.conversation.title });
  });

  it("is idempotent: deleting again → 204, tombstone unchanged; unknown id → 404", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    expect((await remove(conversation.id)).status).toBe(204);
    const tombstone = await conversationRow(conversation.id);
    await tick();

    expect((await remove(conversation.id)).status).toBe(204);
    expect(await conversationRow(conversation.id)).toStrictEqual(tombstone);
    await expectError(await remove("missing"), 404, "not_found");
  });
});

describe("PATCH /conversations/{id}", () => {
  it("stores the trimmed title, bumps updated_at, returns the conversation, and changes nothing else", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("How long?", ["Short"]))]);
    const first = await ok<TurnBody>(await send("POST", "/conversations", { text: "hi" }));
    const id = first.conversation.id;
    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    await ok(await send("POST", `/conversations/${id}/messages`, { text: "Short" }));
    await ok(await decide(601, "maybe", id));
    const before = await conversationRow(id);
    const messages = await rowsOf("messages", id);
    const recommendations = await rowsOf("recommendations", id);
    const decisionsBefore = await decisions();
    await tick();

    const body = await ok<ApiConversation>(await rename(id, { title: "  Folk horror night \n", ignored: true }));
    expect(body).toStrictEqual({
      id,
      title: "Folk horror night",
      model: first.conversation.model,
      question_rounds: 1,
      created_at: first.conversation.created_at,
      updated_at: expect.any(String),
      deleted_at: null,
    });
    expect(body.updated_at > (before!.updated_at as string)).toBe(true);
    expect(await conversationRow(id)).toStrictEqual({ ...before, title: "Folk horror night", updated_at: body.updated_at });
    expect(await rowsOf("messages", id)).toStrictEqual(messages);
    expect(await rowsOf("recommendations", id)).toStrictEqual(recommendations);
    expect(await decisions()).toStrictEqual(decisionsBefore);
    expect(world.claudeCalls).toHaveLength(2);

    // Same title again: a normal update.
    await tick();
    const again = await ok<ApiConversation>(await rename(id, { title: "Folk horror night" }));
    expect(again.title).toBe("Folk horror night");
    expect(again.updated_at > body.updated_at).toBe(true);
  });

  it("counts the 1–100 character limit in code points, after trimming", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    const id = conversation.id;
    const ghost = String.fromCodePoint(0x1f47b); // two UTF-16 units
    const eAcute = String.fromCodePoint(0xe9);

    expect((await ok<ApiConversation>(await rename(id, { title: "x".repeat(100) }))).title).toBe("x".repeat(100));
    const mixed = ghost.repeat(50) + eAcute.repeat(50);
    expect(mixed.length).toBe(150);
    expect((await ok<ApiConversation>(await rename(id, { title: ` ${mixed} ` }))).title).toBe(mixed);
    expect((await conversationRow(id))!.title).toBe(mixed);

    expect(await expectError(await rename(id, { title: "x".repeat(101) }), 400, "invalid_request")).toContain("title");
    await expectError(await rename(id, { title: ghost.repeat(101) }), 400, "invalid_request");
    await expectError(await rename(id, { title: "" }), 400, "invalid_request");
    await expectError(await rename(id, { title: " \n\t " }), 400, "invalid_request");
    expect((await conversationRow(id))!.title).toBe(mixed);
  });

  it("rejects a null, missing, or non-string title and malformed JSON", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    const id = conversation.id;
    await expectError(await rename(id, { title: null }), 400, "invalid_request");
    await expectError(await rename(id, {}), 400, "invalid_request");
    await expectError(await rename(id, { title: 42 }), 400, "invalid_request");
    await expectError(await rename(id, ["title"]), 400, "invalid_request");
    await expectError(await authed(`/conversations/${id}`, { method: "PATCH", body: "{not json" }), 400, "invalid_json");
    expect((await conversationRow(id))!.title).toBe(conversation.title);
  });

  it("unknown id → 404; deleted conversation → 404 with the tombstone unchanged", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    await expectError(await rename("missing", { title: "x" }), 404, "not_found");
    await remove(conversation.id);
    const tombstone = await conversationRow(conversation.id);
    await tick();
    await expectError(await rename(conversation.id, { title: "x" }), 404, "not_found");
    expect(await conversationRow(conversation.id)).toStrictEqual(tombstone);
  });

  it("a later turn keeps the renamed title", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("How long?"))]);
    const first = await ok<TurnBody>(await send("POST", "/conversations", { text: "hi" }));
    const id = first.conversation.id;
    await ok(await rename(id, { title: "Renamed" }));

    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    const next = await ok<TurnBody>(await send("POST", `/conversations/${id}/messages`, { text: "Short" }));
    expect(next.conversation.title).toBe("Renamed");
    expect((await conversationRow(id))!.title).toBe("Renamed");
  });

  it("a /sync delta after a rename carries the new title with the conversation's messages and recommendations", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005]);
    const b = await conversationWith(world, ["Kairo", 2001]);
    const since = await between();
    await ok(await rename(a.conversation.id, { title: "Renamed" }));

    const delta = await pull(since);
    expect(delta.conversations.map((c) => [c.id, c.title, c.deleted_at])).toEqual([[a.conversation.id, "Renamed", null]]);
    expect(delta.messages.map((m) => m.id).sort()).toEqual(a.messages.map((m) => m.id).sort());
    expect(delta.recommendations.map((r) => r.conversation_id)).toEqual([a.conversation.id]);
    expect(delta.messages.some((m) => m.conversation_id === b.conversation.id)).toBe(false);
  });
});

describe("a deleted conversation elsewhere", () => {
  it("GET, POST messages, and PUT decisions → 404, with no Claude call", async () => {
    const world = mockWorld(CATALOG, []);
    const { conversation } = await conversationWith(world, ["Noroi", 2005]);
    const id = conversation.id;
    await remove(id);
    const tombstone = await conversationRow(id);
    const calls = world.claudeCalls.length;

    await expectError(await authed(`/conversations/${id}`), 404, "not_found");
    await expectError(await send("POST", `/conversations/${id}/messages`, { text: "more" }), 404, "not_found");
    await expectError(await decide(601, "yes", id), 404, "not_found");
    expect(world.claudeCalls).toHaveLength(calls);
    expect(await count("messages")).toBe(0);
    expect(await count("decisions")).toBe(0);
    expect(await conversationRow(id)).toStrictEqual(tombstone);
  });

  it("a no made in it still excludes the film in a new conversation", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005]);
    await ok(await decide(601, "no", a.conversation.id));
    expect((await remove(a.conversation.id)).status).toBe(204);

    world.replies.push(
      claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001))),
      claudeReply(question("?")),
      claudeReply(question("?")),
    );
    const b = await ok<TurnBody>(await send("POST", "/conversations", { text: "again" }));
    expect(b.messages[1]!.recommendations!.map((r) => r.title)).toEqual(["Kairo"]);
    expect(rejections()).toEqual([["Noroi", "excluded"]]);
  });

  it("a maybe made in it no longer excludes anything", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005]);
    await ok(await decide(601, "maybe", a.conversation.id));
    expect((await remove(a.conversation.id)).status).toBe(204);

    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    const b = await ok<TurnBody>(await send("POST", "/conversations", { text: "again" }));
    expect(b.messages[1]!.recommendations!.map((r) => r.title)).toEqual(["Noroi"]);
    expect(rejections()).toEqual([]);
  });
});

describe("deletion during an in-flight turn", () => {
  // The delete lands while the turn waits on Claude: after loadConversation, before saveTurn.
  async function deletedMidTurn(reply: unknown): Promise<void> {
    const world = mockWorld(CATALOG, [claudeReply(question("How long?"))]);
    const first = await ok<TurnBody>(await send("POST", "/conversations", { text: "hi" }));
    const id = first.conversation.id;
    await tick();

    let tombstone: Row | null = null;
    world.replies.push(async () => {
      expect((await remove(id)).status).toBe(204);
      tombstone = await conversationRow(id);
      await tick();
      return claudeReply(reply)();
    });
    await expectError(await send("POST", `/conversations/${id}/messages`, { text: "Short" }), 404, "not_found");

    expect(tombstone).toMatchObject({ id, title: null, deleted_at: expect.any(String) });
    expect(await conversationRow(id)).toStrictEqual(tombstone);
    expect(await count("messages")).toBe(0);
    expect(await count("recommendations")).toBe(0);
  }

  it("a recommendations turn → 404, nothing written, tombstone unchanged", async () => {
    await deletedMidTurn(recs(pick("Noroi", 2005), pick("Kairo", 2001)));
  });

  it("a question turn → 404, nothing written, tombstone unchanged", async () => {
    await deletedMidTurn(question("Era?"));
  });
});

describe("GET /sync tombstones", () => {
  it("a full pull has live conversations only, each with deleted_at: null, and still every decision", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005]);
    const b = await conversationWith(world, ["Kairo", 2001]);
    await ok(await decide(601, "no", a.conversation.id));
    await remove(a.conversation.id);

    const body = await pull();
    expect(body.conversations.map((c) => [c.id, c.deleted_at])).toEqual([[b.conversation.id, null]]);
    expect(body.messages.every((m) => m.conversation_id === b.conversation.id)).toBe(true);
    expect(body.messages).toHaveLength(2);
    expect(body.recommendations.map((r) => r.conversation_id)).toEqual([b.conversation.id]);
    expect(body.decisions).toEqual([
      { tmdb_id: 601, decision: "no", conversation_id: a.conversation.id, decided_at: expect.any(String) },
    ]);
  });

  it("a delta after a deletion carries the tombstone and none of its content", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWith(world, ["Noroi", 2005]);
    await conversationWith(world, ["Kairo", 2001]);
    const since = await between();
    await remove(a.conversation.id);

    const delta = await pull(since);
    expect(delta.conversations).toStrictEqual([
      {
        id: a.conversation.id,
        title: null,
        model: a.conversation.model,
        question_rounds: 0,
        created_at: a.conversation.created_at,
        updated_at: expect.any(String),
        deleted_at: expect.any(String),
      },
    ]);
    expect(delta.messages).toEqual([]);
    expect(delta.recommendations).toEqual([]);

    // Re-sent within the overlap window; a later cursor no longer sees it.
    expect((await pull(since)).conversations).toHaveLength(1);
    expect((await pull(await between())).conversations).toEqual([]);
  });

  it("an orphaned row under a tombstone is never synced", async () => {
    const { conversation } = await conversationWith(mockWorld(CATALOG, []), ["Noroi", 2005]);
    const since = await between();
    await remove(conversation.id);
    await env.DB.prepare(
      "INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES ('orphan', ?, 1, 'user', 'text', '{}', 'x')",
    )
      .bind(conversation.id)
      .run();
    expect((await pull(since)).messages).toEqual([]);
    expect((await pull()).messages).toEqual([]);
  });
});
