import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { call, clearLibrary, expectError, film, ok, range, seedFilms, send, authed, uri } from "./helpers";

beforeEach(clearLibrary);

describe("auth on W2 routes", () => {
  it.each([
    ["GET", "/library/films"],
    ["POST", "/library/films"],
    ["POST", "/library/films/matches"],
    ["POST", "/library/import"],
    ["PUT", "/library/films/override"],
    ["GET", "/library/imports/latest"],
  ])("%s %s without a key → 401", async (method, path) => {
    await expectError(await call(path, { method, body: method === "GET" ? undefined : "{}" }), 401, "unauthorized");
  });
});

describe("GET /library/films", () => {
  it("returns an empty list on an empty DB", async () => {
    expect(await ok(await authed("/library/films"))).toEqual({ films: [] });
  });

  it("returns only the listed fields, ordered by letterboxd_uri", async () => {
    await seedFilms("b", "a");
    await env.DB.prepare("UPDATE films SET tmdb_json = '{}', matched_at = 'x' WHERE letterboxd_uri = ?").bind(uri("a")).run();

    const { films } = await ok<{ films: Record<string, unknown>[] }>(await authed("/library/films"));
    expect(films.map((f) => f.letterboxd_uri)).toEqual([uri("a"), uri("b")]);
    expect(films[0]).toEqual({
      letterboxd_uri: uri("a"),
      name: "Film a",
      year: 2000,
      tmdb_id: null,
      match_status: "pending",
      is_horror: null,
      genre_override: null,
    });
  });
});

describe("POST /library/films", () => {
  it("inserts new films as pending with created_at set", async () => {
    const before = new Date().toISOString();
    expect(await ok(await send("POST", "/library/films", { films: [film(1), film(2)] }))).toEqual({
      inserted: 2,
      updated: 0,
    });
    const rows = await env.DB.prepare("SELECT match_status, created_at FROM films").all<{ match_status: string; created_at: string }>();
    expect(rows.results).toHaveLength(2);
    for (const row of rows.results) {
      expect(row.match_status).toBe("pending");
      expect(row.created_at >= before).toBe(true);
      expect(new Date(row.created_at).toISOString()).toBe(row.created_at);
    }
  });

  it("re-posting identical films changes nothing", async () => {
    await seedFilms(1, 2);
    expect(await ok(await send("POST", "/library/films", { films: [film(1), film(2)] }))).toEqual({
      inserted: 0,
      updated: 0,
    });
  });

  it("updates changed name or year without touching matching columns", async () => {
    await seedFilms(1, 2, 3);
    await env.DB.prepare(
      "UPDATE films SET tmdb_id = 42, match_status = 'matched', is_horror = 1, genre_override = 'exclude' WHERE letterboxd_uri = ?",
    )
      .bind(uri(1))
      .run();

    expect(await ok(await send("POST", "/library/films", { films: [film(1, { name: "Renamed" }), film(2)] }))).toEqual({
      inserted: 0,
      updated: 1,
    });
    expect(await ok(await send("POST", "/library/films", { films: [film(3, { year: 2001 }), film(4)] }))).toEqual({
      inserted: 1,
      updated: 1,
    });

    const row = await env.DB.prepare("SELECT * FROM films WHERE letterboxd_uri = ?").bind(uri(1)).first();
    expect(row).toMatchObject({ name: "Renamed", tmdb_id: 42, match_status: "matched", is_horror: 1, genre_override: "exclude" });
    const three = await env.DB.prepare("SELECT year FROM films WHERE letterboxd_uri = ?").bind(uri(3)).first();
    expect(three).toEqual({ year: 2001 });
  });

  it("accepts 1,000 films in one request", async () => {
    const films = range(1000).map((i) => film(i));
    expect(await ok(await send("POST", "/library/films", { films }))).toEqual({ inserted: 1000, updated: 0 });
    const renamed = films.map((f, i) => (i % 2 ? { ...f, name: `${f.name} (renamed)` } : f));
    expect(await ok(await send("POST", "/library/films", { films: renamed }))).toEqual({ inserted: 0, updated: 500 });
  });

  it.each([
    ["missing films", {}],
    ["non-boxd.it URI", { films: [{ ...film(1), letterboxd_uri: "https://letterboxd.com/film/x/" }] }],
    ["empty name", { films: [{ ...film(1), name: "" }] }],
    ["non-integer year", { films: [{ ...film(1), year: 2000.5 }] }],
    ["duplicate URI", { films: [film(1), film(1)] }],
  ])("rejects %s → 400 invalid_request", async (_label, body) => {
    await expectError(await send("POST", "/library/films", body), 400, "invalid_request");
  });
});

describe("PUT /library/films/override", () => {
  const inView = async () =>
    (await env.DB.prepare("SELECT 1 FROM horror_films WHERE letterboxd_uri = ?").bind(uri(1)).first()) !== null;

  it("sets include, sets exclude, and clears with null", async () => {
    await seedFilms(1);
    await env.DB.prepare("UPDATE films SET is_horror = 0 WHERE letterboxd_uri = ?").bind(uri(1)).run();
    expect(await inView()).toBe(false);

    const include = await ok(await send("PUT", "/library/films/override", { letterboxd_uri: uri(1), genre_override: "include" }));
    expect(include).toEqual({
      letterboxd_uri: uri(1),
      name: "Film 1",
      year: 2000,
      tmdb_id: null,
      match_status: "pending",
      is_horror: 0,
      genre_override: "include",
    });
    expect(await inView()).toBe(true);

    await env.DB.prepare("UPDATE films SET is_horror = 1 WHERE letterboxd_uri = ?").bind(uri(1)).run();
    const exclude = await ok(await send("PUT", "/library/films/override", { letterboxd_uri: uri(1), genre_override: "exclude" }));
    expect(exclude.genre_override).toBe("exclude");
    expect(await inView()).toBe(false);

    const cleared = await ok(await send("PUT", "/library/films/override", { letterboxd_uri: uri(1), genre_override: null }));
    expect(cleared.genre_override).toBeNull();
    expect(await inView()).toBe(true);
  });

  it("rejects an invalid value → 400", async () => {
    await seedFilms(1);
    await expectError(
      await send("PUT", "/library/films/override", { letterboxd_uri: uri(1), genre_override: "maybe" }),
      400,
      "invalid_request",
    );
    await expectError(await send("PUT", "/library/films/override", { letterboxd_uri: uri(1) }), 400, "invalid_request");
  });

  it("returns 404 for an unknown URI", async () => {
    await expectError(
      await send("PUT", "/library/films/override", { letterboxd_uri: uri("nope"), genre_override: "include" }),
      404,
      "not_found",
    );
  });
});
