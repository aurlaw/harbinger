import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { truncateOverview } from "../src/recent/prompt";
import { monthsBefore, refreshRecentReleases } from "../src/recent/refresh";
import {
  type World,
  claudeReply,
  clearAll,
  discoverFilm,
  film,
  mockWorld,
  pick,
  question,
  recs,
  seedLibrary,
  setRecentReleasesJob,
} from "./conversations-helpers";
import { call, count, expectError, ok, range, send, tick } from "./helpers";

const DASH = String.fromCodePoint(0x2014);
const ELLIPSIS = String.fromCodePoint(0x2026);
const NOW = new Date("2026-10-02T20:00:00.000Z");
const CRON = "0 20 * * 5";
const HEADING = "## Recent releases you may not know (optional candidates)";
const GUIDANCE = `These horror films came out in the last ~18 months and may be newer than your training data. Recommend one only when it genuinely fits their taste and the request ${DASH} this is not a list you must use.`;

interface ReleaseRow {
  tmdb_id: number;
  title: string;
  release_date: string | null;
  year: number | null;
  overview: string;
  genre_ids: string;
  popularity: number;
  rank: number;
}

interface JobRow {
  last_success_at: string | null;
  last_error: string | null;
  updated_at: string;
}

const releases = async () =>
  (await env.DB.prepare("SELECT * FROM recent_releases ORDER BY rank").all<ReleaseRow>()).results;
const jobState = () =>
  env.DB.prepare("SELECT last_success_at, last_error, updated_at FROM job_state WHERE name = 'recent_releases'").first<JobRow>();

const start = (body: unknown) => send("POST", "/conversations", body);
const reply = (id: string, body: unknown) => send("POST", `/conversations/${id}/messages`, body);
const runJob = () => send("POST", "/jobs/recent-releases", {});

/** Loads `films` into recent_releases through the real refresh, leaving the job fresh. */
async function loadReleases(world: World, films: unknown[], at = new Date()): Promise<void> {
  world.discoverPages = [films];
  expect(await refreshRecentReleases(env, at)).toMatchObject({ ok: true });
  world.discoverCalls.length = 0;
}

function section(system: string): string {
  const startAt = system.indexOf(HEADING);
  expect(startAt).toBeGreaterThan(-1);
  const rest = system.slice(startAt + HEADING.length);
  return rest.slice(0, rest.indexOf("\n## ")).trim();
}

const lines = (system: string) => section(system).split("\n").slice(1);

beforeEach(async () => {
  await clearAll();
  await setRecentReleasesJob(null);
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("migration 0005", () => {
  it("creates recent_releases and job_state", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('recent_releases', 'job_state') ORDER BY name",
    ).all<{ name: string }>();
    expect(results.map((r) => r.name)).toEqual(["job_state", "recent_releases"]);
  });
});

