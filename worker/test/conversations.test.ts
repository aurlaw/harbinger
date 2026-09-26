import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { OUTPUT_SCHEMA } from "../src/recommend/schema";
import {
  type CatalogFilm,
  type World,
  USAGE,
  claudeReply,
  claudeStatus,
  clearAll,
  film,
  mockWorld,
  pick,
  question,
  recs,
  seedLibrary,
} from "./conversations-helpers";
import { BASE, authed, call, count, expectError, ok, send } from "./helpers";

const RECOMMEND_NOW = "Recommend now — do not ask a question.";
const EN_DASH = String.fromCodePoint(0x2013);

interface ApiRecommendation {
  id: string;
  position: number;
  tmdb_id: number;
  title: string;
  year: number | null;
  why_short: string;
  why_full: string;
  poster_path: string | null;
  runtime: number | null;
  overview: string;
  director: string | null;
  providers: { name: string; type: string; logo_path: string | null }[];
  providers_link: string | null;
  trailer_key: string | null;
}

interface ApiMessage {
  id: string;
  seq: number;
  role: string;
  kind: string;
  content: Record<string, unknown>;
  recommendations?: ApiRecommendation[];
  created_at: string;
}

interface ConversationBody {
  conversation: { id: string; title: string; model: string; question_rounds: number; created_at: string; updated_at: string };
  messages: ApiMessage[];
}

const CATALOG: CatalogFilm[] = [
  film(101, "The Wailing", 2016),
  film(102, "Lake Mungo", 2008),
  film(103, `Mission: Impossible ${EN_DASH} Fallout`, 2018),
  film(104, "Kairo", 2001, { original_title: "Kairo", other_years: [2002] }),
  film(105, "Noroi", 2005),
  film(106, "Pulse", 2001),
  film(107, "Session 9", 2001),
];

const start = (body: unknown) => send("POST", "/conversations", body);
const reply = (id: string, body: unknown) => send("POST", `/conversations/${id}/messages`, body);

async function startWithQuestion(world: World): Promise<ConversationBody> {
  world.replies.push(claudeReply(question("How long?", ["Short", "Long"])));
  return ok<ConversationBody>(await start({ text: "Something slow" }));
}

function callWithEnv(overrides: Record<string, unknown>, path: string, init: RequestInit = {}) {
  const request = new Request(`${BASE}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${env.API_KEY}`, "Content-Type": "application/json" },
  }) as Parameters<typeof worker.fetch>[0];
  return worker.fetch(request, { ...env, ...overrides } as Env);
}

function forbidFetch() {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
    throw new Error("fetch must not be called");
  });
}

