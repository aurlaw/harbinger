import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { replaceSnapshots, type ImportInput } from "../src/library/imports";
import { authed, clearLibrary, count, expectError, ok, range, seedFilms, send, tick, uri } from "./helpers";

beforeEach(clearLibrary);

const rating = (n: number | string, half_stars = 8) => ({ letterboxd_uri: uri(n), half_stars, rated_on: "2021-03-11" });
const watched = (n: number | string) => ({ letterboxd_uri: uri(n), logged_on: "2021-03-11" });
const listed = (n: number | string) => ({ letterboxd_uri: uri(n), added_on: "2025-06-02" });
const liked = (n: number | string) => ({ letterboxd_uri: uri(n) });

function payload(overrides: Partial<ImportInput> = {}): ImportInput {
  return {
    source_filename: "letterboxd-export.zip",
    force: false,
    ratings: [rating(1), rating(2, 5)],
    watched: [watched(1), watched(2)],
    watchlist: [listed(3)],
    likes: [liked(1)],
    ...overrides,
  };
}

const importNow = (body: unknown) => send("POST", "/library/import", body);

async function snapshot() {
  const all = async (sql: string) => (await env.DB.prepare(sql).all()).results;
  return {
    ratings: await all("SELECT * FROM ratings ORDER BY letterboxd_uri"),
    watched: await all("SELECT * FROM watched ORDER BY letterboxd_uri"),
    watchlist: await all("SELECT * FROM watchlist ORDER BY letterboxd_uri"),
    likes: await all("SELECT * FROM likes ORDER BY letterboxd_uri"),
    imports: await all("SELECT * FROM imports ORDER BY id"),
  };
}

