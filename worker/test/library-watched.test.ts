import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { claudeReply, clearAll, film as catalogFilm, mockWorld, pick, recs } from "./conversations-helpers";
import { BASE, authed, call, expectError, ok, range, send, uri } from "./helpers";

interface WatchedFilm {
  letterboxd_uri: string;
  tmdb_id: number | null;
  title: string;
  year: number;
  half_stars: number | null;
  logged_on: string | null;
  poster_path: string | null;
  is_horror: boolean;
  harbinger_pick: boolean;
  first_recommended_at: string | null;
}

interface WatchedBody {
  last_import_at: string | null;
  films: WatchedFilm[];
}

interface Seed {
  n: number | string;
  name?: string;
  year?: number;
  /** Omit for an unmatched film. */
  tmdb_id?: number;
  horror?: boolean;
  override?: "include" | "exclude";
  /** The stored TMDB details; defaults to one with a poster when matched. */
  tmdb_json?: unknown;
  watched?: string | null | false;
  half_stars?: number;
  watchlist?: boolean;
}

/** Library rows as the CLI's import would leave them (fixed statement count). */
async function seed(films: Seed[]): Promise<void> {
  const rows = films.map((f) => {
    const matched = f.tmdb_id !== undefined;
    const details = f.tmdb_json === undefined ? { title: `TMDB ${f.n}`, poster_path: `/p${f.n}.jpg` } : f.tmdb_json;
    return {
      uri: uri(f.n),
      name: f.name ?? `Film ${f.n}`,
      year: f.year ?? 2000,
      tmdb_id: f.tmdb_id ?? null,
      status: matched ? "matched" : "unmatched",
      is_horror: matched ? (f.horror ? 1 : 0) : null,
      override: f.override ?? null,
      tmdb_json: matched && details !== null ? JSON.stringify(details) : null,
      watched: f.watched === undefined ? "2024-01-01" : f.watched,
      is_watched: f.watched !== false ? 1 : 0,
      half_stars: f.half_stars ?? null,
      watchlist: f.watchlist ? 1 : 0,
    };
  });
  const payload = JSON.stringify(rows);
  const x = (field: string) => `json_extract(value, '$.${field}')`;
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO films (letterboxd_uri, name, year, tmdb_id, match_status, is_horror, genre_override, tmdb_json, created_at)
       SELECT ${x("uri")}, ${x("name")}, ${x("year")}, ${x("tmdb_id")}, ${x("status")}, ${x("is_horror")},
              ${x("override")}, ${x("tmdb_json")}, '2026-09-24T00:00:00.000Z'
       FROM json_each(?)`,
    ).bind(payload),
    env.DB.prepare(
      `INSERT INTO watched (letterboxd_uri, logged_on) SELECT ${x("uri")}, ${x("watched")} FROM json_each(?) WHERE ${x("is_watched")}`,
    ).bind(payload),
    env.DB.prepare(
      `INSERT INTO ratings (letterboxd_uri, half_stars) SELECT ${x("uri")}, ${x("half_stars")} FROM json_each(?)
       WHERE ${x("half_stars")} IS NOT NULL`,
    ).bind(payload),
    env.DB.prepare(`INSERT INTO watchlist (letterboxd_uri) SELECT ${x("uri")} FROM json_each(?) WHERE ${x("watchlist")}`).bind(
      payload,
    ),
  ]);
}

const addImport = (importedAt: string) =>
  env.DB.prepare(
    `INSERT INTO imports (imported_at, source_filename, ratings_count, watched_count, watchlist_count, likes_count, new_films_count)
     VALUES (?, 'x.zip', 0, 0, 0, 0, 0)`,
  )
    .bind(importedAt)
    .run();

const logPick = (tmdbId: number, at: string) =>
  env.DB.prepare(
    "INSERT INTO pick_log (tmdb_id, title, year, model, conversation_id, first_recommended_at) VALUES (?, 'Logged', 2020, 'claude-sonnet-5', 'c-gone', ?)",
  )
    .bind(tmdbId, at)
    .run();

const watched = async () => ok<WatchedBody>(await authed("/library/watched"));
const byUri = (body: WatchedBody, n: number | string) => body.films.find((f) => f.letterboxd_uri === uri(n));

beforeEach(clearAll);

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /library/watched", () => {
  it("unauthenticated → 401", async () => {
    await expectError(await call("/library/watched"), 401, "unauthorized");
  });

  it("POST → 405", async () => {
    const res = await send("POST", "/library/watched", {});
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
  });

  it("empty library → null import and no films", async () => {
    expect(await watched()).toStrictEqual({ last_import_at: null, films: [] });
  });

  it("returns exactly the documented fields for a matched, rated film", async () => {
    await seed([{ n: 1, name: "Jack Reacher", year: 2012, tmdb_id: 123, half_stars: 6, watched: "2021-03-11" }]);

    expect((await watched()).films).toStrictEqual([
      {
        letterboxd_uri: uri(1),
        tmdb_id: 123,
        title: "Jack Reacher",
        year: 2012,
        half_stars: 6,
        logged_on: "2021-03-11",
        poster_path: "/p1.jpg",
        is_horror: false,
        harbinger_pick: false,
        first_recommended_at: null,
      },
    ]);
  });
});

describe("rows", () => {
  it("lists every watched film exactly once and nothing that isn't watched", async () => {
    await seed([
      { n: 1, tmdb_id: 1, half_stars: 8 },
      { n: 2, tmdb_id: 2 },
      { n: 3 },
      { n: "list", tmdb_id: 4, watched: false, watchlist: true },
      { n: "rated-only", tmdb_id: 5, watched: false, half_stars: 9 },
      { n: "known", tmdb_id: 6, watched: false },
    ]);

    const { films } = await watched();
    expect(films.map((f) => f.letterboxd_uri).sort()).toEqual([uri(1), uri(2), uri(3)]);
  });

  it("a film that shares its tmdb_id with another watched film still appears once each", async () => {
    await seed([
      { n: "a", tmdb_id: 7 },
      { n: "b", tmdb_id: 7 },
    ]);
    await logPick(7, "2026-09-01T00:00:00.000Z");

    const { films } = await watched();
    expect(films.map((f) => f.letterboxd_uri)).toEqual([uri("a"), uri("b")]);
    expect(films.every((f) => f.harbinger_pick)).toBe(true);
  });

  it("rated → half_stars; unrated → null", async () => {
    await seed([
      { n: 1, tmdb_id: 1, half_stars: 9 },
      { n: 2, tmdb_id: 2 },
    ]);
    const body = await watched();
    expect(byUri(body, 1)!.half_stars).toBe(9);
    expect(byUri(body, 2)!.half_stars).toBeNull();
  });

  it("poster_path comes from tmdb_json; missing → null", async () => {
    await seed([
      { n: 1, tmdb_id: 1, tmdb_json: { title: "A", poster_path: "/a.jpg", genres: [] } },
      { n: 2, tmdb_id: 2, tmdb_json: { title: "B" } },
      { n: 3, tmdb_id: 3, tmdb_json: { title: "C", poster_path: null } },
      { n: 4, tmdb_id: 4, tmdb_json: null },
    ]);
    const body = await watched();
    expect([1, 2, 3, 4].map((n) => byUri(body, n)!.poster_path)).toEqual(["/a.jpg", null, null, null]);
  });

  it("an unmatched film is listed with no tmdb_id, poster, or pick", async () => {
    await seed([{ n: 1, name: "Obscure", year: 1972, half_stars: 4, watched: "2020-05-05" }]);
    expect((await watched()).films).toStrictEqual([
      {
        letterboxd_uri: uri(1),
        tmdb_id: null,
        title: "Obscure",
        year: 1972,
        half_stars: 4,
        logged_on: "2020-05-05",
        poster_path: null,
        is_horror: false,
        harbinger_pick: false,
        first_recommended_at: null,
      },
    ]);
  });

  it("a watched row without a logged date is listed, last", async () => {
    await seed([
      { n: 1, tmdb_id: 1, watched: null },
      { n: 2, tmdb_id: 2, watched: "2019-01-01" },
    ]);
    const { films } = await watched();
    expect(films.map((f) => [f.letterboxd_uri, f.logged_on])).toEqual([
      [uri(2), "2019-01-01"],
      [uri(1), null],
    ]);
  });

  it("handles ~1,000 watched films in one request", async () => {
    await seed(range(1000).map((i) => ({ n: i, tmdb_id: i + 1, half_stars: (i % 10) + 1 })));
    const { films } = await watched();
    expect(films).toHaveLength(1000);
    expect(new Set(films.map((f) => f.letterboxd_uri)).size).toBe(1000);
  });
});

describe("horror flag", () => {
  it("follows the effective rule: TMDB genre, with the override winning; always a boolean", async () => {
    await seed([
      { n: "horror", tmdb_id: 1, horror: true },
      { n: "not", tmdb_id: 2, horror: false },
      { n: "excluded", tmdb_id: 3, horror: true, override: "exclude" },
      { n: "included", tmdb_id: 4, horror: false, override: "include" },
      { n: "unmatched" },
      { n: "unmatched-included", override: "include" },
    ]);
    const body = await watched();
    const flag = (n: string) => byUri(body, n)!.is_horror;

    expect(flag("horror")).toBe(true);
    expect(flag("not")).toBe(false);
    expect(flag("excluded")).toBe(false);
    expect(flag("included")).toBe(true);
    expect(flag("unmatched")).toBe(false);
    expect(flag("unmatched-included")).toBe(true);
    for (const film of body.films) {
      expect(typeof film.is_horror).toBe("boolean");
      expect(typeof film.harbinger_pick).toBe("boolean");
    }
  });
});

describe("harbinger pick", () => {
  it("a film with a pick_log row is a pick with its first_recommended_at; others are not", async () => {
    await seed([
      { n: 1, tmdb_id: 11, half_stars: 9 },
      { n: 2, tmdb_id: 12 },
      { n: 3 },
    ]);
    await logPick(11, "2026-09-29T18:01:30.456Z");
    // A logged pick that was never watched doesn't add a row.
    await logPick(99, "2026-09-30T00:00:00.000Z");

    const body = await watched();
    expect(body.films).toHaveLength(3);
    expect(byUri(body, 1)).toMatchObject({ harbinger_pick: true, first_recommended_at: "2026-09-29T18:01:30.456Z" });
    expect(byUri(body, 2)).toMatchObject({ harbinger_pick: false, first_recommended_at: null });
    expect(byUri(body, 3)).toMatchObject({ harbinger_pick: false, first_recommended_at: null });
  });

  it("a pick whose conversation was deleted is still a pick", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    mockWorld([catalogFilm(201, "Noroi", 2005)], [claudeReply(recs(pick("Noroi", 2005)))]);
    const turn = await ok<{ conversation: { id: string } }>(await send("POST", "/conversations", { text: "slow dread" }));
    const logged = await env.DB.prepare("SELECT first_recommended_at FROM pick_log WHERE tmdb_id = 201").first<{
      first_recommended_at: string;
    }>();
    expect((await authed(`/conversations/${turn.conversation.id}`, { method: "DELETE" })).status).toBe(204);

    // Then watched, rated, and imported.
    await seed([{ n: 1, name: "Noroi: The Curse", year: 2005, tmdb_id: 201, horror: true, half_stars: 9 }]);

    expect(byUri(await watched(), 1)).toMatchObject({
      title: "Noroi: The Curse",
      harbinger_pick: true,
      first_recommended_at: logged!.first_recommended_at,
    });
  });
});

describe("order and import", () => {
  it("orders by logged_on desc, then title, then URI", async () => {
    await seed([
      { n: "c", name: "Alpha", tmdb_id: 1, watched: "2021-01-01" },
      { n: "a", name: "Zulu", tmdb_id: 2, watched: "2024-06-01" },
      { n: "e", name: "Beta", tmdb_id: 3, watched: "2024-06-01" },
      { n: "d", name: "Beta", tmdb_id: 4, watched: "2024-06-01" },
      { n: "b", name: "Alpha", tmdb_id: 5, watched: "2025-12-31" },
    ]);
    expect((await watched()).films.map((f) => f.letterboxd_uri)).toEqual([uri("b"), uri("d"), uri("e"), uri("a"), uri("c")]);
  });

  it("last_import_at is the latest import's imported_at", async () => {
    await addImport("2026-09-24T22:10:00.000Z");
    await addImport("2026-10-01T08:00:00.000Z");
    expect((await watched()).last_import_at).toBe("2026-10-01T08:00:00.000Z");
  });
});

describe("config", () => {
  it("works with ANTHROPIC_API_KEY and TMDB_READ_TOKEN unset, with no outbound request", async () => {
    await seed([{ n: 1, tmdb_id: 1 }]);
    const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new Error("fetch must not be called");
    });
    const request = new Request(`${BASE}/library/watched`, {
      headers: { Authorization: `Bearer ${env.API_KEY}` },
    }) as Parameters<typeof worker.fetch>[0];
    const res = await worker.fetch(request, { ...env, ANTHROPIC_API_KEY: "", TMDB_READ_TOKEN: "" } as Env);

    expect((await ok<WatchedBody>(res)).films).toHaveLength(1);
    expect(spy).not.toHaveBeenCalled();
  });
});
