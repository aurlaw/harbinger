import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { toApiRecommendation } from "../src/conversations/store";
import { toEnrichedDetails } from "../src/tmdb/enrich";
import { claudeReply, clearAll, film, mockWorld, pick, recs } from "./conversations-helpers";
import { ok, send } from "./helpers";

const base = {
  id: 1,
  title: "The Witch",
  original_title: "The Witch",
  release_date: "2015-01-27",
  genres: [{ id: 27, name: "Horror" }],
  runtime: 92,
  overview: "New England, 1630.",
  poster_path: "/w.jpg",
};

const crew = (...entries: [string, string][]) => ({ cast: [], crew: entries.map(([name, job]) => ({ name, job })) });
const video = (key: string, type: string, official: boolean, published_at: string, site = "YouTube") => ({
  key,
  type,
  official,
  published_at,
  site,
});
const provider = (provider_name: string, logo_path = `/${provider_name}.png`) => ({ provider_name, logo_path });

describe("toEnrichedDetails", () => {
  it("keeps the W3 details fields and adds enrichment", () => {
    const details = toEnrichedDetails({ ...base, budget: 1 });
    expect(details).toStrictEqual({
      tmdb_id: 1,
      title: "The Witch",
      original_title: "The Witch",
      release_date: "2015-01-27",
      genres: [{ id: 27, name: "Horror" }],
      is_horror: true,
      runtime: 92,
      overview: "New England, 1630.",
      poster_path: "/w.jpg",
      director: null,
      providers: [],
      providers_link: null,
      trailer_key: null,
    });
  });

  it("joins multiple directors in order, de-duplicated; null when none", () => {
    const credits = crew(["A", "Director"], ["X", "Writer"], ["B", "Director"], ["A", "Director"]);
    expect(toEnrichedDetails({ ...base, credits }).director).toBe("A, B");
    expect(toEnrichedDetails({ ...base, credits: crew(["X", "Producer"]) }).director).toBeNull();
    expect(toEnrichedDetails({ ...base, credits: "garbage" }).director).toBeNull();
  });

  it("orders US providers by type, de-duplicates by name keeping the best type, includes logo_path", () => {
    const details = toEnrichedDetails({
      ...base,
      "watch/providers": {
        results: {
          GB: { link: "gb", flatrate: [provider("BBC")] },
          US: {
            link: "https://www.themoviedb.org/movie/1/watch?locale=US",
            buy: [provider("Apple TV"), provider("Amazon Video")],
            rent: [provider("Apple TV"), provider("Vudu")],
            flatrate: [provider("Shudder"), provider("AMC+", null as unknown as string)],
            ads: [provider("Tubi")],
          },
        },
      },
    });
    expect(details.providers).toStrictEqual([
      { name: "Shudder", type: "flatrate", logo_path: "/Shudder.png" },
      { name: "AMC+", type: "flatrate", logo_path: null },
      { name: "Tubi", type: "ads", logo_path: "/Tubi.png" },
      { name: "Apple TV", type: "rent", logo_path: "/Apple TV.png" },
      { name: "Vudu", type: "rent", logo_path: "/Vudu.png" },
      { name: "Amazon Video", type: "buy", logo_path: "/Amazon Video.png" },
    ]);
    expect(details.providers_link).toBe("https://www.themoviedb.org/movie/1/watch?locale=US");
  });

  it("maps no US key, no watch/providers key, or malformed data to [] / null", () => {
    for (const extra of [
      { "watch/providers": { results: { GB: { flatrate: [provider("BBC")] } } } },
      {},
      { "watch/providers": null },
      { "watch/providers": { results: { US: { flatrate: "nope" } } } },
    ]) {
      const details = toEnrichedDetails({ ...base, ...extra });
      expect(details.providers).toEqual([]);
      expect(details.providers_link).toBeNull();
    }
  });

  it("prefers official Trailer > Trailer > Teaser, latest within a tier, YouTube only", () => {
    const pickKey = (...results: unknown[]) => toEnrichedDetails({ ...base, videos: { results } }).trailer_key;
    const officialOld = video("official-old", "Trailer", true, "2015-01-01T00:00:00.000Z");
    const officialNew = video("official-new", "Trailer", true, "2016-01-01T00:00:00.000Z");
    const unofficial = video("unofficial", "Trailer", false, "2020-01-01T00:00:00.000Z");
    const teaser = video("teaser", "Teaser", true, "2021-01-01T00:00:00.000Z");
    const vimeo = video("vimeo", "Trailer", true, "2022-01-01T00:00:00.000Z", "Vimeo");
    const clip = video("clip", "Clip", true, "2022-01-01T00:00:00.000Z");

    expect(pickKey(teaser, unofficial, officialOld, officialNew, vimeo)).toBe("official-new");
    expect(pickKey(teaser, unofficial, vimeo)).toBe("unofficial");
    expect(pickKey(teaser, vimeo, clip)).toBe("teaser");
    expect(pickKey(vimeo, clip)).toBeNull();
    expect(toEnrichedDetails(base).trailer_key).toBeNull();
  });
});

