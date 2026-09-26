import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { DRAFT_MAX_TOKENS, DRAFT_SCHEMA, mergeNotes } from "../src/taste/draft";
import { claudeReply, clearAll, mockWorld, seedLibrary } from "./conversations-helpers";
import { BASE, authed, count, expectError, ok, send } from "./helpers";

interface Profile {
  content: string;
  based_on_import_id: number | null;
  updated_at: string;
}

const draft = (body: unknown = {}) => send("POST", "/taste-profile/draft", body);
const save = (content: unknown) => send("PUT", "/taste-profile", { content });

const SECTIONS = "## Loves\nSlow dread.\n\n## Enjoys\nFolk horror.\n\n## Mixed on\nFound footage.\n\n## Tends to dislike\nGore.";
// Irregular spacing on purpose: must survive byte-for-byte.
const NOTES = "## Notes\nUnder ~2 hours on weeknights.  \n\n  - no clowns\n* Subtitles fine";

async function addImport(): Promise<number> {
  const row = await env.DB.prepare(
    `INSERT INTO imports (imported_at, source_filename, ratings_count, watched_count, watchlist_count, likes_count, new_films_count)
     VALUES (?, 'x.zip', 0, 0, 0, 0, 0) RETURNING id`,
  )
    .bind(new Date().toISOString())
    .first<{ id: number }>();
  return row!.id;
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
    { name: "Heat", year: 1995, horror: false, half_stars: 8, watched: true },
  ]);
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("migration 0003", () => {
  it("creates taste_profile and rejects a second row", async () => {
    await env.DB.prepare("INSERT INTO taste_profile (id, content, updated_at) VALUES (1, 'x', 'now')").run();
    await expect(
      env.DB.prepare("INSERT INTO taste_profile (id, content, updated_at) VALUES (2, 'y', 'now')").run(),
    ).rejects.toThrow(/CHECK constraint failed/);
  });
});

describe("taste profile CRUD", () => {
  it("GET before any save → 404 no_taste_profile", async () => {
    await expectError(await authed("/taste-profile"), 404, "no_taste_profile");
  });

  it("PUT saves trimmed content with based_on_import_id null when there are no imports", async () => {
    const saved = await ok<Profile>(await save(`  ${SECTIONS}\n`));
    expect(saved).toStrictEqual({ content: SECTIONS, based_on_import_id: null, updated_at: expect.any(String) });
    expect(await ok<Profile>(await authed("/taste-profile"))).toStrictEqual(saved);
  });

  it("PUT sets based_on_import_id to the latest import; a second PUT overwrites the single row", async () => {
    await addImport();
    const latest = await addImport();
    expect((await ok<Profile>(await save("first"))).based_on_import_id).toBe(latest);
    const second = await ok<Profile>(await save("second"));
    expect(second.content).toBe("second");
    expect(await count("taste_profile")).toBe(1);
  });

  it("PUT rejects empty, whitespace-only, non-string, and > 4,000 characters; accepts exactly 4,000", async () => {
    for (const content of ["", "   ", 5, null, "x".repeat(4001)]) {
      await expectError(await save(content), 400, "invalid_request");
    }
    await ok(await save("x".repeat(4000)));
  });

  it("GET / PUT work with ANTHROPIC_API_KEY unset", async () => {
    const overrides = { ...env, ANTHROPIC_API_KEY: "" } as Env;
    const request = (method: string, body?: unknown) =>
      new Request(`${BASE}/taste-profile`, {
        method,
        body: body === undefined ? undefined : JSON.stringify(body),
        headers: { Authorization: `Bearer ${env.API_KEY}` },
      }) as Parameters<typeof worker.fetch>[0];
    expect((await worker.fetch(request("PUT", { content: "hi" }), overrides)).status).toBe(200);
    expect((await worker.fetch(request("GET"), overrides)).status).toBe(200);
  });
});

