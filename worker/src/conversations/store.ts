import type { Turn } from "../recommend/prompt";
import type { EnrichedDetails } from "../tmdb/enrich";

// D1 access for conversations, messages, and recommendations, plus the
// row → API mappings shared by every conversation endpoint.

export interface ConversationRow {
  id: string;
  model: string;
  title: string | null;
  question_rounds: number;
  created_at: string;
  updated_at: string;
  /** NULL = live; set = a tombstone (content gone, row kept for decisions' foreign key). */
  deleted_at: string | null;
}

export interface MessageRow {
  id: string;
  conversation_id: string;
  seq: number;
  role: "user" | "assistant";
  kind: "text" | "question" | "recommendations";
  content_json: string;
  created_at: string;
}

export interface RecommendationRow {
  id: string;
  conversation_id: string;
  message_id: string;
  position: number;
  tmdb_id: number;
  title: string;
  year: number | null;
  why_short: string;
  why_full: string;
  tmdb_json: string;
  created_at: string;
}

export interface UserContent {
  text: string | null;
  just_pick: boolean;
}

export interface QuestionContent {
  text: string;
  chips: string[];
}

export interface RecommendationsContent {
  dropped: number;
}

export interface ConversationState {
  conversation: ConversationRow;
  messages: MessageRow[];
  recommendations: RecommendationRow[];
}

/** Two concurrent sends to one conversation collided on (conversation_id, seq). */
export class ConversationBusy extends Error {}

/** The conversation was deleted between loadConversation and saveTurn; nothing was written. */
export class ConversationDeleted extends Error {}

export const CONVERSATION_COLUMNS = "id, model, title, question_rounds, created_at, updated_at, deleted_at";

/**
 * Loads a live conversation with all messages (seq order) and recommendations
 * (position order). A deleted conversation is null, like an unknown one.
 */
export async function loadConversation(db: D1Database, id: string): Promise<ConversationState | null> {
  const [conversation, messages, recommendations] = await db.batch([
    db.prepare(`SELECT ${CONVERSATION_COLUMNS} FROM conversations WHERE id = ? AND deleted_at IS NULL`).bind(id),
    db
      .prepare(
        "SELECT id, conversation_id, seq, role, kind, content_json, created_at FROM messages WHERE conversation_id = ? ORDER BY seq",
      )
      .bind(id),
    db
      .prepare(
        `SELECT id, conversation_id, message_id, position, tmdb_id, title, year, why_short, why_full, tmdb_json, created_at
         FROM recommendations WHERE conversation_id = ? ORDER BY message_id, position`,
      )
      .bind(id),
  ]);
  const row = conversation?.results[0] as ConversationRow | undefined;
  if (!row) return null;
  return {
    conversation: row,
    messages: (messages?.results ?? []) as MessageRow[],
    recommendations: (recommendations?.results ?? []) as RecommendationRow[],
  };
}

export interface TurnWrite {
  /** Set when the conversation is new; inserted in the same batch. */
  create: boolean;
  conversation: ConversationRow;
  user: MessageRow;
  assistant: MessageRow;
  recommendations: RecommendationRow[];
}

// Every turn write is conditional on the conversation still being live, so a
// turn that was in flight when the conversation was deleted never lands in the
// tombstone. A new conversation's row is inserted earlier in the same batch.
const IS_LIVE = "EXISTS (SELECT 1 FROM conversations WHERE id = ?2 AND deleted_at IS NULL)";

const INSERT_MESSAGE = `
  INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at)
  SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE ${IS_LIVE}`;

const INSERT_RECOMMENDATIONS = `
  INSERT INTO recommendations (id, conversation_id, message_id, position, tmdb_id, title, year,
                               why_short, why_full, tmdb_json, created_at)
  SELECT json_extract(value, '$.id'), json_extract(value, '$.conversation_id'), json_extract(value, '$.message_id'),
         json_extract(value, '$.position'), json_extract(value, '$.tmdb_id'), json_extract(value, '$.title'),
         json_extract(value, '$.year'), json_extract(value, '$.why_short'), json_extract(value, '$.why_full'),
         json_extract(value, '$.tmdb_json'), json_extract(value, '$.created_at')
  FROM json_each(?1) WHERE ${IS_LIVE}`;

// The durable log behind pick outcomes: same payload and live condition as the
// recommendations insert. DO NOTHING keeps each film's first recommendation.
const INSERT_PICK_LOG = `
  INSERT INTO pick_log (tmdb_id, title, year, model, conversation_id, first_recommended_at)
  SELECT json_extract(value, '$.tmdb_id'), json_extract(value, '$.title'), json_extract(value, '$.year'),
         ?3, json_extract(value, '$.conversation_id'), json_extract(value, '$.created_at')
  FROM json_each(?1) WHERE ${IS_LIVE}
  ON CONFLICT(tmdb_id) DO NOTHING`;

/**
 * Writes one exchange atomically: (conversation), user message, assistant
 * message, recommendations, pick log, conversation update. A failed statement rolls
 * back the whole batch. Throws ConversationDeleted, having written nothing,
 * if an existing conversation was deleted in the meantime.
 */
