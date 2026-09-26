import {
  type ConversationRow,
  type MessageRow,
  type RecommendationRow,
  messageContent,
  toApiConversation,
  toApiRecommendation,
} from "../conversations/store";
import { DECISION_COLUMNS } from "../decisions/handlers";
import { errorResponse, json } from "../http";
import { PROFILE_COLUMNS } from "../taste/handlers";

// GET /sync — one-way pull for the iOS app's SwiftData cache. Read-only.
//
// Messages and recommendations are selected by their CONVERSATION's
// updated_at, never their own created_at: converse() stamps the user message
// before the Claude call but commits it (with conversations.updated_at) up to
// a minute+ later, so a created_at-based delta could skip it forever. The
// cursor also overlaps by OVERLAP_MS so boundary commits are re-sent, not
// missed; the app upserts by id, so duplicates are harmless.

export const OVERLAP_MS = 120_000;

// Changed conversations. A full pull binds '' — every ISO timestamp sorts after it.
const CHANGED = "SELECT id FROM conversations WHERE updated_at > ?1";

const CONVERSATIONS = `
  SELECT id, model, title, question_rounds, created_at, updated_at
  FROM conversations WHERE updated_at > ?1
  ORDER BY updated_at, id`;

const MESSAGES = `
  SELECT id, conversation_id, seq, role, kind, content_json, created_at
  FROM messages WHERE conversation_id IN (${CHANGED})
  ORDER BY conversation_id, seq`;

const RECOMMENDATIONS = `
  SELECT id, conversation_id, message_id, position, tmdb_id, title, year, why_short, why_full, tmdb_json, created_at
  FROM recommendations WHERE conversation_id IN (${CHANGED})
  ORDER BY message_id, position`;

const DECISIONS = `SELECT ${DECISION_COLUMNS} FROM decisions WHERE decided_at > ?1 ORDER BY decided_at, tmdb_id`;

const TASTE_PROFILE = `SELECT ${PROFILE_COLUMNS} FROM taste_profile WHERE id = 1 AND updated_at > ?1`;

const LAST_IMPORT = "SELECT imported_at FROM imports ORDER BY id DESC LIMIT 1";

/** Parses `since` to canonical toISOString() form, so string comparison is correct. */
function parseSince(raw: string | null): string | null | undefined {
  if (raw === null) return null;
  const ms = Date.parse(raw);
  return Number.isNaN(ms) ? undefined : new Date(ms).toISOString();
}

export async function sync(request: Request, env: Env): Promise<Response> {
  const since = parseSince(new URL(request.url).searchParams.get("since"));
  if (since === undefined) {
    return errorResponse(400, "invalid_request", "since must be a date, e.g. an ISO 8601 timestamp");
  }

  // Taken before the read, so the cursor never runs ahead of what was read.
  const now = new Date();
  const db = env.DB;
  const bound = since ?? "";
  // One batch: a consistent snapshot.
  const [conversations, messages, recommendations, decisions, profile, lastImport] = await db.batch([
    db.prepare(CONVERSATIONS).bind(bound),
    db.prepare(MESSAGES).bind(bound),
    db.prepare(RECOMMENDATIONS).bind(bound),
    db.prepare(DECISIONS).bind(bound),
    db.prepare(TASTE_PROFILE).bind(bound),
    db.prepare(LAST_IMPORT),
  ]);

  return json(200, {
    server_time: now.toISOString(),
    next_since: new Date(now.getTime() - OVERLAP_MS).toISOString(),
    conversations: ((conversations?.results ?? []) as ConversationRow[]).map(toApiConversation),
    messages: ((messages?.results ?? []) as MessageRow[]).map((m) => ({
      id: m.id,
      conversation_id: m.conversation_id,
      seq: m.seq,
      role: m.role,
      kind: m.kind,
      content: messageContent(m),
      created_at: m.created_at,
    })),
    // toApiRecommendation's shape, flat: plus conversation_id, message_id, created_at.
    recommendations: ((recommendations?.results ?? []) as RecommendationRow[]).map((r) => {
      const { id, ...fields } = toApiRecommendation(r);
      return { id, conversation_id: r.conversation_id, message_id: r.message_id, ...fields, created_at: r.created_at };
    }),
    decisions: decisions?.results ?? [],
    taste_profile: profile?.results[0] ?? null,
    last_import_at: (lastImport?.results[0] as { imported_at: string } | undefined)?.imported_at ?? null,
  });
}
