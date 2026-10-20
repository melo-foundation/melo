import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { relayUrl, setRelayTuningForTest } from "./stream-relay";
import { notify } from "./rpc";

vi.mock("./rpc", () => ({ notify: vi.fn() }));
const notified = () => vi.mocked(notify).mock.calls.filter((c) => c[0] === "stream/dropped").map((c) => c[1]);
const resumed = () => vi.mocked(notify).mock.calls.filter((c) => c[0] === "stream/resumed").map((c) => c[1]);

const CHUNK = 16 * 1024;
const MS = 150;
const DATA = Buffer.alloc(CHUNK * 4 + 1000);
for (let i = 0; i < DATA.length; i++) DATA[i] = (i * 31 + (i >> 8)) & 0xff;

type Handler = (req: http.IncomingMessage, res: http.ServerResponse, n: number) => void;
let behave: Handler = () => {};
let hits = 0;
const upstreamClosed: number[] = [];
let upstream: http.Server;
let base = "";
let seq = 0;

function range(req: http.IncomingMessage): [number, number] {
  const m = /bytes=(\d+)-(\d+)/.exec(req.headers.range || "")!;
  return [parseInt(m[1]), Math.min(parseInt(m[2]), DATA.length - 1)];
}

function head206(res: http.ServerResponse, s: number, e: number): void {
  res.writeHead(206, {
    "content-type": "audio/webm",
    "content-range": `bytes ${s}-${e}/${DATA.length}`,
    "content-length": String(e - s + 1),
  });
}

// a correct ranged answer, at most `cap` bytes
function serve(req: http.IncomingMessage, res: http.ServerResponse, cap = Infinity): void {
  const [s, e0] = range(req);
  const e = Math.min(e0, s + cap - 1);
  head206(res, s, e);
  res.end(DATA.subarray(s, e + 1));
}

interface Got { status: number; body: Buffer; cut: boolean }

function get(url: string, rangeHdr?: string, onData?: (req: http.ClientRequest) => void,
             extra: Record<string, string> = {}): Promise<Got> {
  return new Promise((resolve) => {
    const parts: Buffer[] = [];
    let status = 0;
    let done = false;
    const finish = (cut: boolean) => {
      if (done) return;
      done = true;
      resolve({ status, body: Buffer.concat(parts), cut });
    };
    const req = http.get(url, { headers: { ...(rangeHdr ? { Range: rangeHdr } : {}), ...extra } }, (res) => {
      status = res.statusCode || 0;
      res.on("data", (d: Buffer) => { parts.push(d); onData?.(req); });
      res.on("end", () => finish(false));
      res.on("aborted", () => finish(true));
      res.on("error", () => finish(true));
      res.on("close", () => finish(!res.complete));
    });
    req.on("error", () => finish(true));
  });
}

let lines: string[] = [];
const relayLines = (word: string) => lines.filter((l) => l.startsWith("[relay]") && l.includes(word));
async function until(cond: () => boolean, ms = 3000): Promise<void> {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error("timed out waiting");
    await new Promise((r) => setTimeout(r, 10));
  }
}