beforeEach(async () => {
  await clearAll();
  await seedLibrary([
    { name: "Hereditary", year: 2018, horror: true, half_stars: 10, watched: true },
    { name: "The Witch", year: 2015, horror: true, half_stars: 9, watched: true },
    { name: "Alien", year: 1979, horror: true, half_stars: 10, watched: true },
    { name: "Heat", year: 1995, horror: false, half_stars: 8, watched: true },
    { name: "Saw", year: 2004, horror: true, watched: true },
    { name: "Suspiria", year: 1977, horror: true, watchlist: true },
  ]);
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("auth + config", () => {
  const routes: [string, string][] = [
    ["GET", "/models"],
    ["POST", "/conversations"],
    ["GET", "/conversations/abc"],
    ["POST", "/conversations/abc/messages"],
  ];

  it("rejects unauthenticated conversation routes without any outbound fetch", async () => {
    const spy = forbidFetch();
    for (const [method, path] of routes) {
      await expectError(await call(path, { method, body: method === "POST" ? "{}" : undefined }), 401, "unauthorized");
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("fails closed with 500 when ANTHROPIC_API_KEY is unset or empty; other routes unaffected", async () => {
    const spy = forbidFetch();
    for (const ANTHROPIC_API_KEY of [undefined, ""]) {
      for (const [method, path] of routes) {
        const init = { method, body: method === "POST" ? JSON.stringify({ text: "hi" }) : undefined };
        await expectError(await callWithEnv({ ANTHROPIC_API_KEY }, path, init), 500, "internal_error");
      }
      expect((await callWithEnv({ ANTHROPIC_API_KEY }, "/health")).status).toBe(200);
      expect((await callWithEnv({ ANTHROPIC_API_KEY }, "/library/films")).status).toBe(200);
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("fails closed with 500 when the default model is not in the allowlist", async () => {
    const spy = forbidFetch();
    const overrides = { CLAUDE_DEFAULT_MODEL: "claude-unknown" };
    await expectError(await callWithEnv(overrides, "/models"), 500, "internal_error");
    await expectError(
      await callWithEnv(overrides, "/conversations", { method: "POST", body: JSON.stringify({ text: "hi" }) }),
      500,
      "internal_error",
    );
    expect(spy).not.toHaveBeenCalled();
  });

  it("GET /models returns the default and the allowlist from vars", async () => {
    expect(await ok(await authed("/models"))).toStrictEqual({
      default: "claude-sonnet-5",
      allowed: ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5-5"],
    });
    const custom = await callWithEnv({ CLAUDE_MODELS: " a , b ", CLAUDE_DEFAULT_MODEL: "b" }, "/models");
    expect(await ok(custom)).toStrictEqual({ default: "b", allowed: ["a", "b"] });
  });

  it("rejects an unknown model with 400 invalid_model and no outbound call", async () => {
    const spy = forbidFetch();
    await expectError(await start({ text: "hi", model: "claude-opus-4-1" }), 400, "invalid_model");
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("request validation", () => {
  it("rejects bad bodies with 400 before calling out", async () => {
    const spy = forbidFetch();
    const long = "x".repeat(2001);
    await expectError(await start({}), 400, "invalid_request");
    await expectError(await start({ text: "   " }), 400, "invalid_request");
    await expectError(await start({ text: long }), 400, "invalid_request");
    await expectError(await start({ text: "hi", just_pick: "yes" }), 400, "invalid_request");
    await expectError(await start({ text: "hi", model: 5 }), 400, "invalid_request");
    await expectError(await reply("abc", {}), 400, "invalid_request");
    await expectError(await reply("abc", { just_pick: false }), 400, "invalid_request");
    await expectError(await reply("abc", { text: long }), 400, "invalid_request");
    expect(spy).not.toHaveBeenCalled();
  });

  it("accepts exactly 2,000 characters after trimming", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: `  ${"x".repeat(2000)}  ` }));
    expect(world.claudeCalls[0]!.body.messages[0]!.content).toBe("x".repeat(2000));
  });

  it("returns 404 for an unknown conversation without calling Claude", async () => {
    const spy = forbidFetch();
    await expectError(await reply("does-not-exist", { text: "hi" }), 404, "not_found");
    await expectError(await authed("/conversations/does-not-exist"), 404, "not_found");
    expect(spy).not.toHaveBeenCalled();
  });

  it("returns 405 with Allow for wrong methods", async () => {
    const res = await authed("/conversations/abc/messages");
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("POST");
  });
});

describe("Claude request", () => {
  it("sends the auth headers, chosen model, constant schema, and top-level cache_control", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: "hi", model: "claude-haiku-4-5-20251001" }));

    expect(world.claudeCalls).toHaveLength(1);
    const { body, headers } = world.claudeCalls[0]!;
    expect(headers.get("x-api-key")).toBe("test-anthropic-key");
    expect(headers.get("anthropic-version")).toBe("2023-06-01");
    expect(headers.get("content-type")).toBe("application/json");
    expect(body.model).toBe("claude-haiku-4-5-20251001");
    expect(body.max_tokens).toBe(4096);
    expect(body.output_config).toStrictEqual({ format: { type: "json_schema", schema: OUTPUT_SCHEMA } });
    expect(body.cache_control).toStrictEqual({ type: "ephemeral" });
    expect(body).not.toHaveProperty("output_format");
    expect(body.messages).toStrictEqual([{ role: "user", content: "hi" }]);
  });

  it("keeps the model for the life of the conversation and the system prompt byte-identical", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("Q?")), claudeReply(recs(pick("Lake Mungo", 2008)))]);
    const first = await ok<ConversationBody>(await start({ text: "hi", model: "claude-opus-5-5" }));
    await ok(await reply(first.conversation.id, { text: "Short", model: "claude-sonnet-5" }));

    const [a, b] = world.claudeCalls;
    expect(b!.body.model).toBe("claude-opus-5-5");
    expect(b!.body.system).toBe(a!.body.system);
    expect(JSON.stringify(b!.body.output_config)).toBe(JSON.stringify(a!.body.output_config));
  });

  it("lists sorted horror ratings, other seen films, and the watchlist in labeled sections", async () => {
    const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: "hi" }));
    const system = world.claudeCalls[0]!.body.system;

    const section = (heading: string) => {
      const startAt = system.indexOf(heading);
      expect(startAt).toBeGreaterThan(-1);
      const rest = system.slice(startAt + heading.length);
      const end = rest.indexOf("\n## ");
      return (end === -1 ? rest : rest.slice(0, end)).trim();
    };
    expect(section("## Horror ratings (their taste — ★0.5 to ★5)")).toBe(
      ["Alien (1979) — ★5", "Hereditary (2018) — ★5", "The Witch (2015) — ★4.5"].join("\n"),
    );
    // Horror-rated films are not duplicated here; unrated horror and non-horror are.
    expect(section("## Never recommend (already seen)")).toBe("Heat (1995)\nSaw (2004)");
    expect(section("## Never recommend (already on watchlist)")).toBe(
      "Exclusion only — not a signal of taste.\nSuspiria (1977)",
    );
  });

  it("replays prior turns in order, rebuilding recommendation turns from stored rows", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(recs(pick("Mission: Impossible - Fallout", 2018))));
    await ok(await reply(first.conversation.id, { text: "Short" }));
    world.replies.push(claudeReply(question("More?", ["Yes"])));
    await ok(await reply(first.conversation.id, { text: "Another" }));

    expect(world.claudeCalls[2]!.body.messages).toStrictEqual([
      { role: "user", content: "Something slow" },
      {
        role: "assistant",
        content: JSON.stringify({ kind: "question", question: "How long?", chips: ["Short", "Long"], picks: [] }),
      },
      { role: "user", content: "Short" },
      {
        role: "assistant",
        content: JSON.stringify({
          kind: "recommendations",
          question: "",
          chips: [],
          // TMDB's title, not Claude's.
          picks: [
            {
              title: `Mission: Impossible ${EN_DASH} Fallout`,
              year: 2018,
              why_short: "Short why for Mission: Impossible - Fallout.",
              why_full: "Full why for Mission: Impossible - Fallout. Relates to Hereditary.",
            },
          ],
        }),
      },
      { role: "user", content: "Another" },
    ]);
  });

  it("appends the recommend-now line to the user turn for just_pick, not the system prompt", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    await ok(await reply(first.conversation.id, { just_pick: true }));

    const body = world.claudeCalls[1]!.body;
    expect(body.messages.at(-1)).toStrictEqual({ role: "user", content: `Just pick for me.\n\n${RECOMMEND_NOW}` });
    expect(body.system).not.toContain("Recommend now");
    expect(body.system).toBe(world.claudeCalls[0]!.body.system);

    world.replies.push(claudeReply(recs(pick("Pulse", 2001))));
    await ok(await reply(first.conversation.id, { text: "Slower", just_pick: true }));
    expect(world.claudeCalls[2]!.body.messages.at(-1)!.content).toBe(`Slower\n\n${RECOMMEND_NOW}`);
  });

  it("appends the recommend-now line once question_rounds reaches 2", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(question("Era?", ["Old", "New"])));
    const second = await ok<ConversationBody>(await reply(first.conversation.id, { text: "Short" }));
    expect(second.conversation.question_rounds).toBe(2);

    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    await ok(await reply(first.conversation.id, { text: "Old" }));
    expect(world.claudeCalls[1]!.body.messages.at(-1)!.content).toBe("Short");
    expect(world.claudeCalls[2]!.body.messages.at(-1)!.content).toBe(`Old\n\n${RECOMMEND_NOW}`);
    expect(world.claudeCalls[2]!.body.system).not.toContain("Recommend now");
  });

  it("logs one usage line per call with the cache token fields", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: "hi" }));

    const lines = log.mock.calls
      .map(([line]) => (typeof line === "string" && line.startsWith("{") ? JSON.parse(line) : null))
      .filter((l) => l?.event === "claude_usage");
    expect(lines).toStrictEqual([{ event: "claude_usage", model: "claude-sonnet-5", ...USAGE, stop_reason: "end_turn" }]);
    expect(JSON.stringify(log.mock.calls)).not.toContain("test-anthropic-key");
  });
});

