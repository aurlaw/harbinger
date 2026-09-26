import { InvalidRequest, withJsonBody } from "../body";
import { type ClaudeConfig, ClaudeError, callClaude, claudeConfig } from "../claude/client";
import { errorResponse, json } from "../http";
import { buildSystemPrompt, loadLibraryPrompt, replayTurns, userTurnText } from "../recommend/prompt";
import { resolvePicks } from "../recommend/resolve";
import { OUTPUT_SCHEMA, type Reply, parseReply, recommendationFailed } from "../recommend/schema";
import { TmdbError } from "../tmdb/client";
import { boolean, object } from "../validate";
import {
  type ConversationRow,
  ConversationBusy,
  type ConversationState,
  type MessageRow,
  type RecommendationRow,
  loadConversation,
  saveTurn,
  toApiConversation,
  toApiMessage,
  toTurns,
} from "./store";

// GET /models, POST /conversations, POST /conversations/{id}/messages, GET /conversations/{id}

type Params = Record<string, string>;
type ConfiguredHandler = (request: Request, env: Env, params: Params, config: ClaudeConfig) => Promise<Response>;

/**
 * Fails closed (500, logged, no outbound call) when Claude or TMDB isn't
 * configured. Only conversation routes go through this; others are unaffected.
 */
function withClaudeConfig(handler: ConfiguredHandler) {
  return async (request: Request, env: Env, params: Params): Promise<Response> => {
    const config = claudeConfig(env);
    if (!config) return errorResponse(500, "internal_error", "Internal server error");
    if (!env.TMDB_READ_TOKEN) {
      console.error("TMDB_READ_TOKEN is not configured");
      return errorResponse(500, "internal_error", "Internal server error");
    }
    return handler(request, env, params, config);
  };
}

export const listModels = withClaudeConfig(async (_request, _env, _params, config) =>
  json(200, { default: config.defaultModel, allowed: config.models }),
);

const MAX_TEXT_LENGTH = 2000;
const TITLE_LENGTH = 60;

function userText(value: unknown, path: string): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (text.length === 0 || text.length > MAX_TEXT_LENGTH) {
    throw new InvalidRequest(`${path} must be a string of 1 to ${MAX_TEXT_LENGTH} characters after trimming`);
  }
  return text;
}

interface TurnInput {
  text: string | null;
  just_pick: boolean;
}

interface CreateInput extends TurnInput {
  model: string | undefined;
}

function validateCreate(body: unknown): CreateInput {
  const obj = object(body, "body");
  if (obj.model !== undefined && typeof obj.model !== "string") {
    throw new InvalidRequest("model must be a string");
  }
  return {
    model: obj.model,
    text: userText(obj.text, "text"),
    just_pick: obj.just_pick === undefined ? false : boolean(obj.just_pick, "just_pick"),
  };
}

function validateAppend(body: unknown): TurnInput {
  const obj = object(body, "body");
  const input = {
    text: obj.text === undefined ? null : userText(obj.text, "text"),
    just_pick: obj.just_pick === undefined ? false : boolean(obj.just_pick, "just_pick"),
  };
  if (input.text === null && !input.just_pick) {
    throw new InvalidRequest("body must include text or just_pick: true");
  }
  return input;
}

/** First 60 characters of the first message, cut at a word boundary where possible. */
export function titleFrom(text: string): string {
  const chars = [...text.replace(/\s+/g, " ")];
  if (chars.length <= TITLE_LENGTH) return chars.join("");
  // Include one extra character so a space right after the 60th counts as a boundary.
  const head = chars.slice(0, TITLE_LENGTH + 1);
  const space = head.lastIndexOf(" ");
  return (space > 0 ? head.slice(0, space) : head.slice(0, TITLE_LENGTH)).join("").trimEnd();
}

export const createConversation = withClaudeConfig((request, env, _params, config) =>
  withJsonBody(validateCreate, async (input) => {
    const model = input.model ?? config.defaultModel;
    if (!config.models.includes(model)) {
      return errorResponse(400, "invalid_model", `model must be one of: ${config.models.join(", ")}`);
    }
    const now = new Date().toISOString();
    const conversation: ConversationRow = {
      id: crypto.randomUUID(),
      model,
      title: titleFrom(input.text ?? ""),
      question_rounds: 0,
      created_at: now,
      updated_at: now,
    };
    return converse(env, config, { conversation, messages: [], recommendations: [] }, true, input);
  })(request, env),
);

