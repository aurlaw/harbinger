import { env, exports } from "cloudflare:workers";
import { expect } from "vitest";

export const BASE = "https://harbinger-api.aurlaw.dev";

export function call(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(`${BASE}${path}`, init);
}

export function authed(path: string, init: RequestInit = {}): Promise<Response> {
  return call(path, { ...init, headers: { Authorization: `Bearer ${env.API_KEY}`, ...init.headers } });
}

export function send(method: string, path: string, body: unknown): Promise<Response> {
  return authed(path, { method, body: JSON.stringify(body), headers: { "Content-Type": "application/json" } });
}

export async function expectError(res: Response, status: number, code: string): Promise<string> {
  expect(res.status).toBe(status);
  expect(res.headers.get("Content-Type")).toBe("application/json");
  expect(res.headers.get("Cache-Control")).toBe("no-store");
  const body = (await res.json()) as { error: { code: string; message: string } };
  expect(body).toEqual({ error: { code, message: expect.any(String) } });
  expect(body.error.message.length).toBeGreaterThan(0);
  return body.error.message;
}

export async function ok<T = Record<string, unknown>>(res: Response): Promise<T> {
  if (res.status !== 200) throw new Error(`expected 200, got ${res.status}: ${await res.text()}`);
  expect(res.headers.get("Content-Type")).toBe("application/json");
  return (await res.json()) as T;
}

/** Storage is shared by tests within a file, so each W2 test starts from empty tables. */
export async function clearLibrary(): Promise<void> {
  await env.DB.batch(
    ["ratings", "watched", "watchlist", "likes", "imports", "films"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)),
  );
}

export const uri = (n: number | string) => `https://boxd.it/f${n}`;

export function film(n: number | string, overrides: Partial<{ name: string; year: number }> = {}) {
  return { letterboxd_uri: uri(n), name: `Film ${n}`, year: 2000, ...overrides };
}

export async function seedFilms(...ns: (number | string)[]): Promise<void> {
  await ok(await send("POST", "/library/films", { films: ns.map((n) => film(n)) }));
}

export async function count(table: string): Promise<number> {
  const row = await env.DB.prepare(`SELECT COUNT(*) AS c FROM ${table}`).first<{ c: number }>();
  return row?.c ?? 0;
}

/** Workers only advance Date.now() across I/O; wait so consecutive timestamps differ. */
export const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

export const range = (n: number) => Array.from({ length: n }, (_, i) => i);
