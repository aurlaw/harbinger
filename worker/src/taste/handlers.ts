import { InvalidRequest, withJsonBody } from "../body";
import { ClaudeError, callClaude, claudeConfig } from "../claude/client";
import { errorResponse, json } from "../http";
import { loadLibraryPrompt } from "../recommend/prompt";
import { object } from "../validate";
import { DRAFT_INSTRUCTIONS, DRAFT_MAX_TOKENS, DRAFT_SCHEMA, draftUserTurn, parseDraft } from "./draft";

// GET /taste-profile, PUT /taste-profile, POST /taste-profile/draft

const MAX_CONTENT_LENGTH = 4000;

const PROFILE_COLUMNS = "content, based_on_import_id, updated_at";

// Single row (id = 1); based_on_import_id is the latest import at save time.
const UPSERT = `
  INSERT INTO taste_profile (id, content, based_on_import_id, updated_at)
  VALUES (1, ?1, (SELECT id FROM imports ORDER BY id DESC LIMIT 1), ?2)
  ON CONFLICT(id) DO UPDATE SET
    content = excluded.content,
    based_on_import_id = excluded.based_on_import_id,
    updated_at = excluded.updated_at
  RETURNING ${PROFILE_COLUMNS}`;

export async function getTasteProfile(_request: Request, env: Env): Promise<Response> {
  const row = await env.DB.prepare(`SELECT ${PROFILE_COLUMNS} FROM taste_profile WHERE id = 1`).first();
  if (!row) return errorResponse(404, "no_taste_profile", "No taste profile has been saved");
  return json(200, row);
}

function validateContent(body: unknown): string {
  const obj = object(body, "body");
  const content = typeof obj.content === "string" ? obj.content.trim() : "";
  if (content.length === 0 || content.length > MAX_CONTENT_LENGTH) {
    throw new InvalidRequest(`content must be a string of 1 to ${MAX_CONTENT_LENGTH} characters after trimming`);
  }
  return content;
}

export const putTasteProfile = withJsonBody(validateContent, async (content, env) => {
  const row = await env.DB.prepare(UPSERT).bind(content, new Date().toISOString()).first();
  return json(200, row);
});

function validateDraft(body: unknown): { model: string | undefined } {
  const obj = object(body, "body");
  if (obj.model !== undefined && typeof obj.model !== "string") throw new InvalidRequest("model must be a string");
  return { model: obj.model };
}

/** Drafts (or redrafts) a profile. Never saves. Fails closed on Claude config only. */
export async function draftTasteProfile(request: Request, env: Env): Promise<Response> {
  const config = claudeConfig(env);
  if (!config) return errorResponse(500, "internal_error", "Internal server error");

  return withJsonBody(validateDraft, async (input) => {
    const model = input.model ?? config.defaultModel;
    if (!config.models.includes(model)) {
      return errorResponse(400, "invalid_model", `model must be one of: ${config.models.join(", ")}`);
    }

    const library = await loadLibraryPrompt(env.DB);
    if (library.horrorRatings.length === 0) {
      return errorResponse(422, "no_ratings", "No horror ratings to draft a taste profile from");
    }

    try {
      const raw = await callClaude(config, {
        model,
        system: DRAFT_INSTRUCTIONS,
        messages: [{ role: "user", content: draftUserTurn(library.horrorRatings, library.tasteProfile) }],
        schema: DRAFT_SCHEMA,
        maxTokens: DRAFT_MAX_TOKENS,
      });
      return json(200, parseDraft(raw, library.tasteProfile));
    } catch (err) {
      if (err instanceof ClaudeError) return err.toResponse();
      throw err;
    }
  })(request, env);
}