export const appendMessage = withClaudeConfig((request, env, params, config) =>
  withJsonBody(validateAppend, async (input) => {
    const state = await loadConversation(env.DB, params.id ?? "");
    if (!state) return errorResponse(404, "not_found", "Conversation not found");
    return converse(env, config, state, false, input);
  })(request, env),
);

export const getConversation = withClaudeConfig(async (_request, env, params) => {
  const state = await loadConversation(env.DB, params.id ?? "");
  if (!state) return errorResponse(404, "not_found", "Conversation not found");
  return json(200, {
    conversation: toApiConversation(state.conversation),
    messages: state.messages.map((m) => toApiMessage(m, state.recommendations)),
  });
});

/**
 * One exchange: prompt → Claude (question-cap retry) → validate → resolve →
 * one atomic write. Nothing is written if Claude or TMDB fails.
 */
async function converse(
  env: Env,
  config: ClaudeConfig,
  state: ConversationState,
  create: boolean,
  input: TurnInput,
): Promise<Response> {
  const startedAt = new Date().toISOString();
  try {
    const { conversation } = state;
    const system = buildSystemPrompt(await loadLibraryPrompt(env.DB));
    const history = replayTurns(toTurns(state));
    // Enforced on the user turn, never the system prompt, so the cache holds.
    const mustRecommend = input.just_pick || conversation.question_rounds >= 2;

    const ask = async (firm: boolean): Promise<Reply> =>
      parseReply(
        await callClaude(config, {
          model: conversation.model,
          system,
          messages: [
            ...history,
            { role: "user", content: userTurnText(input.text, input.just_pick, mustRecommend, firm) },
          ],
          schema: OUTPUT_SCHEMA,
        }),
      );

    let reply = await ask(false);
    if (reply.kind === "question" && mustRecommend) {
      console.log("Claude asked a question when it had to recommend; retrying once");
      reply = await ask(true);
      if (reply.kind === "question") throw recommendationFailed("Claude would not recommend");
    }

    const now = new Date().toISOString();
    const lastSeq = state.messages.at(-1)?.seq ?? 0;
    const user: MessageRow = {
      id: crypto.randomUUID(),
      conversation_id: conversation.id,
      seq: lastSeq + 1,
      role: "user",
      kind: "text",
      content_json: JSON.stringify({ text: input.text, just_pick: input.just_pick }),
      created_at: startedAt,
    };
    const assistant: MessageRow = {
      id: crypto.randomUUID(),
      conversation_id: conversation.id,
      seq: lastSeq + 2,
      role: "assistant",
      kind: reply.kind,
      content_json: "",
      created_at: now,
    };

    let recommendations: RecommendationRow[] = [];
    if (reply.kind === "question") {
      assistant.content_json = JSON.stringify({ text: reply.question, chips: reply.chips });
    } else {
      const { resolved, unresolved } = await resolvePicks(env, reply.picks);
      if (resolved.length === 0) throw recommendationFailed("No recommended film could be matched on TMDB");
      assistant.content_json = JSON.stringify({ dropped: reply.invalid + unresolved });
      recommendations = resolved.map((r, i) => ({
        id: crypto.randomUUID(),
        conversation_id: conversation.id,
        message_id: assistant.id,
        position: i + 1,
        tmdb_id: r.tmdb_id,
        title: r.title,
        year: r.year,
        why_short: r.why_short,
        why_full: r.why_full,
        tmdb_json: JSON.stringify(r.details),
        created_at: now,
      }));
    }

    const updated: ConversationRow = {
      ...conversation,
      question_rounds: conversation.question_rounds + (reply.kind === "question" ? 1 : 0),
      updated_at: now,
    };
    await saveTurn(env.DB, { create, conversation: updated, user, assistant, recommendations });

    return json(200, {
      conversation: toApiConversation(updated),
      messages: [toApiMessage(user, recommendations), toApiMessage(assistant, recommendations)],
    });
  } catch (err) {
    if (err instanceof ClaudeError || err instanceof TmdbError) return err.toResponse();
    if (err instanceof ConversationBusy) {
      return errorResponse(409, "conversation_busy", "Another message is being processed for this conversation");
    }
    throw err;
  }
}