describe("response handling", () => {
  it("stores a question, increments question_rounds, and caps chips at 4", async () => {
    mockWorld(CATALOG, [claudeReply(question("  How long?  ", ["a", " b ", "", "c", "d", "e"]))]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));

    expect(body.conversation.question_rounds).toBe(1);
    expect(body.messages[1]).toMatchObject({
      seq: 2,
      role: "assistant",
      kind: "question",
      content: { text: "How long?", chips: ["a", "b", "c", "d"] },
    });
    expect(body.messages[1]).not.toHaveProperty("recommendations");
    const row = await env.DB.prepare("SELECT question_rounds FROM conversations WHERE id = ?")
      .bind(body.conversation.id)
      .first<{ question_rounds: number }>();
    expect(row?.question_rounds).toBe(1);
  });

  it("accepts kind with the wrong case", async () => {
    mockWorld(CATALOG, [claudeReply({ ...recs(pick("Noroi", 2005)), kind: "Recommendations" })]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));
    expect(body.messages[1]!.kind).toBe("recommendations");
    expect(body.conversation.question_rounds).toBe(0);
  });

  it("uses only the first 5 of 7 picks", async () => {
    const seven = [
      pick("The Wailing", 2016),
      pick("Lake Mungo", 2008),
      pick("Noroi", 2005),
      pick("Pulse", 2001),
      pick("Session 9", 2001),
      pick("Kairo", 2001),
      pick("Mission: Impossible - Fallout", 2018),
    ];
    const world = mockWorld(CATALOG, [claudeReply(recs(...seven))]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));
    const picks = body.messages[1]!.recommendations!;
    expect(picks.map((p) => p.title)).toEqual(["The Wailing", "Lake Mungo", "Noroi", "Pulse", "Session 9"]);
    expect(body.messages[1]!.content).toStrictEqual({ dropped: 0 });
    expect(world.tmdbCalls.some((u) => u.searchParams.get("query") === "Kairo")).toBe(false);
  });

  it("must-recommend + question → one firmer retry → still a question → 502, nothing stored", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(question("Really?")), claudeReply(question("Sure?")));
    await expectError(await reply(first.conversation.id, { just_pick: true }), 502, "recommendation_failed");

    expect(world.claudeCalls).toHaveLength(3);
    const retry = world.claudeCalls[2]!.body.messages.at(-1)!.content;
    expect(retry).toContain("Just pick for me.");
    expect(retry).toContain("A question is not allowed");
    expect(await count("messages")).toBe(2);
    expect(await count("recommendations")).toBe(0);
  });

  it("must-recommend + question → retry that recommends succeeds", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(question("Really?")), claudeReply(recs(pick("Noroi", 2005))));
    const body = await ok<ConversationBody>(await reply(first.conversation.id, { just_pick: true }));
    expect(body.messages[1]!.kind).toBe("recommendations");
    expect(body.conversation.question_rounds).toBe(1);
  });

  it.each(["refusal", "max_tokens"])("stop_reason %s → 502 claude_error, nothing stored", async (stopReason) => {
    mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005)), stopReason)]);
    await expectError(await start({ text: "hi" }), 502, "claude_error");
    expect(await count("conversations")).toBe(0);
  });

  it("non-JSON text block → 502 claude_error", async () => {
    mockWorld(CATALOG, [claudeReply('{"kind": "question", "quest')]);
    await expectError(await start({ text: "hi" }), 502, "claude_error");
  });

  it("Anthropic 529 → 503 claude_unavailable with Retry-After, no retry", async () => {
    const world = mockWorld(CATALOG, [claudeStatus(529, { type: "error" }, { "Retry-After": "7" })]);
    const res = await start({ text: "hi" });
    await expectError(res, 503, "claude_unavailable");
    expect(res.headers.get("Retry-After")).toBe("7");
    expect(world.claudeCalls).toHaveLength(1);
  });

  it("Anthropic 429 → 503 claude_unavailable", async () => {
    mockWorld(CATALOG, [claudeStatus(429, { type: "error" })]);
    const res = await start({ text: "hi" });
    await expectError(res, 503, "claude_unavailable");
    expect(res.headers.get("Retry-After")).toBeNull();
  });

  it("Anthropic 500 is retried once, then 502 claude_error", async () => {
    const world = mockWorld(CATALOG, [claudeStatus(500), claudeStatus(503)]);
    await expectError(await start({ text: "hi" }), 502, "claude_error");
    expect(world.claudeCalls).toHaveLength(2);
  });

  it("a network error followed by success is recovered by the retry", async () => {
    const world = mockWorld(CATALOG, [
      () => {
        throw new TypeError("network down");
      },
      claudeReply(question("Q?")),
    ]);
    await ok(await start({ text: "hi" }));
    expect(world.claudeCalls).toHaveLength(2);
  });

  it("Anthropic 401 → 502 claude_error without forwarding Anthropic's body", async () => {
    const world = mockWorld(CATALOG, [
      claudeStatus(401, { type: "error", error: { type: "authentication_error", message: "invalid x-api-key SECRET-DETAIL" } }),
    ]);
    const res = await start({ text: "hi" });
    const text = await res.clone().text();
    await expectError(res, 502, "claude_error");
    expect(text).not.toContain("SECRET-DETAIL");
    expect(text).not.toContain("authentication_error");
    expect(world.claudeCalls).toHaveLength(1);
  });
});

