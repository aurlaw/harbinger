import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { BASE, authed, call, expectError, ok } from "./helpers";

const TMDB = "https://api.themoviedb.org/3";

type Reply = (url: URL, headers: Headers) => Response | Promise<Response>;

/**
 * Mocks outbound fetch. Only `${TMDB}${path}` is allowed; any other URL throws
 * so the test fails loudly if the Worker calls something it shouldn't.
 */
function mockTmdb(path: string, reply: Reply) {
  const unexpected: string[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (`${url.origin}${url.pathname}` !== `${TMDB}${path}`) {
      unexpected.push(url.href);
      throw new Error(`unexpected fetch: ${url.href}`);
    }
    return reply(url, new Headers(init?.headers));
  });
  return { spy, unexpected };
}

/** A fetch spy that fails any call. */
function forbidFetch() {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
    throw new Error("fetch must not be called");
  });
}

const tmdbJson = (body: unknown, init: ResponseInit = {}) =>
  new Response(JSON.stringify(body), { ...init, headers: { "Content-Type": "application/json", ...init.headers } });

afterEach(() => {
  vi.restoreAllMocks();
});

const rawSearchMovie = {
  adult: false,
  backdrop_path: "/back.jpg",
  genre_ids: [27, 9648],
  id: 310131,
  original_language: "en",
  original_title: "The Witch",
  overview: "New England, 1630.",
  popularity: 45.2,
  poster_path: "/witch.jpg",
  release_date: "2015-01-27",
  title: "The VVitch",
  video: false,
  vote_average: 7.1,
  vote_count: 6000,
};

const searchResponse = (results: unknown[] = [rawSearchMovie]) => ({
  page: 1,
  results,
  total_pages: 1,
  total_results: results.length,
});

const rawMovie = {
  adult: false,
  backdrop_path: "/back.jpg",
  belongs_to_collection: null,
  budget: 4000000,
  genres: [
    { id: 27, name: "Horror" },
    { id: 9648, name: "Mystery" },
  ],
  homepage: "",
  id: 310131,
  imdb_id: "tt4263482",
  original_language: "en",
  original_title: "The Witch",
  overview: "New England, 1630.",
  popularity: 45.2,
  poster_path: "/witch.jpg",
  release_date: "2015-01-27",
  revenue: 40000000,
  runtime: 92,
  status: "Released",
  tagline: "Evil takes many forms.",
  title: "The VVitch",
  video: false,
  vote_average: 7.1,
  vote_count: 6000,
};

function callWithEnv(overrides: Partial<Env>, path: string) {
  const request = new Request(`${BASE}${path}`, {
    headers: { Authorization: `Bearer ${env.API_KEY}` },
  }) as Parameters<typeof worker.fetch>[0];
  return worker.fetch(request, { ...env, ...overrides });
}

