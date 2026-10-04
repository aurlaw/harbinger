import { withJsonBody } from "../body";
import { errorResponse, json } from "../http";
import { TMDB_ID } from "../tmdb/movie";
import { nonEmptyString, object, oneOf } from "../validate";

// PUT /decisions/{tmdb_id} — Yes / Maybe / No on a pick. Decisions are
// exclusion only; W4b's exclusion query reads them, nothing else does.

const DECISIONS = ["yes", "maybe", "no"] as const;

interface DecisionInput {
  decision: (typeof DECISIONS)[number];
  conversation_id: string;
}

function validateDecision(body: unknown): DecisionInput {
  const obj = object(body, "body");
  return {
    decision: oneOf(obj.decision, "decision", DECISIONS),
    conversation_id: nonEmptyString(obj.conversation_id, "conversation_id"),
  };
}

/** The decision shape returned by PUT /decisions and GET /sync. */
export const DECISION_COLUMNS = "tmdb_id, decision, conversation_id, decided_at";

// One row per film; changing a decision (or re-deciding a maybe in another
// conversation, which moves its scope) is the same upsert.
const UPSERT = `
  INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at)
  VALUES (?1, ?2, ?3, ?4)
  ON CONFLICT(tmdb_id) DO UPDATE SET
    decision = excluded.decision,
    conversation_id = excluded.conversation_id,
    decided_at = excluded.decided_at
  RETURNING ${DECISION_COLUMNS}`;

export async function putDecision(request: Request, env: Env, params: Record<string, string>): Promise<Response> {
  const id = params.id ?? "";
  if (!TMDB_ID.test(id)) {
    return errorResponse(400, "invalid_request", "tmdb_id must be a positive integer of at most 10 digits");
  }
  const tmdbId = Number(id);

  return withJsonBody(validateDecision, async (input) => {
    const [conversation, recommended] = await env.DB.batch([
      // A deleted conversation counts as missing.
      env.DB.prepare("SELECT 1 FROM conversations WHERE id = ? AND deleted_at IS NULL").bind(input.conversation_id),
      env.DB.prepare("SELECT 1 FROM recommendations WHERE conversation_id = ? AND tmdb_id = ? LIMIT 1").bind(
        input.conversation_id,
        tmdbId,
      ),
    ]);
    if (!conversation?.results.length) return errorResponse(404, "not_found", "Conversation not found");
    if (!recommended?.results.length) {
      return errorResponse(422, "not_recommended", "This film was not recommended in that conversation");
    }

    // Deliberately leaves conversations.updated_at alone.
    const row = await env.DB.prepare(UPSERT)
      .bind(tmdbId, input.decision, input.conversation_id, new Date().toISOString())
      .first();
    return json(200, row);
  })(request, env);
}