describe("refreshRecentReleases", () => {
  it("requests pages 1 and 2 of /discover/movie with every parameter, dated from the injected now", async () => {
    const world = mockWorld([], []);
    world.discoverPages = [[discoverFilm(1, "One")]];
    await refreshRecentReleases(env, new Date("2026-08-31T20:00:00.000Z"));

    expect(world.discoverCalls.map((u) => u.searchParams.get("page")).sort()).toEqual(["1", "2"]);
    for (const url of world.discoverCalls) {
      const params = Object.fromEntries(url.searchParams);
      delete params.page;
      expect(params).toStrictEqual({
        language: "en-US",
        with_genres: "27",
        "primary_release_date.gte": "2025-02-28",
        "primary_release_date.lte": "2026-08-31",
        sort_by: "popularity.desc",
        "vote_count.gte": "25",
        "with_runtime.gte": "60",
        include_adult: "false",
        include_video: "false",
      });
    }
    expect(world.tmdbCalls).toHaveLength(0);
    expect(world.unexpected).toEqual([]);
  });

  it("computes 18 months back in UTC, clamping to the month's last day", () => {
    const back = (iso: string) => monthsBefore(new Date(iso), 18);
    expect(back("2026-08-31T20:00:00.000Z")).toBe("2025-02-28");
    expect(back("2025-08-31T00:00:00.000Z")).toBe("2024-02-29");
    expect(back("2026-10-02T20:00:00.000Z")).toBe("2025-04-02");
    expect(back("2026-03-15T23:59:59.000Z")).toBe("2024-09-15");
    expect(back("2026-12-31T00:00:00.000Z")).toBe("2025-06-30");
  });

  it("replaces the whole table atomically; ranks contiguous; duplicates across pages collapsed", async () => {
    const world = mockWorld([], []);
    await loadReleases(world, [discoverFilm(900, "Old One"), discoverFilm(901, "Old Two")], new Date("2026-09-25T20:00:00.000Z"));

    const pageOne = range(20).map((i) => discoverFilm(i + 1, `Film ${i + 1}`));
    // TMDB pagination shifted: film 20 shows up again at the top of page 2.
    const pageTwo = [discoverFilm(20, "Film 20"), ...range(19).map((i) => discoverFilm(i + 21, `Film ${i + 21}`))];
    world.discoverPages = [pageOne, pageTwo];
    const result = await refreshRecentReleases(env, NOW);

    expect(result).toStrictEqual({ ok: true, count: 39, last_success_at: NOW.toISOString() });
    const rows = await releases();
    expect(rows.map((r) => r.rank)).toEqual(range(39).map((i) => i + 1));
    expect(rows.map((r) => r.tmdb_id)).toEqual(range(39).map((i) => i + 1));
    expect(await jobState()).toStrictEqual({
      last_success_at: NOW.toISOString(),
      last_error: null,
      updated_at: NOW.toISOString(),
    });
  });

  it('stores release_date "" as NULL date and year, and genre_ids as JSON', async () => {
    const world = mockWorld([], []);
    world.discoverPages = [
      [
        discoverFilm(1, "Dated", { release_date: "2026-03-13", genre_ids: [27, 53], popularity: 88.5 }),
        discoverFilm(2, "Undated", { release_date: "", genre_ids: [27] }),
      ],
    ];
    await refreshRecentReleases(env, NOW);

    const [dated, undated] = await releases();
    expect(dated).toStrictEqual({
      tmdb_id: 1,
      title: "Dated",
      release_date: "2026-03-13",
      year: 2026,
      overview: "Overview of Dated.",
      genre_ids: "[27,53]",
      popularity: 88.5,
      rank: 1,
    });
    expect(undated).toMatchObject({ release_date: null, year: null, genre_ids: "[27]", rank: 2 });
  });

  it("TMDB failure on page 2 keeps the previous list, sets last_error, leaves last_success_at", async () => {
    const world = mockWorld([], []);
    const before = new Date("2026-09-25T20:00:00.000Z");
    await loadReleases(world, [discoverFilm(900, "Old One"), discoverFilm(901, "Old Two")], before);

    world.discoverPages = [[discoverFilm(1, "New")], [discoverFilm(2, "Newer")]];
    world.discoverFailPage = 2;
    const result = await refreshRecentReleases(env, NOW);

    expect(result).toStrictEqual({ ok: false, error: "tmdb_unavailable" });
    expect((await releases()).map((r) => r.tmdb_id)).toEqual([900, 901]);
    expect(await jobState()).toStrictEqual({
      last_success_at: before.toISOString(),
      last_error: "tmdb_unavailable",
      updated_at: NOW.toISOString(),
    });
  });

  it("zero results is a failure: previous list kept, last_error = 'empty result'", async () => {
    const world = mockWorld([], []);
    const before = new Date("2026-09-25T20:00:00.000Z");
    await loadReleases(world, [discoverFilm(900, "Old One")], before);

    world.discoverPages = [[], []];
    expect(await refreshRecentReleases(env, NOW)).toStrictEqual({ ok: false, error: "empty result" });
    expect((await releases()).map((r) => r.tmdb_id)).toEqual([900]);
    expect(await jobState()).toMatchObject({ last_success_at: before.toISOString(), last_error: "empty result" });
  });

  it("a first-ever failure records the error with no last_success_at; a later success clears it", async () => {
    const world = mockWorld([], []);
    world.tmdbStatus = 503;
    await refreshRecentReleases(env, NOW);
    expect(await jobState()).toStrictEqual({ last_success_at: null, last_error: "tmdb_unavailable", updated_at: NOW.toISOString() });

    world.tmdbStatus = undefined;
    world.discoverPages = [[discoverFilm(1, "One")]];
    await refreshRecentReleases(env, NOW);
    expect(await jobState()).toMatchObject({ last_success_at: NOW.toISOString(), last_error: null });
  });

  it("logs one summary line with count, date range, and outcome", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const world = mockWorld([], []);
    world.discoverPages = [[discoverFilm(1, "One"), discoverFilm(2, "Two")]];
    await refreshRecentReleases(env, NOW);

    const summaries = log.mock.calls
      .map(([line]) => (typeof line === "string" && line.startsWith("{") ? JSON.parse(line) : null))
      .filter((l) => l?.event === "recent_releases_refresh");
    expect(summaries).toStrictEqual([
      { event: "recent_releases_refresh", outcome: "success", from: "2025-04-02", to: "2026-10-02", count: 2 },
    ]);
  });
});