beforeAll(async () => {
  setRelayTuningForTest({ chunk: CHUNK, headersMs: MS, idleMs: MS });
  upstream = http.createServer((req, res) => {
    const n = hits++;
    res.on("close", () => upstreamClosed.push(n));
    behave(req, res, n);
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`;
});

afterAll(async () => {
  upstream.closeAllConnections();
  await new Promise((r) => upstream.close(r));
});

let spy: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  lines = [];
  hits = 0;
  upstreamClosed.length = 0;
  vi.mocked(notify).mockClear();
  spy = vi.spyOn(console, "error").mockImplementation((...a: unknown[]) => { lines.push(a.join(" ")); });
});
afterEach(() => {
  spy.mockRestore();
  upstream.closeAllConnections();
});

const fresh = (vid = "vid12345678") => relayUrl(`${base}/v${seq++}?secret=sig`, undefined, undefined, vid);

describe("stream relay", () => {
  it("serves a whole file across chunks with one open and one end line", async () => {
    behave = (req, res) => serve(req, res);
    const url = await fresh();
    const got = await get(url, "bytes=0-");
    expect(got.status).toBe(206);
    expect(got.body.equals(DATA)).toBe(true);
    expect(relayLines(" open ")).toHaveLength(1);
    expect(relayLines(" open ")[0]).toMatch(/vid12345678 open range=bytes=0- status=206 size=\d+/);
    expect(relayLines(" end ")).toHaveLength(1);
    expect(relayLines(" end ")[0]).toMatch(new RegExp(`end sent=${DATA.length} in \\d+ms complete$`));
    expect(notified()).toHaveLength(0);
    expect(lines.join("\n")).not.toContain("secret");
    expect(lines.join("\n")).not.toContain(base);
  });

  it("(a) ends with a timeout when upstream never answers", async () => {
    behave = () => {};
    const url = await fresh();
    const t0 = Date.now();
    const got = await get(url, "bytes=0-");
    expect(Date.now() - t0).toBeLessThan(MS * 3 + 1000);
    expect(got.status).toBe(504);
    expect(relayLines(" retry ")).toHaveLength(2);
    expect(relayLines(" retry ")[0]).toContain("no headers");
    expect(relayLines(" end ")).toHaveLength(1);
    expect(relayLines(" end ")[0]).toMatch(/end sent=0 in \d+ms timeout status=504$/);
    expect(notified()).toHaveLength(0);   // no headers sent: the player sees the 504 itself
    await until(() => upstreamClosed.length === hits);
  });

  it("(b) recovers from a body that stalls mid-chunk, from the same offset", async () => {
    behave = (req, res, n) => {
      if (n !== 0) return serve(req, res);
      const [s, e] = range(req);
      head206(res, s, e);
      res.write(DATA.subarray(s, s + 5000));   // then silence
    };
    const url = await fresh();
    const got = await get(url, "bytes=0-");
    expect(got.body.equals(DATA)).toBe(true);
    expect(relayLines(" retry ")).toHaveLength(1);
    expect(relayLines(" retry ")[0]).toContain("at byte 5000: body idle");
    expect(relayLines(" end ")[0]).toMatch(/complete$/);
  });

  it("(b) cuts the response after three stalls instead of leaving it open", async () => {
    behave = (req, res) => {
      const [s, e] = range(req);
      head206(res, s, e);
      res.write(DATA.subarray(s, s + 100));
    };
    const url = await fresh();
    const t0 = Date.now();
    const got = await get(url, "bytes=0-");
    expect(Date.now() - t0).toBeLessThan(MS * 3 + 1000);
    expect(got.cut).toBe(true);
    expect(relayLines(" end ")).toHaveLength(1);
    expect(relayLines(" end ")[0]).toMatch(/timeout$/);
    // the player takes the cut for an end of stream: melo is told where it stopped
    expect(notified()).toEqual([{ url, videoId: "vid12345678", at: 300 }]);
  });

  it("tells melo of an upstream error after the headers, not of the silence scan's", async () => {
    behave = (req, res) => {   // the first chunk, then 500s
      if (range(req)[0] === 0) return serve(req, res);
      res.writeHead(500); res.end();
    };
    const url = await fresh();
    const got = await get(url, "bytes=0-");
    expect(got.cut).toBe(true);
    expect(notified()).toEqual([{ url, videoId: "vid12345678", at: CHUNK }]);
    vi.mocked(notify).mockClear();
    const scan = await get(url, "bytes=0-", undefined, { "User-Agent": "Lavf/61.7.100" });
    expect(scan.cut).toBe(true);
    expect(notified()).toHaveLength(0);
    // the player reconnects and the stream flows again: melo is told once
    behave = (req, res) => serve(req, res);
    await get(url, `bytes=${CHUNK}-`, undefined, { "User-Agent": "Lavf/61.7.100" });
    expect(resumed()).toHaveLength(0);
    const again = await get(url, `bytes=${CHUNK}-`);
    expect(again.body.equals(DATA.subarray(CHUNK))).toBe(true);
    expect(resumed()).toEqual([{ url, videoId: "vid12345678" }]);
    await get(url, `bytes=${CHUNK}-`);
    expect(resumed()).toHaveLength(1);
  });

  it("(c) a short 206 advances by the bytes received", async () => {
    behave = (req, res) => serve(req, res, 10_000);
    const url = await fresh();
    const got = await get(url, `bytes=1000-${DATA.length - 1}`);
    expect(got.status).toBe(206);
    expect(got.body.equals(DATA.subarray(1000))).toBe(true);
    expect(relayLines(" retry ")).toHaveLength(0);
    expect(relayLines(" end ")).toHaveLength(1);
    expect(relayLines(" end ")[0]).toMatch(/complete$/);
  });

  it("(d) a client disconnect mid-chunk aborts the fetch and the prefetch", async () => {
    behave = (req, res) => {
      const [s, e] = range(req);
      head206(res, s, e);
      res.write(DATA.subarray(s, s + 4000));   // then hold
    };
    const url = await fresh();
    const p = get(url, "bytes=0-", (req) => { setTimeout(() => req.destroy(), 30); });
    await p;
    await until(() => relayLines(" end ").length === 1, MS * 2);
    expect(relayLines(" end ")[0]).toMatch(/client closed$/);
    expect(hits).toBe(2);   // the chunk and its prefetch
    await until(() => upstreamClosed.length === 2, MS * 2);
    expect(relayLines(" retry ")).toHaveLength(0);
  });

  it("adds no listener per chunk", async () => {
    const warnings: string[] = [];
    const onWarn = (w: Error) => warnings.push(w.name);
    process.on("warning", onWarn);
    setRelayTuningForTest({ chunk: 1024 });
    try {
      behave = (req, res) => serve(req, res);
      const got = await get(await fresh(), "bytes=0-");
      expect(got.body.equals(DATA)).toBe(true);
      await new Promise((r) => setTimeout(r, 20));
      expect(warnings).not.toContain("MaxListenersExceededWarning");
    } finally {
      setRelayTuningForTest({ chunk: CHUNK });
      process.off("warning", onWarn);
    }
  });

  it("logs evictions and a 404 for an evicted id", async () => {
    behave = (req, res) => serve(req, res);
    const first = await fresh("evictme0001");
    for (let i = 0; i < 64; i++) await fresh();
    expect(relayLines("evictme0001 evicted")).toHaveLength(1);
    const got = await get(first, "bytes=0-");
    expect(got.status).toBe(404);
    expect(relayLines(" 404 evicted evictme0001")).toHaveLength(1);
  });
});
