import type { Turn } from "../recommend/prompt";
import type { MovieDetails } from "../tmdb/movie";

// D1 access for conversations, messages, and recommendations, plus the
// row → API mappings shared by every conversation endpoint.

export interface ConversationRow {
  id: string;
  model: string;
  title: string | null;
  question_rounds: number;
  created_at: string;
  updated_at: string;
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

/** Loads a conversation with all messages (seq order) and recommendations (position order). */
export async function loadConversation(db: D1Database, id: string): Promise<ConversationState | null> {
  const [conversation, messages, recommendations] = await db.batch([
    db.prepare("SELECT id, model, title, question_rounds, created_at, updated_at FROM conversations WHERE id = ?").bind(id),
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

const INSERT_MESSAGE =
  "INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)";

const INSERT_RECOMMENDATIONS = `
  INSERT INTO recommendations (id, conversation_id, message_id, position, tmdb_id, title, year,
                               why_short, why_full, tmdb_json, created_at)
  SELECT json_extract(value, '$.id'), json_extract(value, '$.conversation_id'), json_extract(value, '$.message_id'),
         json_extract(value, '$.position'), json_extract(value, '$.tmdb_id'), json_extract(value, '$.title'),
         json_extract(value, '$.year'), json_extract(value, '$.why_short'), json_extract(value, '$.why_full'),
         json_extract(value, '$.tmdb_json'), json_extract(value, '$.created_at')
  FROM json_each(?)`;

/**
 * Writes one exchange atomically: (conversation), user message, assistant
 * message, recommendations, conversation update. A failed statement rolls
 * back the whole batch.
 */
export async function saveTurn(db: D1Database, write: TurnWrite): Promise<void> {
  const { conversation: c, user, assistant } = write;
  const message = (m: MessageRow) =>
    db.prepare(INSERT_MESSAGE).bind(m.id, m.conversation_id, m.seq, m.role, m.kind, m.content_json, m.created_at);

  const statements = [
    message(user),
    message(assistant),
    db.prepare(INSERT_RECOMMENDATIONS).bind(JSON.stringify(write.recommendations)),
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
        .prepare("UPDATE conversations SET question_rounds = ?, updated_at = ? WHERE id = ?")
        .bind(c.question_rounds, c.updated_at, c.id),
    );
  }

  try {
    await db.batch(statements);
  } catch (err) {
    if (/UNIQUE constraint failed: messages\.conversation_id, messages\.seq/.test(String(err))) {
      throw new ConversationBusy();
    }
    throw err;
  }
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
  };
}

export function toApiMessage(m: MessageRow, recommendations: RecommendationRow[]) {
  const message = {
    id: m.id,
    seq: m.seq,
    role: m.role,
    kind: m.kind,
    content: JSON.parse(m.content_json) as unknown,
    created_at: m.created_at,
  };
  if (m.kind !== "recommendations") return message;
  return { ...message, recommendations: picksFor(recommendations, m.id).map(toApiRecommendation) };
}

/** Stable app contract; director / providers / trailer_key are filled by W4b. */
export function toApiRecommendation(r: RecommendationRow) {
  const details = JSON.parse(r.tmdb_json) as MovieDetails;
  return {
    id: r.id,
    position: r.position,
    tmdb_id: r.tmdb_id,
    title: r.title,
    year: r.year,
    why_short: r.why_short,
    why_full: r.why_full,
    poster_path: details.poster_path,
    runtime: details.runtime,
    overview: details.overview,
    director: null,
    providers: [],
    trailer_key: null,
  };
}