describe("scheduled", () => {
  async function runScheduled(cron: string): Promise<void> {
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ scheduledTime: NOW, cron }), env, ctx);
    await waitOnExecutionContext(ctx);
  }

  it("cron 0 20 * * 5 runs the refresh as of the scheduled time", async () => {
    const world = mockWorld([], []);
    world.discoverPages = [[discoverFilm(1, "One")]];
    await runScheduled(CRON);

    expect(world.discoverCalls).toHaveLength(2);
    expect(world.discoverCalls[0]!.searchParams.get("primary_release_date.lte")).toBe("2026-10-02");
    expect(await count("recent_releases")).toBe(1);
    expect((await jobState())?.last_success_at).toBe(NOW.toISOString());
  });

  it("an unknown cron logs a warning and does nothing", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const world = mockWorld([], []);
    await runScheduled("0 21 * * 5");

    expect(warn).toHaveBeenCalledTimes(1);
    expect(String(warn.mock.calls[0]![0])).toContain("0 21 * * 5");
    expect(world.discoverCalls).toHaveLength(0);
    expect(await jobState()).toBeNull();
  });

  it("a refresh error doesn't throw out of scheduled", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new Error("network down");
    });
    await expect(runScheduled(CRON)).resolves.toBeUndefined();
    expect((await jobState())?.last_error).toBe("tmdb_unavailable");
  });

  it("a failing database doesn't throw out of scheduled either", async () => {
    mockWorld([], []).discoverPages = [[discoverFilm(1, "One")]];
    const broken = { ...env, DB: { prepare: () => { throw new Error("db down"); }, batch: () => { throw new Error("db down"); } } };
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ scheduledTime: NOW, cron: CRON }), broken as unknown as Env, ctx);
    await expect(waitOnExecutionContext(ctx)).resolves.toBeUndefined();
  });
});

describe("stale fallback", () => {
  const daysAgo = (days: number) => new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();

  async function turn(lastSuccessAt: string | null): Promise<World> {
    const world = mockWorld([], [claudeReply(question("Q?"))]);
    world.discoverPages = [[discoverFilm(1, "Fresh Film")]];
    await setRecentReleasesJob(lastSuccessAt);
    await ok(await start({ text: "hi" }));
    return world;
  }

  it("last_success_at 9 days old → refresh runs before the prompt is built", async () => {
    const world = await turn(daysAgo(9));
    expect(world.discoverCalls).toHaveLength(2);
    expect(lines(world.claudeCalls[0]!.body.system)).toEqual([`Fresh Film (2026) ${DASH} Overview of Fresh Film.`]);
  });

  it("2 days old → no refresh", async () => {
    const world = await turn(daysAgo(2));
    expect(world.discoverCalls).toHaveLength(0);
    expect(lines(world.claudeCalls[0]!.body.system)).toEqual(["(none)"]);
  });

  it("missing → refresh", async () => {
    const world = await turn(null);
    expect(world.discoverCalls).toHaveLength(2);
    expect(section(world.claudeCalls[0]!.body.system)).toContain("Fresh Film (2026)");
  });

  it("refresh failure → the turn still succeeds using the existing list, with one attempt", async () => {
    const world = mockWorld([], [claudeReply(question("Q?"))]);
    await loadReleases(world, [discoverFilm(900, "Old One")], new Date(daysAgo(9)));
    world.discoverFailPage = 1;

    await ok(await start({ text: "hi" }));
    expect(world.discoverCalls).toHaveLength(2);
    expect(lines(world.claudeCalls[0]!.body.system)).toEqual([`Old One (2026) ${DASH} Overview of Old One.`]);
    expect((await jobState())?.last_error).toBe("tmdb_unavailable");
  });

  it("refresh failure with no list at all → the turn succeeds with (none)", async () => {
    const world = mockWorld([], [claudeReply(question("Q?"))]);
    world.discoverFailPage = 2;
    await ok(await start({ text: "hi" }));
    expect(lines(world.claudeCalls[0]!.body.system)).toEqual(["(none)"]);
  });
});