describe("TMDB auth + routing", () => {
  it("rejects unauthenticated requests without calling TMDB", async () => {
    const spy = forbidFetch();
    await expectError(await call("/tmdb/search?query=x"), 401, "unauthorized");
    await expectError(await call("/tmdb/movie/1"), 401, "unauthorized");
    expect(spy).not.toHaveBeenCalled();
  });

  it("returns 405 with Allow: GET for POST /tmdb/movie/1", async () => {
    const spy = forbidFetch();
    const res = await authed("/tmdb/movie/1", { method: "POST" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
    expect(spy).not.toHaveBeenCalled();
  });

  it("returns 405 with Allow: GET for POST /tmdb/search", async () => {
    const res = await authed("/tmdb/search?query=x", { method: "POST" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
  });

  it("returns 404 for paths that don't match the parameterized route", async () => {
    const spy = forbidFetch();
    for (const path of ["/tmdb/movie/1/extra", "/tmdb/movie/", "/tmdb/movie", "/tmdb"]) {
      await expectError(await authed(path), 404, "not_found");
    }
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("TMDB_READ_TOKEN", () => {
  it("fails closed with 500 on TMDB routes when unset or empty, without calling fetch", async () => {
    const spy = forbidFetch();
    for (const TMDB_READ_TOKEN of [undefined, ""]) {
      const overrides = { TMDB_READ_TOKEN } as Partial<Env>;
      await expectError(await callWithEnv(overrides, "/tmdb/search?query=x"), 500, "internal_error");
      await expectError(await callWithEnv(overrides, "/tmdb/movie/1"), 500, "internal_error");
      const health = await callWithEnv(overrides, "/health");
      expect(health.status).toBe(200);
    }
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("GET /tmdb/search", () => {
  it("sends auth, language, include_adult and the mapped params", async () => {
    const { spy } = mockTmdb("/search/movie", () => tmdbJson(searchResponse()));
    await ok(await authed("/tmdb/search?query=The%20Witch&primary_release_year=2015&year=2015&page=2&extra=ignored"));

    expect(spy).toHaveBeenCalledTimes(1);
    const [input, init] = spy.mock.calls[0]!;
    const url = new URL(String(input instanceof Request ? input.url : input));
    const headers = new Headers(init?.headers);
    expect(headers.get("Authorization")).toBe("Bearer test-tmdb-token");
    expect(headers.get("Accept")).toBe("application/json");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      language: "en-US",
      include_adult: "false",
      query: "The Witch",
      primary_release_year: "2015",
      year: "2015",
      page: "2",
    });
  });

  it("sends only the params that were supplied", async () => {
    let sent: URLSearchParams | undefined;
    mockTmdb("/search/movie", (url) => {
      sent = url.searchParams;
      return tmdbJson(searchResponse());
    });
    await ok(await authed("/tmdb/search?query=Hereditary"));
    expect([...sent!.keys()].sort()).toEqual(["include_adult", "language", "query"]);
  });

  it("encodes spaces, &, ? and non-ASCII in query correctly", async () => {
    for (const title of ["Mission: Impossible – Fallout", "Rock & Rule?", "Låt den rätte komma in", "a+b=c #1"]) {
      let sent: URLSearchParams | undefined;
      mockTmdb("/search/movie", (url) => {
        sent = url.searchParams;
        return tmdbJson(searchResponse());
      });
      await ok(await authed(`/tmdb/search?${new URLSearchParams({ query: title })}`));
      expect(sent!.get("query")).toBe(title);
      expect(sent!.getAll("query")).toHaveLength(1);
      expect([...sent!.keys()].sort()).toEqual(["include_adult", "language", "query"]);
      vi.restoreAllMocks();
    }
  });

  it("returns only the listed fields and drops the rest", async () => {
    mockTmdb("/search/movie", () => tmdbJson(searchResponse()));
    const body = await ok(await authed("/tmdb/search?query=The%20Witch"));
    expect(body).toStrictEqual({
      page: 1,
      total_pages: 1,
      total_results: 1,
      results: [
        {
          tmdb_id: 310131,
          title: "The VVitch",
          original_title: "The Witch",
          release_date: "2015-01-27",
          genre_ids: [27, 9648],
          overview: "New England, 1630.",
          popularity: 45.2,
          poster_path: "/witch.jpg",
        },
      ],
    });
  });

  it('maps release_date "" to null and a missing poster_path to null', async () => {
    const { poster_path: _, ...noPoster } = rawSearchMovie;
    mockTmdb("/search/movie", () => tmdbJson(searchResponse([{ ...noPoster, release_date: "" }])));
    const body = await ok<{ results: Record<string, unknown>[] }>(await authed("/tmdb/search?query=x"));
    expect(body.results[0]!.release_date).toBeNull();
    expect(body.results[0]!.poster_path).toBeNull();
  });

  it("rejects a missing, blank or too-long query", async () => {
    const spy = forbidFetch();
    for (const qs of ["", "?query=", "?query=%20%20", `?query=${"a".repeat(201)}`]) {
      await expectError(await authed(`/tmdb/search${qs}`), 400, "invalid_request");
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("accepts a 200-character query", async () => {
    mockTmdb("/search/movie", () => tmdbJson(searchResponse([])));
    await ok(await authed(`/tmdb/search?query=${"a".repeat(200)}`));
  });

  it("rejects out-of-range or non-integer year and page params", async () => {
    const spy = forbidFetch();
    for (const qs of [
      "primary_release_year=abc",
      "primary_release_year=1869",
      "year=1500",
      "year=2101",
      "year=2015.5",
      "year=",
      "page=0",
      "page=11",
      "page=-1",
      "page=1e1",
    ]) {
      await expectError(await authed(`/tmdb/search?query=x&${qs}`), 400, "invalid_request");
    }
    expect(spy).not.toHaveBeenCalled();
  });
});

describe("GET /tmdb/movie/{id}", () => {
  it("calls TMDB /movie/{id} and returns only the listed fields", async () => {
    const { spy } = mockTmdb("/movie/310131", () => tmdbJson(rawMovie));
    const body = await ok(await authed("/tmdb/movie/310131"));
    expect(body).toStrictEqual({
      tmdb_id: 310131,
      title: "The VVitch",
      original_title: "The Witch",
      release_date: "2015-01-27",
      genres: [
        { id: 27, name: "Horror" },
        { id: 9648, name: "Mystery" },
      ],
      is_horror: true,
      runtime: 92,
      overview: "New England, 1630.",
      poster_path: "/witch.jpg",
    });

    const [input, init] = spy.mock.calls[0]!;
    const url = new URL(String(input instanceof Request ? input.url : input));
    expect(Object.fromEntries(url.searchParams)).toEqual({ language: "en-US" });
    expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer test-tmdb-token");
  });

  it("sets is_horror from genre 27 only", async () => {
    const cases: [unknown[], boolean][] = [
      [[{ id: 27, name: "Horror" }], true],
      [[{ id: 53, name: "Thriller" }, { id: 9648, name: "Mystery" }], false],
      [[], false],
    ];
    for (const [genres, expected] of cases) {
      mockTmdb("/movie/1", () => tmdbJson({ ...rawMovie, id: 1, genres }));
      const body = await ok(await authed("/tmdb/movie/1"));
      expect(body.is_horror).toBe(expected);
      vi.restoreAllMocks();
    }
  });

  it('maps runtime 0/missing, release_date "" and missing poster_path to null', async () => {
    const { runtime: _r, poster_path: _p, ...rest } = rawMovie;
    for (const raw of [{ ...rawMovie, runtime: 0, release_date: "", poster_path: null }, { ...rest, release_date: "" }]) {
      mockTmdb("/movie/310131", () => tmdbJson(raw));
      const body = await ok(await authed("/tmdb/movie/310131"));
      expect(body.runtime).toBeNull();
      expect(body.release_date).toBeNull();
      expect(body.poster_path).toBeNull();
      vi.restoreAllMocks();
    }
  });

  it("rejects ids that aren't a positive integer of at most 10 digits", async () => {
    const spy = forbidFetch();
    for (const id of ["abc", "0", "0123", "12345678901", "-1", "1.5", "%31"]) {
      await expectError(await authed(`/tmdb/movie/${id}`), 400, "invalid_request");
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("accepts a 10-digit id", async () => {
    mockTmdb("/movie/1234567890", () => tmdbJson({ ...rawMovie, id: 1234567890 }));
    const body = await ok(await authed("/tmdb/movie/1234567890"));
    expect(body.tmdb_id).toBe(1234567890);
  });
});

describe("TMDB error mapping", () => {
  const secretBody = JSON.stringify({ status_message: "SECRET_TMDB_DETAIL", success: false });

  async function expectNoLeak(res: Response) {
    const text = await res.clone().text();
    expect(text).not.toContain("SECRET_TMDB_DETAIL");
    expect(text).not.toContain("test-tmdb-token");
  }

  it("maps a TMDB 404 on details to 404 not_found", async () => {
    mockTmdb("/movie/999", () => new Response(secretBody, { status: 404 }));
    const res = await authed("/tmdb/movie/999");
    await expectNoLeak(res);
    await expectError(res, 404, "not_found");
  });

  it("maps TMDB 401 and 403 to 502 tmdb_unavailable without forwarding the body", async () => {
    for (const status of [401, 403]) {
      mockTmdb("/search/movie", () => new Response(secretBody, { status }));
      const res = await authed("/tmdb/search?query=x");
      await expectNoLeak(res);
      await expectError(res, 502, "tmdb_unavailable");
      vi.restoreAllMocks();
    }
  });

  it("maps TMDB 429 to 503 tmdb_rate_limited, passing Retry-After through", async () => {
    mockTmdb("/movie/1", () => new Response(secretBody, { status: 429, headers: { "Retry-After": "5" } }));
    const res = await authed("/tmdb/movie/1");
    await expectNoLeak(res);
    expect(res.headers.get("Retry-After")).toBe("5");
    await expectError(res, 503, "tmdb_rate_limited");
  });

  it("omits Retry-After on 429 when TMDB didn't send one", async () => {
    mockTmdb("/movie/1", () => new Response(secretBody, { status: 429 }));
    const res = await authed("/tmdb/movie/1");
    expect(res.headers.has("Retry-After")).toBe(false);
    await expectError(res, 503, "tmdb_rate_limited");
  });

  it("maps TMDB 5xx to 502", async () => {
    for (const status of [500, 503]) {
      mockTmdb("/search/movie", () => new Response(secretBody, { status }));
      const res = await authed("/tmdb/search?query=x");
      await expectNoLeak(res);
      await expectError(res, 502, "tmdb_unavailable");
      vi.restoreAllMocks();
    }
  });

  it("maps a network error to 502", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("SECRET_TMDB_DETAIL network down"));
    const res = await authed("/tmdb/movie/1");
    await expectNoLeak(res);
    await expectError(res, 502, "tmdb_unavailable");
  });

  it("maps a timeout to 502", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new DOMException("timed out", "TimeoutError"));
    await expectError(await authed("/tmdb/search?query=x"), 502, "tmdb_unavailable");
  });

  it("maps a non-JSON 200 body to 502", async () => {
    mockTmdb("/movie/1", () => new Response("<html>SECRET_TMDB_DETAIL</html>", { status: 200 }));
    const res = await authed("/tmdb/movie/1");
    await expectNoLeak(res);
    await expectError(res, 502, "tmdb_unavailable");
  });

  it("maps a non-object JSON 200 body to 502", async () => {
    mockTmdb("/search/movie", () => tmdbJson([1, 2, 3]));
    await expectError(await authed("/tmdb/search?query=x"), 502, "tmdb_unavailable");
  });
});
