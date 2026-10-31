import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createServer, type Server } from "http";
import { createRequire } from "module";
import { setUpFetch } from "./proxy";

// Node's fetch ignores HTTP(S)_PROXY, and the undici jsdom loads replaces Node's
// dispatcher anyway.
describe("a proxy in the environment", () => {
  let server: Server, url = "";
  beforeAll(async () => {
    server = createServer((_q, r) => r.end("direct"));
    await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
    url = `http://127.0.0.1:${(server.address() as any).port}/`;
  });
  afterAll(() => server.close());

  it("is not used when none is set", () => {
    expect(setUpFetch({})).toBe(false);
  });

  it("carries every fetch, before and after jsdom loads", async () => {
    expect(await (await fetch(url)).text()).toBe("direct");
    expect(setUpFetch({ HTTP_PROXY: "http://127.0.0.1:9", HTTPS_PROXY: "http://127.0.0.1:9" })).toBe(true);
    await expect(fetch(url)).rejects.toThrow();
    createRequire(import.meta.url)("jsdom");
    await expect(fetch(url)).rejects.toThrow();
  });
});

// youtube.com's front page sends up to 19 KB of headers, over Node's 16 KB
describe("large response headers", () => {
  let server: Server, url = "";
  beforeAll(async () => {
    server = createServer((_q, r) => { r.setHeader("x-big", "a".repeat(20 * 1024)); r.end("ok"); });
    await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
    url = `http://127.0.0.1:${(server.address() as any).port}/`;
  });
  afterAll(() => server.close());

  it("are read, before and after jsdom loads", async () => {
    setUpFetch({});
    expect(await (await fetch(url)).text()).toBe("ok");
    createRequire(import.meta.url)("jsdom");
    expect(await (await fetch(url)).text()).toBe("ok");
  });
});