describe("POST /taste-profile/draft", () => {
  it("no horror ratings → 422 no_ratings without calling Claude", async () => {
    await clearAll();
    await seedLibrary([{ name: "Heat", year: 1995, horror: false, half_stars: 8, watched: true }]);
    const spy = forbidFetch();
    await expectError(await draft(), 422, "no_ratings");
    expect(spy).not.toHaveBeenCalled();
  });

  it("first draft: ratings only, draft schema + DRAFT_MAX_TOKENS, changes forced to []", async () => {
    const world = mockWorld([], [claudeReply({ content: SECTIONS, changes: ["should be dropped"] })]);
    const body = await ok(await draft({ model: "claude-haiku-4-5-20251001" }));
    expect(body).toStrictEqual({ content: SECTIONS, changes: [] });

    const call = world.claudeCalls[0]!.body;
    expect(call.model).toBe("claude-haiku-4-5-20251001");
    expect(call.max_tokens).toBe(DRAFT_MAX_TOKENS);
    expect(call.output_config).toStrictEqual({ format: { type: "json_schema", schema: DRAFT_SCHEMA } });
    expect(call.system).toContain("## Tends to dislike");
    expect(call.system).toContain('Do not write a "Notes" section');
    const turn = call.messages[0]!.content;
    expect(call.messages).toHaveLength(1);
    expect(turn).toContain("<horror_ratings>\nHereditary (2018) — ★5\nThe Witch (2015) — ★4.5\n</horror_ratings>");
    expect(turn).not.toContain("Heat");
    expect(turn).not.toContain("<current_profile>");
  });

  it("redraft: sends the labeled current profile; keeps changes; appends saved Notes verbatim, strips Claude's", async () => {
    const current = `${SECTIONS}\n\n${NOTES}`;
    await ok(await save(current));
    const claudeContent = "## Loves\nDread.\n\n## Notes\nClaude's notes.\n\n## Enjoys\nFolk.";
    const world = mockWorld([], [claudeReply({ content: claudeContent, changes: [" Moved folk ", "", "Kept gore"] })]);

    const body = await ok<{ content: string; changes: string[] }>(await draft());
    expect(body.changes).toEqual(["Moved folk", "Kept gore"]);
    expect(body.content).toBe(`## Loves\nDread.\n\n## Enjoys\nFolk.\n\n${NOTES}`);
    expect(body.content.endsWith(NOTES)).toBe(true);
    expect(body.content).not.toContain("Claude's notes");

    const turn = world.claudeCalls[0]!.body.messages[0]!.content;
    expect(turn).toContain(`<current_profile>`);
    expect(turn).toContain(current);
    // Draft does not save.
    expect((await ok<Profile>(await authed("/taste-profile"))).content).toBe(current);
  });

  it("Notes in the middle of the saved profile are carried over too", async () => {
    await ok(await save(`## Loves\nDread.\n\n${NOTES}\n\n## Enjoys\nFolk.`));
    mockWorld([], [claudeReply({ content: SECTIONS, changes: [] })]);
    const body = await ok<{ content: string }>(await draft());
    expect(body.content).toBe(`${SECTIONS}\n\n${NOTES}`);
  });

  it("no saved Notes + Claude writes Notes → stripped, nothing appended", async () => {
    await ok(await save(SECTIONS));
    mockWorld([], [claudeReply({ content: `${SECTIONS}\n\n## Notes\nInvented.`, changes: [] })]);
    const body = await ok<{ content: string }>(await draft());
    expect(body.content).toBe(SECTIONS);
  });

  it("does not write to taste_profile", async () => {
    mockWorld([], [claudeReply({ content: SECTIONS, changes: [] })]);
    await ok(await draft());
    expect(await count("taste_profile")).toBe(0);
  });

  it("unknown model → 400 invalid_model; missing ANTHROPIC_API_KEY → 500; empty body → 400", async () => {
    const spy = forbidFetch();
    await expectError(await draft({ model: "gpt-4" }), 400, "invalid_model");
    const res = await worker.fetch(
      new Request(`${BASE}/taste-profile/draft`, {
        method: "POST",
        body: "{}",
        headers: { Authorization: `Bearer ${env.API_KEY}` },
      }) as Parameters<typeof worker.fetch>[0],
      { ...env, ANTHROPIC_API_KEY: "" } as Env,
    );
    await expectError(res, 500, "internal_error");
    await expectError(await authed("/taste-profile/draft", { method: "POST" }), 400, "invalid_json");
    expect(spy).not.toHaveBeenCalled();
  });

  it.each([
    ["refusal", { content: SECTIONS, changes: [] }, "refusal"],
    ["max_tokens", { content: SECTIONS, changes: [] }, "max_tokens"],
    ["empty content", { content: "   ", changes: [] }, "end_turn"],
    ["only Notes", { content: "## Notes\nx", changes: [] }, "end_turn"],
  ])("%s → 502 claude_error", async (_name, output, stopReason) => {
    mockWorld([], [claudeReply(output, stopReason)]);
    await expectError(await draft(), 502, "claude_error");
  });
});

describe("mergeNotes", () => {
  it("handles CRLF headings and multiple Claude Notes sections", () => {
    expect(mergeNotes("## Loves\r\nA\r\n\r\n## notes\r\nB\r\n\r\n## Enjoys\r\nC\r\n## NOTES\nD", null)).toBe(
      "## Loves\r\nA\r\n\r\n## Enjoys\r\nC",
    );
    expect(mergeNotes("## Loves\nA", "## Loves\nX\n\n### Notes\nsub-heading, not a section")).toBe("## Loves\nA");
  });
});