describe("POST /jobs/recent-releases", () => {
  it("runs the refresh → 200 with count and last_success_at", async () => {
    const world = mockWorld([], []);
    world.discoverPages = [[discoverFilm(1, "One"), discoverFilm(2, "Two")], [discoverFilm(3, "Three")]];
    const body = await ok<{ count: number; last_success_at: string }>(await runJob());

    expect(body).toStrictEqual({ count: 3, last_success_at: expect.any(String) });
    expect(await count("recent_releases")).toBe(3);
    expect((await jobState())?.last_success_at).toBe(body.last_success_at);
  });

  it("unauthenticated → 401 with no outbound request", async () => {
    const world = mockWorld([], []);
    await expectError(await call("/jobs/recent-releases", { method: "POST" }), 401, "unauthorized");
    expect(world.discoverCalls).toHaveLength(0);
  });

  it("wrong method → 405", async () => {
    const res = await send("PUT", "/jobs/recent-releases", {});
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("POST");
  });

  it("TMDB failure → 502 tmdb_unavailable, list unchanged", async () => {
    const world = mockWorld([], []);
    await loadReleases(world, [discoverFilm(900, "Old One")]);
    world.tmdbStatus = 500;

    await expectError(await runJob(), 502, "tmdb_unavailable");
    expect((await releases()).map((r) => r.tmdb_id)).toEqual([900]);
  });
});

