import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { clearLibrary, expectError, ok, range, seedFilms, send, uri } from "./helpers";

beforeEach(clearLibrary);

const tmdbJson = { title: "The Film", poster_path: "/p.jpg", runtime: 93, genres: [27, 53], overview: "Something bad." };

const matched = (n: number | string, overrides: Record<string, unknown> = {}) => ({
  letterboxd_uri: uri(n),
  match_status: "matched",
  tmdb_id: 1000 + Number(String(n).replace(/\D/g, "") || 0),
  is_horror: 1,
  tmdb_json: tmdbJson,
  ...overrides,
});

const row = (n: number | string) =>
  env.DB.prepare("SELECT * FROM films WHERE letterboxd_uri = ?").bind(uri(n)).first<Record<string, unknown>>();

describe("POST /library/films/matches", () => {
  it("matched sets tmdb_id, is_horror, tmdb_json, matched_at", async () => {
    await seedFilms(1);
    expect(await ok(await send("POST", "/library/films/matches", { matches: [matched(1)] }))).toEqual({ updated: 1 });
    const film = await row(1);
    expect(film).toMatchObject({ match_status: "matched", tmdb_id: 1001, is_horror: 1, tmdb_json: JSON.stringify(tmdbJson) });
    expect(typeof film?.matched_at).toBe("string");
    expect(new Date(film?.matched_at as string).toISOString()).toBe(film?.matched_at);
  });

  it("unmatched on a previously matched film clears the match columns, keeps genre_override", async () => {
    await seedFilms(1);
    await ok(await send("POST", "/library/films/matches", { matches: [matched(1)] }));
    await env.DB.prepare("UPDATE films SET genre_override = 'include' WHERE letterboxd_uri = ?").bind(uri(1)).run();

    expect(
      await ok(await send("POST", "/library/films/matches", { matches: [{ letterboxd_uri: uri(1), match_status: "unmatched" }] })),
    ).toEqual({ updated: 1 });
    expect(await row(1)).toMatchObject({
      match_status: "unmatched",
      tmdb_id: null,
      is_horror: null,
      tmdb_json: null,
      matched_at: null,
      genre_override: "include",
    });
  });

  it.each([
    ["matched missing tmdb_id", { letterboxd_uri: uri(1), match_status: "matched", is_horror: 1, tmdb_json: tmdbJson }],
    ["matched missing tmdb_json", { letterboxd_uri: uri(1), match_status: "matched", tmdb_id: 5, is_horror: 1 }],
    ["matched with is_horror 2", matched(1, { is_horror: 2 })],
    ["matched with tmdb_id 0", matched(1, { tmdb_id: 0 })],
    ["matched with array tmdb_json", matched(1, { tmdb_json: [] })],
    ["ambiguous with tmdb_id", { letterboxd_uri: uri(1), match_status: "ambiguous", tmdb_id: 5 }],
    ["pending", { letterboxd_uri: uri(1), match_status: "pending" }],
    ["duplicate URI", [matched(1), matched(1)]],
  ])("rejects %s → 400", async (_label, entry) => {
    await seedFilms(1);
    const matches = Array.isArray(entry) ? entry : [entry];
    await expectError(await send("POST", "/library/films/matches", { matches }), 400, "invalid_request");
    expect(await row(1)).toMatchObject({ match_status: "pending", tmdb_id: null });
  });

  it("unknown URI → 422 unknown_films and no rows changed", async () => {
    await seedFilms(1);
    const message = await expectError(
      await send("POST", "/library/films/matches", { matches: [matched(1), matched("nope")] }),
      422,
      "unknown_films",
    );
    expect(message).toContain(uri("nope"));
    expect(await row(1)).toMatchObject({ match_status: "pending", tmdb_id: null, matched_at: null });
  });

  it("accepts 1,000 matches in one request", async () => {
    const ids = range(1000);
    await seedFilms(...ids);
    const matches = ids.map((i) =>
      i % 3 === 0 ? { letterboxd_uri: uri(i), match_status: "ambiguous" } : matched(i, { is_horror: i % 2 }),
    );
    expect(await ok(await send("POST", "/library/films/matches", { matches }))).toEqual({ updated: 1000 });
    const counts = await env.DB.prepare(
      "SELECT match_status, COUNT(*) AS c FROM films GROUP BY match_status ORDER BY match_status",
    ).all();
    expect(counts.results).toEqual([
      { match_status: "ambiguous", c: 334 },
      { match_status: "matched", c: 666 },
    ]);
  });
});