describe("enriched resolution", () => {
  beforeEach(async () => {
    await clearAll();
    vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => vi.restoreAllMocks());

  it("makes one details call with append_to_response and returns the enrichment", async () => {
    const catalog = [
      film(301, "Noroi", 2005, {
        appended: {
          credits: crew(["Koji Shiraishi", "Director"]),
          videos: { results: [video("abc123", "Trailer", true, "2006-01-01T00:00:00.000Z")] },
          "watch/providers": { results: { US: { link: "https://tmdb/301", flatrate: [provider("Shudder")] } } },
        },
      }),
    ];
    const world = mockWorld(catalog, [claudeReply(recs(pick("Noroi", 2005)))]);
    const body = await ok<{ messages: { recommendations?: unknown[] }[] }>(
      await send("POST", "/conversations", { text: "hi" }),
    );

    const details = world.tmdbCalls.filter((u) => u.pathname === "/3/movie/301");
    expect(details).toHaveLength(1);
    expect(details[0]!.searchParams.get("append_to_response")).toBe("credits,videos,watch/providers");
    expect(body.messages[1]!.recommendations![0]).toMatchObject({
      director: "Koji Shiraishi",
      providers: [{ name: "Shudder", type: "flatrate", logo_path: "/Shudder.png" }],
      providers_link: "https://tmdb/301",
      trailer_key: "abc123",
    });
  });

  it("resolves even when TMDB omits every appended section", async () => {
    mockWorld([film(302, "Lake Mungo", 2008, { appended: {} })], [claudeReply(recs(pick("Lake Mungo", 2008)))]);
    const body = await ok<{ messages: { recommendations?: unknown[] }[] }>(
      await send("POST", "/conversations", { text: "hi" }),
    );
    expect(body.messages[1]!.recommendations![0]).toMatchObject({
      director: null,
      providers: [],
      providers_link: null,
      trailer_key: null,
    });
  });

  it("renders a W4a-era row (no enrichment in tmdb_json) with null / [] / null", () => {
    const w4aDetails = { ...toEnrichedDetails(base) } as Record<string, unknown>;
    for (const key of ["director", "providers", "providers_link", "trailer_key"]) delete w4aDetails[key];
    const rec = toApiRecommendation({
      id: "r",
      conversation_id: "c",
      message_id: "m",
      position: 1,
      tmdb_id: 1,
      title: "The Witch",
      year: 2015,
      why_short: "s",
      why_full: "f",
      tmdb_json: JSON.stringify(w4aDetails),
      created_at: "2026-09-26T00:00:00.000Z",
    });
    expect(rec).toMatchObject({
      poster_path: "/w.jpg",
      runtime: 92,
      director: null,
      providers: [],
      providers_link: null,
      trailer_key: null,
    });
  });
});
