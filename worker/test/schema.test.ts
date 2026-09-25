import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const db = env.DB;
let seq = 0;

async function insertFilm(fields: { is_horror?: number | null; genre_override?: string | null; match_status?: string } = {}) {
  const uri = `https://boxd.it/test${++seq}`;
  await db
    .prepare(
      `INSERT INTO films (letterboxd_uri, name, year, match_status, is_horror, genre_override, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      uri,
      `Film ${seq}`,
      2000,
      fields.match_status ?? "pending",
      fields.is_horror ?? null,
      fields.genre_override ?? null,
      "2026-09-25T00:00:00Z",
    )
    .run();
  return uri;
}

async function inHorrorView(uri: string): Promise<boolean> {
  const row = await db.prepare("SELECT 1 FROM horror_films WHERE letterboxd_uri = ?").bind(uri).first();
  return row !== null;
}

describe("migration 0001", () => {
  it("creates all six tables, both indexes, and the horror_films view", async () => {
    const { results } = await db
      .prepare(
        `SELECT type, name FROM sqlite_master
         WHERE type IN ('table','index','view')
           AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name != 'd1_migrations'
         ORDER BY type, name`,
      )
      .all<{ type: string; name: string }>();
    const byType = (t: string) => results.filter((r) => r.type === t).map((r) => r.name);

    expect(byType("table")).toEqual(["films", "imports", "likes", "ratings", "watched", "watchlist"]);
    expect(byType("index")).toEqual(["idx_films_match_status", "idx_films_tmdb_id"]);
    expect(byType("view")).toEqual(["horror_films"]);
  });
});

describe("constraints", () => {
  it("ratings.half_stars rejects 0 and 11, accepts 1 and 10", async () => {
    const rate = async (halfStars: number) =>
      db
        .prepare("INSERT INTO ratings (letterboxd_uri, half_stars) VALUES (?, ?)")
        .bind(await insertFilm(), halfStars)
        .run();

    await expect(rate(0)).rejects.toThrow(/CHECK constraint failed/);
    await expect(rate(11)).rejects.toThrow(/CHECK constraint failed/);
    await expect(rate(1)).resolves.toMatchObject({ success: true });
    await expect(rate(10)).resolves.toMatchObject({ success: true });
  });

  it("films.match_status rejects an unknown value", async () => {
    await expect(insertFilm({ match_status: "bogus" })).rejects.toThrow(/CHECK constraint failed/);
  });

  it("films.genre_override rejects an unknown value", async () => {
    await expect(insertFilm({ genre_override: "maybe" })).rejects.toThrow(/CHECK constraint failed/);
  });

  it("rejects a ratings row for a non-existent film (foreign keys enforced)", async () => {
    const insert = db
      .prepare("INSERT INTO ratings (letterboxd_uri, half_stars) VALUES (?, ?)")
      .bind("https://boxd.it/does-not-exist", 5)
      .run();
    await expect(insert).rejects.toThrow(/FOREIGN KEY constraint failed/);
  });
});

describe("horror_films view", () => {
  it.each([
    { is_horror: 1, genre_override: null, included: true },
    { is_horror: 0, genre_override: "include", included: true },
    { is_horror: 1, genre_override: "exclude", included: false },
    { is_horror: null, genre_override: null, included: false },
  ])("is_horror=$is_horror override=$genre_override → included=$included", async ({ included, ...fields }) => {
    const uri = await insertFilm(fields);
    expect(await inHorrorView(uri)).toBe(included);
  });
});