describe("prompt section", () => {
  const HEADINGS = [
    "## Taste profile",
    "## Horror ratings",
    HEADING,
    "## Never recommend (already seen)",
    "## Never recommend (already on watchlist)",
  ];

  async function systemWith(films: unknown[]): Promise<string> {
    const world = mockWorld([], [claudeReply(question("Q?"))]);
    if (films.length > 0) await loadReleases(world, films);
    else await setRecentReleasesJob(new Date().toISOString());
    await ok(await start({ text: "hi" }));
    return world.claudeCalls[0]!.body.system;
  }

  it("sits after ratings and before the never-recommend lists, with the header and guidance", async () => {
    const system = await systemWith([discoverFilm(1, "One")]);
    const positions = HEADINGS.map((h) => system.indexOf(`\n${h}`));
    expect(positions.every((p) => p > 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
    expect(section(system)).toBe(`${GUIDANCE}\nOne (2026) ${DASH} Overview of One.`);
    expect(system.slice(0, system.indexOf("\n## "))).toContain('The "Recent releases" list below may describe films you don\'t know.');
  });

  it("lists films in rank order as Title (Year) + overview; no year or overview when TMDB has none", async () => {
    const system = await systemWith([
      discoverFilm(30, "Third Popular First", { release_date: "2025-11-07" }),
      discoverFilm(10, "Undated", { release_date: "" }),
      discoverFilm(20, "No Overview", { overview: "" }),
      discoverFilm(5, "Multi Line", { overview: "First line.\n\nSecond   line." }),
    ]);
    expect(lines(system)).toEqual([
      `Third Popular First (2025) ${DASH} Overview of Third Popular First.`,
      `Undated ${DASH} Overview of Undated.`,
      "No Overview (2026)",
      `Multi Line (2026) ${DASH} First line. Second line.`,
    ]);
  });

  it("truncates the overview at a word boundary near 200 characters", async () => {
    const long = range(60).map((i) => `word${i}`).join(" ");
    const [line] = lines(await systemWith([discoverFilm(1, "Long", { overview: long })]));
    const overview = line!.slice(`Long (2026) ${DASH} `.length);

    expect(overview.endsWith(ELLIPSIS)).toBe(true);
    const kept = overview.slice(0, -1);
    expect(kept.length).toBeLessThanOrEqual(200);
    expect(kept.length).toBeGreaterThan(180);
    expect(long.startsWith(kept)).toBe(true);
    expect(long[kept.length]).toBe(" ");

    expect(truncateOverview("x".repeat(200))).toBe("x".repeat(200));
    expect(truncateOverview("x".repeat(250))).toBe(`${"x".repeat(200)}${ELLIPSIS}`);
    expect(truncateOverview(`${"a".repeat(200)} tail`)).toBe(`${"a".repeat(200)}${ELLIPSIS}`);
    const ghost = String.fromCodePoint(0x1f47b);
    expect(truncateOverview(ghost.repeat(250))).toBe(`${ghost.repeat(200)}${ELLIPSIS}`);
  });

  it("omits a recent release that's in watched or watchlist", async () => {
    await seedLibrary([
      { name: "Seen It", year: 2026, tmdb_id: 1, horror: true, half_stars: 8, watched: true },
      { name: "Queued", year: 2026, tmdb_id: 2, horror: true, watchlist: true },
      // In films but in neither set: still a candidate.
      { name: "Just Matched", year: 2026, tmdb_id: 3, horror: true },
    ]);
    const system = await systemWith([
      discoverFilm(1, "Seen It"),
      discoverFilm(2, "Queued"),
      discoverFilm(3, "Just Matched"),
      discoverFilm(4, "Unknown"),
    ]);
    expect(lines(system).map((l) => l.split(" (")[0])).toEqual(["Just Matched", "Unknown"]);
  });

  it("still lists a recent release with a No decision (validation handles it)", async () => {
    const now = new Date().toISOString();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES ('c-no', 'claude-sonnet-5', 't', 0, ?1, ?1)").bind(now),
      env.DB.prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (1, 'no', 'c-no', ?)").bind(now),
    ]);
    const system = await systemWith([discoverFilm(1, "Rejected Before"), discoverFilm(2, "Other")]);
    expect(lines(system).map((l) => l.split(" (")[0])).toEqual(["Rejected Before", "Other"]);
  });

  it("a pick from the list with a No decision is rejected by validation, not by the prompt", async () => {
    const catalog = [film(1, "Rejected Before", 2026), film(2, "Other", 2026)];
    const world = mockWorld(catalog, [
      claudeReply(recs(pick("Rejected Before", 2026), pick("Other", 2026))),
      claudeReply(recs()),
      claudeReply(recs()),
    ]);
    await loadReleases(world, [discoverFilm(1, "Rejected Before"), discoverFilm(2, "Other")]);
    const now = new Date().toISOString();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO conversations (id, model, title, question_rounds, created_at, updated_at) VALUES ('c-no', 'claude-sonnet-5', 't', 0, ?1, ?1)").bind(now),
      env.DB.prepare("INSERT INTO decisions (tmdb_id, decision, conversation_id, decided_at) VALUES (1, 'no', 'c-no', ?)").bind(now),
    ]);

    const body = await ok<{ messages: { recommendations?: { tmdb_id: number }[] }[] }>(await start({ text: "something recent" }));
    expect(body.messages[1]!.recommendations!.map((r) => r.tmdb_id)).toEqual([2]);
  });

  it("empty table → (none)", async () => {
    expect(section(await systemWith([]))).toBe(`${GUIDANCE}\n(none)`);
  });

  it("is byte-identical across two turns with unchanged state", async () => {
    const world = mockWorld([], [claudeReply(question("Q?")), claudeReply(question("Again?"))]);
    await loadReleases(world, range(30).map((i) => discoverFilm(i + 1, `Film ${i + 1}`)));
    const first = await ok<{ conversation: { id: string } }>(await start({ text: "hi" }));
    await tick();
    await ok(await reply(first.conversation.id, { text: "more" }));

    const [a, b] = world.claudeCalls.map((c) => c.body.system);
    expect(lines(a!)).toHaveLength(30);
    expect(b).toBe(a);
    expect(world.discoverCalls).toHaveLength(0);
  });

  it("the taste-profile draft prompt does not include recent releases", async () => {
    await seedLibrary([{ name: "Hereditary", year: 2018, horror: true, half_stars: 10, watched: true }]);
    const world = mockWorld([], [claudeReply({ content: "## Loves\nDread.", changes: [] })]);
    await loadReleases(world, [discoverFilm(1, "Brand New Film")]);
    await setRecentReleasesJob(null);
    await ok(await send("POST", "/taste-profile/draft", {}));

    const draft = JSON.stringify(world.claudeCalls[0]!.body);
    expect(draft).not.toContain("Recent releases");
    expect(draft).not.toContain("Brand New Film");
    // A draft never triggers the stale fallback.
    expect(world.discoverCalls).toHaveLength(0);
  });
});
