import { errorResponse } from "../http";

// The only code that talks to Anthropic. Native fetch — no SDK (zero runtime deps).

const ANTHROPIC_VERSION = "2023-06-01";
const MAX_TOKENS = 4096;
const TIMEOUT_MS = 90_000;
const RETRY_DELAY_MS = 1_000;

/** A Claude-side failure already mapped to the harbinger error it becomes. */
export class ClaudeError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers?: HeadersInit,
  ) {
    super(message);
  }

  toResponse(): Response {
    return errorResponse(this.status, this.code, this.message, this.headers);
  }
}

const claudeError = () => new ClaudeError(502, "claude_error", "Claude request failed");

export interface ClaudeConfig {
  apiKey: string;
  baseUrl: string;
  models: string[];
  defaultModel: string;
}

/**
 * Reads and checks the Claude config. Returns null (logged) when it is unusable,
 * so conversation routes fail closed without an outbound call.
 */
export function claudeConfig(env: Env): ClaudeConfig | null {
  const models = String(env.CLAUDE_MODELS ?? "")
    .split(",")
    .map((m) => m.trim())
    .filter((m) => m.length > 0);
  const defaultModel = String(env.CLAUDE_DEFAULT_MODEL ?? "");
  const baseUrl = String(env.ANTHROPIC_BASE_URL ?? "");

  if (!env.ANTHROPIC_API_KEY) {
    console.error("ANTHROPIC_API_KEY is not configured");
    return null;
  }
  if (!baseUrl) {
    console.error("ANTHROPIC_BASE_URL is not configured");
    return null;
  }
  if (!models.includes(defaultModel)) {
    console.error(`CLAUDE_DEFAULT_MODEL "${defaultModel}" is not in CLAUDE_MODELS`);
    return null;
  }
  return { apiKey: env.ANTHROPIC_API_KEY, baseUrl, models, defaultModel };
}

export interface ClaudeMessage {
  role: "user" | "assistant";
  content: string;
}

export interface ClaudeRequest {
  model: string;
  system: string;
  messages: ClaudeMessage[];
  /** JSON schema for output_config.format. Keep it constant — changing it invalidates the cache. */
  schema: unknown;
}

interface MessagesResponse {
  stop_reason?: string;
  content?: { type?: string; text?: string }[];
  usage?: {
    input_tokens?: number;
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
    output_tokens?: number;
  };
}

/**
 * Sends one Messages API request and returns the parsed structured-output JSON.
 * Throws ClaudeError on any failure; Anthropic's body is never forwarded.
 */
export async function callClaude(config: ClaudeConfig, req: ClaudeRequest): Promise<unknown> {
  const body = JSON.stringify({
    model: req.model,
    max_tokens: MAX_TOKENS,
    system: req.system,
    messages: req.messages,
    output_config: { format: { type: "json_schema", schema: req.schema } },
    // Automatic caching: the breakpoint follows the end of the conversation.
    cache_control: { type: "ephemeral" },
  });

  let res = await send(config, body);
  if (res === null || (res.status >= 500 && res.status !== 529)) {
    // 5xx, network error, or timeout: one retry after a short pause.
    await res?.body?.cancel();
    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
    res = await send(config, body);
    if (res === null) throw claudeError();
  }

  if (!res.ok) throw await statusError(res);

  let message: MessagesResponse;
  try {
    message = (await res.json()) as MessagesResponse;
  } catch (err) {
    console.error("Claude: response body is not JSON", err);
    throw claudeError();
  }

  logUsage(req.model, message);

  if (message.stop_reason !== "end_turn") {
    console.error(`Claude: stop_reason ${message.stop_reason}`);
    throw claudeError();
  }

  // Thinking blocks may precede it; the structured output is the text block.
  const text = message.content?.find((block) => block.type === "text")?.text;
  if (typeof text !== "string") {
    console.error("Claude: response has no text block");
    throw claudeError();
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    console.error("Claude: text block is not valid JSON", err);
    throw claudeError();
  }
}

/** Returns the response, or null on a network error or timeout. */
async function send(config: ClaudeConfig, body: string): Promise<Response | null> {
  try {
    // Plain join (config, not user input) so a gateway base URL keeps its path.
    return await fetch(`${config.baseUrl.replace(/\/+$/, "")}/v1/messages`, {
      method: "POST",
      headers: {
        "x-api-key": config.apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    console.error("Claude: request failed", err);
    return null;
  }
}

async function statusError(res: Response): Promise<ClaudeError> {
  if (res.status === 429 || res.status === 529) {
    await res.body?.cancel();
    const retryAfter = res.headers.get("Retry-After");
    return new ClaudeError(
      503,
      "claude_unavailable",
      "Claude is temporarily unavailable",
      retryAfter ? { "Retry-After": retryAfter } : undefined,
    );
  }
  // Log Anthropic's error type for diagnosis; never return it.
  let type = "unknown";
  try {
    const parsed = (await res.json()) as { error?: { type?: unknown } };
    if (typeof parsed.error?.type === "string") type = parsed.error.type;
  } catch {
    // Non-JSON error body; the status is enough.
  }
  console.error(`Claude: status ${res.status}, error type ${type}`);
  return claudeError();
}

/** One structured line per call — how caching and cost get verified after deploy. */
function logUsage(model: string, message: MessagesResponse): void {
  const usage = message.usage ?? {};
  console.log(
    JSON.stringify({
      event: "claude_usage",
      model,
      input_tokens: usage.input_tokens ?? null,
      cache_creation_input_tokens: usage.cache_creation_input_tokens ?? null,
      cache_read_input_tokens: usage.cache_read_input_tokens ?? null,
      output_tokens: usage.output_tokens ?? null,
      stop_reason: message.stop_reason ?? null,
    }),
  );
}
