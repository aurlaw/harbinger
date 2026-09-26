import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  type CatalogFilm,
  claudeReply,
  clearAll,
  film,
  mockWorld,
  pick,
  question,
  recs,
  seedLibrary,
} from "./conversations-helpers";
import { authed, count, expectError, ok, send } from "./helpers";

const CATALOG: CatalogFilm[] = [film(601, "Noroi", 2005), film(602, "Kairo", 2001), film(603, "Lake Mungo", 2008)];

interface Decision {
  tmdb_id: number;
  decision: string;
  conversation_id: string;
  decided_at: string;
}

const decide = (tmdbId: number | string, body: unknown) => send("PUT", `/decisions/${tmdbId}`, body);

let log: ReturnType<typeof vi.spyOn>;
const rejections = () =>
  log.mock.calls
    .map(([line]: unknown[]) => (typeof line === "string" && line.startsWith("{") ? JSON.parse(line) : null))
    .filter((l: Record<string, unknown> | null) => l?.event === "pick_rejected")
    .map((l: Record<string, unknown>) => [l.title, l.reason]);

/** Starts a conversation whose only pick is Noroi (601). */
async function conversationWithNoroi(world: ReturnType<typeof mockWorld>): Promise<string> {
  world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
  const body = await ok<{ conversation: { id: string } }>(await send("POST", "/conversations", { text: "hi" }));
  return body.conversation.id;
}

beforeEach(async () => {
  await clearAll();
  await seedLibrary([{ name: "Hereditary", year: 2018, horror: true, half_stars: 10, watched: true }]);
  log = vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("PUT /decisions/{tmdb_id}", () => {
  it("stores yes / maybe / no with decided_at and returns the row", async () => {
    const world = mockWorld(CATALOG, []);
    const id = await conversationWithNoroi(world);
    for (const decision of ["yes", "maybe", "no"]) {
      const body = await ok<Decision>(await decide(601, { decision, conversation_id: id }));
      expect(body).toStrictEqual({ tmdb_id: 601, decision, conversation_id: id, decided_at: expect.any(String) });
      expect(new Date(body.decided_at).toISOString()).toBe(body.decided_at);
    }
  });

  it("changing maybe → yes updates the same row", async () => {
    const world = mockWorld(CATALOG, []);
    const id = await conversationWithNoroi(world);
    await ok(await decide(601, { decision: "maybe", conversation_id: id }));
    await ok(await decide(601, { decision: "yes", conversation_id: id }));
    expect(await count("decisions")).toBe(1);
    const row = await env.DB.prepare("SELECT decision FROM decisions WHERE tmdb_id = 601").first<{ decision: string }>();
    expect(row?.decision).toBe("yes");
  });

  it("re-deciding a maybe in a later conversation moves its scope", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWithNoroi(world);
    const b = await conversationWithNoroi(world);
    await ok(await decide(601, { decision: "maybe", conversation_id: a }));
    const moved = await ok<Decision>(await decide(601, { decision: "maybe", conversation_id: b }));
    expect(moved.conversation_id).toBe(b);
    expect(await count("decisions")).toBe(1);
  });

  it("rejects bad decisions and tmdb_ids with 400", async () => {
    for (const decision of ["Yes", "YES", "undecided", "", 1, null]) {
      await expectError(await decide(601, { decision, conversation_id: "c" }), 400, "invalid_request");
    }
    await expectError(await decide(601, { decision: "yes" }), 400, "invalid_request");
    await expectError(await decide(601, { decision: "yes", conversation_id: "" }), 400, "invalid_request");
    for (const id of ["abc", "0", "0601", "-1", "1.5", "12345678901"]) {
      await expectError(await decide(id, { decision: "yes", conversation_id: "c" }), 400, "invalid_request");
    }
    expect(await count("decisions")).toBe(0);
  });

  it("unknown conversation → 404; film not recommended there → 422 not_recommended", async () => {
    const world = mockWorld(CATALOG, []);
    const id = await conversationWithNoroi(world);
    await expectError(await decide(601, { decision: "yes", conversation_id: "nope" }), 404, "not_found");
    await expectError(await decide(602, { decision: "yes", conversation_id: id }), 422, "not_recommended");
    expect(await count("decisions")).toBe(0);
  });

  it("does not touch conversations.updated_at", async () => {
    const world = mockWorld(CATALOG, []);
    const id = await conversationWithNoroi(world);
    const before = await env.DB.prepare("SELECT updated_at FROM conversations WHERE id = ?").bind(id).first();
    await ok(await decide(601, { decision: "no", conversation_id: id }));
    const after = await env.DB.prepare("SELECT updated_at FROM conversations WHERE id = ?").bind(id).first();
    expect(after).toStrictEqual(before);
  });

  it("405 for other methods; no DELETE", async () => {
    const res = await authed("/decisions/601", { method: "DELETE" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("PUT");
  });
});

describe("decisions flow into W4b's exclusion set", () => {
  it("after no: a later conversation rejects the film as excluded", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWithNoroi(world);
    await ok(await decide(601, { decision: "no", conversation_id: a }));

    world.replies.push(
      claudeReply(recs(pick("Noroi", 2005), pick("Kairo", 2001))),
      claudeReply(question("?")),
      claudeReply(question("?")),
    );
    const b = await ok<{ messages: { recommendations?: { title: string }[] }[] }>(
      await send("POST", "/conversations", { text: "again" }),
    );
    expect(b.messages[1]!.recommendations!.map((r) => r.title)).toEqual(["Kairo"]);
    expect(rejections()).toEqual([["Noroi", "excluded"]]);
  });

  it("after maybe: rejected in the same conversation, allowed in a new one", async () => {
    const world = mockWorld(CATALOG, []);
    const a = await conversationWithNoroi(world);
    await ok(await decide(601, { decision: "maybe", conversation_id: a }));

    // Same conversation.
    world.replies.push(
      claudeReply(recs(pick("Noroi", 2005), pick("Lake Mungo", 2008))),
      claudeReply(question("?")),
      claudeReply(question("?")),
    );
    const same = await ok<{ messages: { recommendations?: { title: string }[] }[] }>(
      await send("POST", `/conversations/${a}/messages`, { text: "more" }),
    );
    expect(same.messages[1]!.recommendations!.map((r) => r.title)).toEqual(["Lake Mungo"]);
    expect(rejections()).toEqual([["Noroi", "excluded"]]);

    // New conversation.
    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    const fresh = await ok<{ messages: { recommendations?: { title: string }[] }[] }>(
      await send("POST", "/conversations", { text: "new" }),
    );
    expect(fresh.messages[1]!.recommendations!.map((r) => r.title)).toEqual(["Noroi"]);
  });
});
