import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BODY_BYTES } from "../src/body";
import { authed, clearLibrary, expectError, film, send } from "./helpers";

beforeEach(clearLibrary);

describe("request body parsing", () => {
  it("malformed JSON → 400 invalid_json", async () => {
    await expectError(await authed("/library/films", { method: "POST", body: "{not json" }), 400, "invalid_json");
    await expectError(await authed("/library/films", { method: "POST" }), 400, "invalid_json");
  });

  it("valid JSON of the wrong shape → 400 invalid_request with a useful message", async () => {
    const message = await expectError(await send("POST", "/library/films", [1, 2]), 400, "invalid_request");
    expect(message).toContain("body");
    const nested = await expectError(
      await send("POST", "/library/films", { films: [film(1), { ...film(2), year: "2000" }] }),
      400,
      "invalid_request",
    );
    expect(nested).toContain("films[1].year");
  });

  it("non-boxd.it URI → 400 invalid_request", async () => {
    for (const letterboxd_uri of ["https://letterboxd.com/film/x/", "http://boxd.it/abc", "https://boxd.it/", 42]) {
      await expectError(
        await send("POST", "/library/films", { films: [{ ...film(1), letterboxd_uri }] }),
        400,
        "invalid_request",
      );
    }
  });

  it("ignores unknown extra fields", async () => {
    const res = await send("POST", "/library/films", { extra: true, films: [{ ...film(1), extra: "x" }] });
    expect(res.status).toBe(200);
  });

  it("body over 5 MB with Content-Length → 413 payload_too_large", async () => {
    const body = JSON.stringify({ films: [], pad: "x".repeat(MAX_BODY_BYTES) });
    await expectError(await authed("/library/films", { method: "POST", body }), 413, "payload_too_large");
  });

  it("streamed body over 5 MB without Content-Length → 413 payload_too_large", async () => {
    const chunk = new Uint8Array(1024 * 1024).fill(0x20);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent > MAX_BODY_BYTES) return controller.close();
        sent += chunk.byteLength;
        controller.enqueue(chunk);
      },
    });
    const res = await authed("/library/films", { method: "POST", body: stream });
    await expectError(res, 413, "payload_too_large");
  });
});