describe("pick resolution", () => {
  it("resolves via primary_release_year, then the year fallback, tolerating en-dash and case", async () => {
    const world = mockWorld(CATALOG, [
      claudeReply(
        recs(
          pick("the wailing", 2016),
          pick("Kairo", 2002), // primary year 2001; only the `year` search finds it
          pick("Mission: Impossible - Fallout", 2018),
        ),
      ),
    ]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));
    const picks = body.messages[1]!.recommendations!;
    expect(picks.map((p) => [p.position, p.tmdb_id, p.title, p.year])).toEqual([
      [1, 101, "The Wailing", 2016],
      [2, 104, "Kairo", 2001],
      [3, 103, `Mission: Impossible ${EN_DASH} Fallout`, 2018],
    ]);

    const kairo = world.tmdbCalls.filter((u) => u.searchParams.get("query") === "Kairo" && u.pathname.endsWith("/search/movie"));
    expect(kairo.map((u) => [u.searchParams.get("primary_release_year"), u.searchParams.get("year")])).toEqual([
      ["2002", null],
      [null, "2002"],
    ]);
  });

  it("drops unresolvable picks, counts them, and keeps positions contiguous", async () => {
    mockWorld(CATALOG, [
      claudeReply(
        recs(
          pick("Not A Real Film", 2010),
          pick("Lake Mungo", 2008),
          pick("Noroi", 1990), // year too far off
          { title: "", year: 2000, why_short: "s", why_full: "f" }, // invalid
          pick("Pulse", 2001),
        ),
      ),
      // W4b: two replacement rounds that yield nothing.
      claudeReply(question("?")),
      claudeReply(question("?")),
    ]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));
    const message = body.messages[1]!;
    expect(message.content).toStrictEqual({ dropped: 3 });
    expect(message.recommendations!.map((p) => [p.position, p.title])).toEqual([
      [1, "Lake Mungo"],
      [2, "Pulse"],
    ]);
  });

  it("all picks unresolvable → 502 recommendation_failed, nothing stored", async () => {
    mockWorld(CATALOG, [
      claudeReply(recs(pick("Nothing", 2000), pick("Nada", 2001))),
      claudeReply(recs(pick("Zilch", 2002), pick("Nix", 2003))),
      claudeReply(recs(pick("Zip", 2004))),
    ]);
    await expectError(await start({ text: "hi" }), 502, "recommendation_failed");
    expect(await count("conversations")).toBe(0);
    expect(await count("messages")).toBe(0);
  });

  it("stores TMDB's id / title / year and the enriched W3 details shape as tmdb_json", async () => {
    mockWorld(CATALOG, [claudeReply(recs(pick("LAKE MUNGO", 2008)))]);
    const body = await ok<ConversationBody>(await start({ text: "hi" }));
    const row = await env.DB.prepare("SELECT tmdb_id, title, year, tmdb_json FROM recommendations").first<{
      tmdb_id: number;
      title: string;
      year: number;
      tmdb_json: string;
    }>();
    expect(row).toMatchObject({ tmdb_id: 102, title: "Lake Mungo", year: 2008 });
    expect(JSON.parse(row!.tmdb_json)).toStrictEqual({
      tmdb_id: 102,
      title: "Lake Mungo",
      original_title: "Lake Mungo",
      release_date: "2008-06-01",
      genres: [{ id: 27, name: "Horror" }],
      is_horror: true,
      runtime: 102 % 30 + 90,
      overview: "Overview of Lake Mungo.",
      poster_path: "/p102.jpg",
      director: null,
      providers: [],
      providers_link: null,
      trailer_key: null,
    });
    expect(body.messages[1]!.recommendations![0]).toMatchObject({ runtime: 102, poster_path: "/p102.jpg" });
  });

  it("TMDB 502 during resolution → 502 tmdb_unavailable, nothing stored", async () => {
    const world = mockWorld(CATALOG, [claudeReply(recs(pick("Noroi", 2005)))]);
    world.tmdbStatus = 502;
    await expectError(await start({ text: "hi" }), 502, "tmdb_unavailable");
    expect(await count("conversations")).toBe(0);
    expect(await count("messages")).toBe(0);
  });
});

