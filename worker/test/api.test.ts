import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index";

const KEY = env.API_KEY;
const BASE = "https://harbinger-api.aurlaw.dev";

function call(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(`${BASE}${path}`, init);
}

function authed(path: string, init: RequestInit = {}): Promise<Response> {
  return call(path, { ...init, headers: { Authorization: `Bearer ${KEY}` } });
}

// Calls the handler directly so the test can substitute bindings.
function callWithEnv(overrides: Partial<Env>, path = "/health", headers?: HeadersInit) {
  const request = new Request(`${BASE}${path}`, { headers }) as Parameters<typeof worker.fetch>[0];
  return worker.fetch(request, { ...env, ...overrides });
}

async function expectError(res: Response, status: number, code: string) {
  expect(res.status).toBe(status);
  expect(res.headers.get("Content-Type")).toBe("application/json");
  expect(res.headers.get("Cache-Control")).toBe("no-store");
  const body = await res.json();
  expect(body).toEqual({ error: { code, message: expect.any(String) } });
  expect(Object.keys(body as object)).toEqual(["error"]);
  expect((body as { error: { message: string } }).error.message.length).toBeGreaterThan(0);
}

describe("API key middleware", () => {
  it("rejects a request with no Authorization header", async () => {
    await expectError(await call("/health"), 401, "unauthorized");
  });

  it("rejects the Basic scheme", async () => {
    const res = await call("/health", { headers: { Authorization: `Basic ${btoa(`user:${KEY}`)}` } });
    await expectError(res, 401, "unauthorized");
  });

  it("rejects Bearer with an empty token", async () => {
    await expectError(await call("/health", { headers: { Authorization: "Bearer " } }), 401, "unauthorized");
    await expectError(await call("/health", { headers: { Authorization: "Bearer" } }), 401, "unauthorized");
  });

  it("rejects a wrong key of the same length", async () => {
    const wrong = "x".repeat(KEY.length);
    expect(wrong).not.toBe(KEY);
    const res = await call("/health", { headers: { Authorization: `Bearer ${wrong}` } });
    await expectError(res, 401, "unauthorized");
  });

  it("rejects a wrong key of a different length", async () => {
    for (const wrong of [KEY.slice(0, -1), `${KEY}x`, "a"]) {
      const res = await call("/health", { headers: { Authorization: `Bearer ${wrong}` } });
      await expectError(res, 401, "unauthorized");
    }
  });

  it("returns 401, not 404, for an unauthenticated request to an unknown path", async () => {
    await expectError(await call("/does-not-exist"), 401, "unauthorized");
  });

  it("fails closed with 500 when API_KEY is unset or empty", async () => {
    for (const API_KEY of [undefined, ""]) {
      const overrides = { API_KEY } as Partial<Env>;
      await expectError(await callWithEnv(overrides), 500, "internal_error");
      await expectError(
        await callWithEnv(overrides, "/does-not-exist", { Authorization: "Bearer " }),
        500,
        "internal_error",
      );
    }
  });
});

describe("routing", () => {
  it("returns 404 for an authenticated request to an unknown path", async () => {
    await expectError(await authed("/does-not-exist"), 404, "not_found");
  });

  it("returns 405 for POST /health", async () => {
    const res = await authed("/health", { method: "POST" });
    await expectError(res, 405, "method_not_allowed");
    expect(res.headers.get("Allow")).toBe("GET");
  });
});

describe("GET /health", () => {
  it("returns 200 { status: ok } with the correct key", async () => {
    const res = await authed("/health");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(await res.json()).toEqual({ status: "ok" });
  });

  it("returns 503 db_unavailable without leaking the underlying error", async () => {
    const failingDb = {
      prepare: () => ({
        first: () => Promise.reject(new Error("SECRET_INTERNAL_DETAIL")),
      }),
    } as unknown as D1Database;
    const res = await callWithEnv({ DB: failingDb }, "/health", { Authorization: `Bearer ${KEY}` });
    const text = await res.clone().text();
    expect(text).not.toContain("SECRET_INTERNAL_DETAIL");
    await expectError(res, 503, "db_unavailable");
  });
});