export async function saveTurn(db: D1Database, write: TurnWrite): Promise<void> {
  const { conversation: c, user, assistant } = write;
  const message = (m: MessageRow) =>
    db.prepare(INSERT_MESSAGE).bind(m.id, m.conversation_id, m.seq, m.role, m.kind, m.content_json, m.created_at);

  const picks = JSON.stringify(write.recommendations);
  const statements = [
    message(user),
    message(assistant),
    db.prepare(INSERT_RECOMMENDATIONS).bind(picks, c.id),
    db.prepare(INSERT_PICK_LOG).bind(picks, c.id, c.model),
  ];
  if (write.create) {
    statements.unshift(
      db
        .prepare(
          "INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(c.id, c.model, c.title, c.question_rounds, c.created_at, c.updated_at),
    );
  } else {
    statements.push(
      db
        .prepare("UPDATE conversations SET question_rounds = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(c.question_rounds, c.updated_at, c.id),
    );
  }

  let results: D1Result[];
  try {
    results = await db.batch(statements);
  } catch (err) {
    if (/UNIQUE constraint failed: messages\.conversation_id, messages\.seq/.test(String(err))) {
      throw new ConversationBusy();
    }
    throw err;
  }
  // The conversation update is last; 0 changes means the inserts' conditions failed too.
  if (!write.create && results.at(-1)?.meta.changes === 0) throw new ConversationDeleted();
}

/**
 * Soft delete: drops the content, keeps the row as a tombstone. Decisions are
 * never touched. Returns false for an unknown id; true if it is (now or
 * already) deleted.
 */
export async function deleteConversation(db: D1Database, id: string): Promise<boolean> {
  const now = new Date().toISOString();
  const [, , , exists] = await db.batch([
    // Recommendations reference messages, so they go first.
    db.prepare("DELETE FROM recommendations WHERE conversation_id = ?").bind(id),
    db.prepare("DELETE FROM messages WHERE conversation_id = ?").bind(id),
    // title is derived from the first message, so it is content too.
    db
      .prepare(
        "UPDATE conversations SET deleted_at = ?1, updated_at = ?1, title = NULL WHERE id = ?2 AND deleted_at IS NULL",
      )
      .bind(now, id),
    db.prepare("SELECT 1 FROM conversations WHERE id = ?").bind(id),
  ]);
  return (exists?.results.length ?? 0) > 0;
}

/** Sets the title of a live conversation; null if it is unknown or deleted. */
export async function renameConversation(db: D1Database, id: string, title: string): Promise<ConversationRow | null> {
  return db
    .prepare(
      `UPDATE conversations SET title = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL
       RETURNING ${CONVERSATION_COLUMNS}`,
    )
    .bind(title, new Date().toISOString(), id)
    .first<ConversationRow>();
}

/** Stored history as prompt turns, recommendation turns rebuilt from their rows. */
export function toTurns(state: Pick<ConversationState, "messages" | "recommendations">): Turn[] {
  return state.messages.map((m): Turn => {
    if (m.role === "user") {
      const content = JSON.parse(m.content_json) as UserContent;
      return { role: "user", text: content.text, just_pick: content.just_pick };
    }
    if (m.kind === "question") {
      const content = JSON.parse(m.content_json) as QuestionContent;
      return { role: "assistant", kind: "question", question: content.text, chips: content.chips };
    }
    return { role: "assistant", kind: "recommendations", picks: picksFor(state.recommendations, m.id) };
  });
}

const picksFor = (recommendations: RecommendationRow[], messageId: string) =>
  recommendations.filter((r) => r.message_id === messageId).sort((a, b) => a.position - b.position);

export function toApiConversation(c: ConversationRow) {
  return {
    id: c.id,
    title: c.title,
    model: c.model,
    question_rounds: c.question_rounds,
    created_at: c.created_at,
    updated_at: c.updated_at,
    deleted_at: c.deleted_at,
  };
}

/** A message's `content`: its parsed content_json, as every endpoint returns it. */
export const messageContent = (m: MessageRow): unknown => JSON.parse(m.content_json);

export function toApiMessage(m: MessageRow, recommendations: RecommendationRow[]) {
  const message = {
    id: m.id,
    seq: m.seq,
    role: m.role,
    kind: m.kind,
    content: messageContent(m),
    created_at: m.created_at,
  };
  if (m.kind !== "recommendations") return message;
  return { ...message, recommendations: picksFor(recommendations, m.id).map(toApiRecommendation) };
}

/**
 * Stable app contract. Enrichment fields come from tmdb_json; W4a-era rows
 * (no enrichment stored) render as null / [] / null — no backfill.
 */
export function toApiRecommendation(r: RecommendationRow) {
  const details = JSON.parse(r.tmdb_json) as Partial<EnrichedDetails>;
  return {
    id: r.id,
    position: r.position,
    tmdb_id: r.tmdb_id,
    title: r.title,
    year: r.year,
    why_short: r.why_short,
    why_full: r.why_full,
    poster_path: details.poster_path ?? null,
    runtime: details.runtime ?? null,
    overview: details.overview ?? "",
    director: details.director ?? null,
    providers: details.providers ?? [],
    providers_link: details.providers_link ?? null,
    trailer_key: details.trailer_key ?? null,
  };
}