describe("endpoints + persistence", () => {
  it("POST /conversations returns the conversation and both messages, title cut at 60", async () => {
    mockWorld(CATALOG, [claudeReply(question("Q?", ["x"]))]);
    const text = "Something slow and unsettling, under two hours, ideally folk horror from the seventies";
    const body = await ok<ConversationBody>(await start({ text }));

    expect(body.conversation).toStrictEqual({
      id: expect.any(String),
      title: "Something slow and unsettling, under two hours, ideally folk",
      model: "claude-sonnet-5",
      question_rounds: 1,
      created_at: expect.any(String),
      updated_at: expect.any(String),
    });
    expect(body.conversation.title.length).toBeLessThanOrEqual(60);
    expect(body.messages).toStrictEqual([
      { id: expect.any(String), seq: 1, role: "user", kind: "text", content: { text, just_pick: false }, created_at: expect.any(String) },
      { id: expect.any(String), seq: 2, role: "assistant", kind: "question", content: { text: "Q?", chips: ["x"] }, created_at: expect.any(String) },
    ]);
  });

  it("POST /conversations/{id}/messages appends seq n+1, n+2 and stores just_pick without text", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(recs(pick("Noroi", 2005))));
    const body = await ok<ConversationBody>(await reply(first.conversation.id, { just_pick: true }));

    expect(body.messages.map((m) => [m.seq, m.role, m.kind])).toEqual([
      [3, "user", "text"],
      [4, "assistant", "recommendations"],
    ]);
    expect(body.messages[0]!.content).toStrictEqual({ text: null, just_pick: true });
    expect(body.conversation.updated_at >= first.conversation.updated_at).toBe(true);
    expect(await count("messages")).toBe(4);
  });

  it("GET /conversations/{id} returns every message with recommendations in position order", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    world.replies.push(claudeReply(recs(pick("Pulse", 2001), pick("Lake Mungo", 2008), pick("Noroi", 2005))));
    const posted = await ok<ConversationBody>(await reply(first.conversation.id, { text: "Short" }));

    const body = await ok<ConversationBody>(await authed(`/conversations/${first.conversation.id}`));
    expect(body.conversation).toStrictEqual(posted.conversation);
    expect(body.messages.map((m) => m.seq)).toEqual([1, 2, 3, 4]);
    expect(body.messages.slice(0, 2)).toStrictEqual(first.messages);
    expect(body.messages.slice(2)).toStrictEqual(posted.messages);

    const picks = body.messages[3]!.recommendations!;
    expect(picks.map((p) => [p.position, p.title])).toEqual([
      [1, "Pulse"],
      [2, "Lake Mungo"],
      [3, "Noroi"],
    ]);
    expect(picks[0]).toStrictEqual({
      id: expect.any(String),
      position: 1,
      tmdb_id: 106,
      title: "Pulse",
      year: 2001,
      why_short: "Short why for Pulse.",
      why_full: "Full why for Pulse. Relates to Hereditary.",
      poster_path: "/p106.jpg",
      runtime: 106 % 30 + 90,
      overview: "Overview of Pulse.",
      director: null,
      providers: [],
      providers_link: null,
      trailer_key: null,
    });
  });

  it("a seq collision from a concurrent send → 409 conversation_busy, nothing written", async () => {
    const world = mockWorld(CATALOG, []);
    const first = await startWithQuestion(world);
    const id = first.conversation.id;
    world.replies.push(async () => {
      // Another request lands seq 3 while this one waits on Claude.
      await env.DB.prepare(
        "INSERT INTO messages (id, conversation_id, seq, role, kind, content_json, created_at) VALUES ('other', ?, 3, 'user', 'text', '{}', 'x')",
      )
        .bind(id)
        .run();
      return claudeReply(question("Era?"))();
    });
    await expectError(await reply(id, { text: "Short" }), 409, "conversation_busy");

    const { results } = await env.DB.prepare("SELECT id, seq FROM messages WHERE conversation_id = ? ORDER BY seq")
      .bind(id)
      .all<{ id: string; seq: number }>();
    expect(results.map((r) => r.seq)).toEqual([1, 2, 3]);
    expect(results[2]!.id).toBe("other");
    const row = await env.DB.prepare("SELECT question_rounds, updated_at FROM conversations WHERE id = ?")
      .bind(id)
      .first<{ question_rounds: number; updated_at: string }>();
    expect(row).toStrictEqual({ question_rounds: 1, updated_at: first.conversation.updated_at });
  });

  it("builds the prompt from a ~1,000-film library with a fixed number of statements", async () => {
    await clearAll();
    await seedLibrary(
      Array.from({ length: 1000 }, (_, i) => ({
        name: `Film ${String(i).padStart(4, "0")}`,
        year: 1950 + (i % 70),
        horror: i % 2 === 0,
        half_stars: i % 3 === 0 ? undefined : (i % 10) + 1,
        watched: true,
        watchlist: false,
      })),
    );
    const world = mockWorld(CATALOG, [claudeReply(question("Q?"))]);
    await ok(await start({ text: "hi" }));
    const system = world.claudeCalls[0]!.body.system;
    expect(system).toContain("Film 0000 (1950)");
    expect(system).toContain("Film 0999 (1969)");
  });
});