describe("POST /library/import", () => {
  it("first import populates all four tables and an imports row", async () => {
    await seedFilms(1, 2, 3);
    const res = await ok(await importNow(payload()));
    expect(res).toEqual({ import_id: expect.any(Number), ratings: 2, watched: 2, watchlist: 1, likes: 1, new_films: 3 });

    const snap = await snapshot();
    expect(snap.ratings).toEqual([
      { letterboxd_uri: uri(1), half_stars: 8, rated_on: "2021-03-11" },
      { letterboxd_uri: uri(2), half_stars: 5, rated_on: "2021-03-11" },
    ]);
    expect(snap.watched).toHaveLength(2);
    expect(snap.watchlist).toEqual([{ letterboxd_uri: uri(3), added_on: "2025-06-02" }]);
    expect(snap.likes).toEqual([{ letterboxd_uri: uri(1) }]);
    expect(snap.imports).toEqual([
      {
        id: res.import_id,
        imported_at: expect.any(String),
        source_filename: "letterboxd-export.zip",
        ratings_count: 2,
        watched_count: 2,
        watchlist_count: 1,
        likes_count: 1,
        new_films_count: 3,
      },
    ]);
  });

  it("a second import fully replaces each table", async () => {
    await seedFilms(1, 2, 3, 4);
    await ok(await importNow(payload()));
    await ok(
      await importNow(
        payload({
          ratings: [rating(1, 10), rating(3, 2)],
          watched: [watched(1), watched(3)],
          watchlist: [listed(4)],
          likes: [liked(3)],
        }),
      ),
    );
    const snap = await snapshot();
    expect(snap.ratings).toEqual([
      { letterboxd_uri: uri(1), half_stars: 10, rated_on: "2021-03-11" },
      { letterboxd_uri: uri(3), half_stars: 2, rated_on: "2021-03-11" },
    ]);
    expect(snap.watched.map((r) => r.letterboxd_uri)).toEqual([uri(1), uri(3)]);
    expect(snap.watchlist.map((r) => r.letterboxd_uri)).toEqual([uri(4)]);
    expect(snap.likes.map((r) => r.letterboxd_uri)).toEqual([uri(3)]);
    expect(snap.imports).toHaveLength(2);
  });

  it("accepts 1,000 ratings + 1,000 watched in one request", async () => {
    const ids = range(1000);
    await seedFilms(...ids);
    const res = await ok(
      await importNow(
        payload({
          ratings: ids.map((i) => rating(i, (i % 10) + 1)),
          watched: ids.map((i) => watched(i)),
          watchlist: [],
          likes: [],
        }),
      ),
    );
    expect(res).toMatchObject({ ratings: 1000, watched: 1000, watchlist: 0, likes: 0, new_films: 1000 });
    expect(await count("ratings")).toBe(1000);
  });

  it.each([
    ["half_stars 0", { ratings: [rating(1, 0)] }],
    ["half_stars 11", { ratings: [rating(1, 11)] }],
    ["duplicate URI in ratings", { ratings: [rating(1), rating(1, 4)] }],
    ["malformed date", { ratings: [{ ...rating(1), rated_on: "03/11/2021" }] }],
    ["impossible date", { watched: [{ ...watched(1), logged_on: "2021-02-30" }] }],
    ["missing likes array", { likes: undefined }],
    ["non-boolean force", { force: "yes" }],
    ["empty source_filename", { source_filename: "" }],
  ])("rejects %s → 400 and writes nothing", async (_label, overrides) => {
    await seedFilms(1, 2, 3);
    await ok(await importNow(payload()));
    const before = await snapshot();
    await expectError(await importNow({ ...payload(), ...overrides }), 400, "invalid_request");
    expect(await snapshot()).toEqual(before);
  });

  it("unknown URI → 422; previous snapshot intact", async () => {
    await seedFilms(1, 2, 3);
    await ok(await importNow(payload()));
    const before = await snapshot();
    const message = await expectError(
      await importNow(payload({ likes: [liked(1), liked("ghost")] })),
      422,
      "unknown_films",
    );
    expect(message).toContain(uri("ghost"));
    expect(await snapshot()).toEqual(before);
  });

  describe("empty-file guard", () => {
    it("existing ratings + empty ratings + force false → 409 naming ratings; snapshot intact", async () => {
      await seedFilms(1, 2, 3);
      await ok(await importNow(payload()));
      const before = await snapshot();
      const message = await expectError(await importNow(payload({ ratings: [] })), 409, "empty_snapshot");
      expect(message).toContain("ratings");
      expect(message).not.toMatch(/watched|watchlist|likes/);
      expect(await snapshot()).toEqual(before);
    });

    it("names every offending table", async () => {
      await seedFilms(1, 2, 3);
      await ok(await importNow(payload()));
      const message = await expectError(
        await importNow(payload({ ratings: [], watchlist: [], likes: [] })),
        409,
        "empty_snapshot",
      );
      for (const table of ["ratings", "watchlist", "likes"]) expect(message).toContain(table);
      expect(message).not.toContain("watched");
    });

    it("force: true empties the table", async () => {
      await seedFilms(1, 2, 3);
      await ok(await importNow(payload()));
      const res = await ok(await importNow(payload({ ratings: [], force: true })));
      expect(res.ratings).toBe(0);
      expect(await count("ratings")).toBe(0);
      expect(await count("watched")).toBe(2);
    });

    it("does not trip when the table is already empty", async () => {
      await seedFilms(1, 2, 3);
      await ok(await importNow(payload({ likes: [] })));
      await ok(await importNow(payload({ likes: [] })));
      expect(await count("imports")).toBe(2);
    });
  });

  it("new_films_count: all films on first import, only newer films later", async () => {
    await seedFilms(1, 2, 3);
    await tick();
    expect((await ok(await importNow(payload()))).new_films).toBe(3);

    await tick();
    await seedFilms(1, 2, 3, 4, 5); // 4 and 5 are new; 1–3 already known
    await tick();
    expect((await ok(await importNow(payload()))).new_films).toBe(2);

    await tick();
    expect((await ok(await importNow(payload()))).new_films).toBe(0);
  });

  it("atomicity: a failure mid-batch leaves every table unchanged", async () => {
    await seedFilms(1, 2, 3);
    await ok(await importNow(payload()));
    const before = await snapshot();

    // Bypass request validation so the last snapshot insert hits the likes foreign key,
    // after the deletes and the other three inserts have already run in the batch.
    const bad = payload({ ratings: [rating(3, 1)], watched: [watched(3)], watchlist: [], likes: [liked("ghost")] });
    await expect(replaceSnapshots(env.DB, bad, new Date().toISOString())).rejects.toThrow(/FOREIGN KEY/);

    expect(await snapshot()).toEqual(before);
  });
});

describe("GET /library/imports/latest", () => {
  it("returns 404 no_imports when there are none", async () => {
    await expectError(await authed("/library/imports/latest"), 404, "no_imports");
  });

  it("returns the second of two imports with all columns", async () => {
    await seedFilms(1, 2, 3);
    await ok(await importNow(payload({ source_filename: "first.zip" })));
    const second = await ok(await importNow(payload({ source_filename: "second.zip", likes: [liked(1), liked(2)] })));
    expect(await ok(await authed("/library/imports/latest"))).toEqual({
      id: second.import_id,
      imported_at: expect.any(String),
      source_filename: "second.zip",
      ratings_count: 2,
      watched_count: 2,
      watchlist_count: 1,
      likes_count: 2,
      new_films_count: 0,
    });
  });
});
