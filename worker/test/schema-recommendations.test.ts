import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const db = env.DB;
const NOW = "2026-09-26T00:00:00.000Z";
let n = 0;

async function insertConversation(questionRounds = 0): Promise<string> {
  const id = `c${++n}`;
  await db
    .prepare("INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(id, "claude-sonnet-5", "t", questionRounds, NOW, NOW)
    .run();
  return id;
}

async function insertMessage(conversationId: string, seq: number, role = "user", kind = "text"): Promise<string> {
  const id = `m${++n}`;
  await db
    .prepare("INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(id, conversationId, seq, role, kind, "{}", NOW)
    .run();
  return id;
}

function insertRecommendation(conversationId: string, messageId: string, position: number) {
  return db
    .prepare(
      `INSERT INTO recommendations (id, conversation_id, message_id, position, tmdb_id, title, year, why_short, why_full, tmdb_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(`r${++n}`, conversationId, messageId, position, 1, "Film", 2000, "s", "f", "{}", NOW)
    .run();
}

describe("migration 0002", () => {
  it("creates conversations, messages, recommendations, decisions and both indexes", async () => {
    const { results } = await db
      .prepare(
        `SELECT type, name FROM sqlite_master
         WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%'
           AND tbl_name IN ('conversations', 'messages', 'recommendations', 'decisions')
         ORDER BY type, name`,
      )
      .all<{ type: string; name: string }>();
    const byType = (t: string) => results.filter((r) => r.type === t).map((r) => r.name);
    expect(byType("table")).toEqual(["conversations", "decisions", "messages", "recommendations"]);
    expect(byType("index")).toEqual(["idx_recommendations_conversation", "idx_recommendations_tmdb_id"]);
  });
});

describe("recommendation constraints", () => {
  it("question_rounds accepts 0..2 and rejects 3", async () => {
    await expect(insertConversation(2)).resolves.toBeTypeOf("string");
    await expect(insertConversation(3)).rejects.toThrow(/CHECK constraint failed/);
  });

  it("messages.role and messages.kind reject values outside their sets", async () => {
    const c = await insertConversation();
    await expect(insertMessage(c, 1, "system", "text")).rejects.toThrow(/CHECK constraint failed/);
    await expect(insertMessage(c, 1, "user", "image")).rejects.toThrow(/CHECK constraint failed/);
    await expect(insertMessage(c, 1, "assistant", "recommendations")).resolves.toBeTypeOf("string");
  });

  it("rejects a duplicate (conversation_id, seq)", async () => {
    const c = await insertConversation();
    await insertMessage(c, 1);
    await expect(insertMessage(c, 1)).rejects.toThrow(/UNIQUE constraint failed: messages.conversation_id, messages.seq/);
  });

  it("recommendations.position accepts 1..5 and rejects 0 and 6", async () => {
    const c = await insertConversation();
    const m = await insertMessage(c, 1, "assistant", "recommendations");
    await expect(insertRecommendation(c, m, 5)).resolves.toMatchObject({ success: true });
    await expect(insertRecommendation(c, m, 6)).rejects.toThrow(/CHECK constraint failed/);
    await expect(insertRecommendation(c, m, 0)).rejects.toThrow(/CHECK constraint failed/);
  });

  it("enforces foreign keys and decisions.decision values", async () => {
    await expect(insertMessage("missing", 1)).rejects.toThrow(/FOREIGN KEY constraint failed/);
    const c = await insertConversation();
    const decide = (decision: string) =>
      db
        .prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (?, ?, ?, ?)")
        .bind(++n, decision, c, NOW)
        .run();
    await expect(decide("maybe")).resolves.toMatchObject({ success: true });
    await expect(decide("later")).rejects.toThrow(/CHECK constraint failed/);
  });
});
