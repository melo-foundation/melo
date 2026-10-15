import http from "node:http";
import { randomUUID } from "node:crypto";

// Localhost relay for googlevideo stream URLs. Some clients' URLs (IOS) 403
// plain GETs and only accept ranged requests — GStreamer's souphttpsrc opens
// with a plain GET. The relay always sends a Range upstream (passing the
// player's own Range through for seeks) and can attach extra headers.
interface Entry {
  url: string;
  headers?: Record<string, string>;
  videoId?: string;
  /** Called when googlevideo rejects a chunk, so the caller can drop any
   *  cached copy of this URL — otherwise the player's "retry with a fresh
   *  resolve" just gets the same dead URL back from cache and gives up. */
  onUpstreamError?: (status: number) => void;
}

const entries = new Map<string, Entry>();
let server: http.Server | null = null;
let port = 0;

// Reverse index so one upstream URL keeps one relay id: the player asks for a
// stream repeatedly (~15x a track), and fresh ids would push the one the deck
// is streaming from out of the 64-slot map (a 404 mid-play).
const idByUrl = new Map<string, string>();

// Evicted ids and their videoId, so a 404 says why; capped at 256.
const evicted = new Map<string, string>();

// googlevideo 403s plain GETs and open-ended ranges (bytes=N-) on the clients
// that need relaying; only bounded ranges succeed. souphttpsrc sends
// open-ended ranges, so the relay fetches bounded 1MB chunks and stitches them.
// Chunk size is not capped: a gated client 403s any range ending past a
// per-file wall (~27% in), and picking the right client removes the wall.
const tuning = {
  chunk: 1024 * 1024,
  // a chunk with no headers, or a body silent this long, is retried
  headersMs: 15_000,
  idleMs: 15_000,
  retries: 2,
};

/** @internal test seam */
export function setRelayTuningForTest(t: Partial<typeof tuning>): void {
  Object.assign(tuning, t);
}

const tag = (id: string, e?: Entry) => `${id.slice(0, 8)}${e?.videoId ? ` ${e.videoId}` : ""}`;

export async function relayUrl(
  target: string, headers?: Record<string, string>,
  onUpstreamError?: (status: number) => void,
  videoId?: string,
): Promise<string> {
  await ensureServer();
  const existing = idByUrl.get(target);
  if (existing && entries.has(existing)) {
    const e = entries.get(existing)!;
    // keep the newest owner's hook; a caller with none (the silence scan)
    // must not erase the deck's
    if (onUpstreamError) e.onUpstreamError = onUpstreamError;
    if (videoId) e.videoId = videoId;
    return `http://127.0.0.1:${port}/s/${existing}`;
  }

  const id = randomUUID();
  entries.set(id, { url: target, headers, onUpstreamError, videoId });
  idByUrl.set(target, id);
  while (entries.size > 64) {
    const oldest = entries.keys().next().value as string;
    const stale = entries.get(oldest);
    entries.delete(oldest);
    if (stale && idByUrl.get(stale.url) === oldest) idByUrl.delete(stale.url);
    console.error(`[relay] ${tag(oldest, stale)} evicted`);
    evicted.set(oldest, stale?.videoId ?? "");
    if (evicted.size > 256) evicted.delete(evicted.keys().next().value as string);
  }
  return `http://127.0.0.1:${port}/s/${id}`;
}

function ensureServer(): Promise<void> {
  if (server) return Promise.resolve();
  return new Promise((resolve) => {
    server = http.createServer(handle);
    server.listen(0, "127.0.0.1", () => {
      port = (server!.address() as { port: number }).port;
      console.error(`[relay] listening on 127.0.0.1:${port}`);
      resolve();
    });
  });
}

// One upstream chunk request; `why` is set before any abort the relay makes.
interface Pending {
  from: number;
  ctrl: AbortController;
  res: Promise<Response>;
  why?: "no headers" | "body idle";
}

function startChunk(entry: Entry, from: number, to: number): Pending {
  const p = { from, ctrl: new AbortController() } as Pending;
  const timer = setTimeout(() => { p.why = "no headers"; p.ctrl.abort(); }, tuning.headersMs);
  p.res = fetch(entry.url, {
    headers: { Range: `bytes=${from}-${to}`, ...(entry.headers || {}) },
    signal: p.ctrl.signal,
  }).finally(() => clearTimeout(timer));
  p.res.catch(() => {});   // abandoned on break/close — don't reject unhandled
  return p;
}

type Ending = "complete" | "client closed" | "upstream error" | "timeout";

async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  const id = (req.url || "").split("/s/")[1] || "";
  const entry = id ? entries.get(id) : undefined;
  if (!entry) {
    const was = evicted.get(id);
    const why = was !== undefined ? `evicted${was ? ` ${was}` : ""}` : "unknown id";
    console.error(`[relay] ${id.slice(0, 8)} 404 ${why}`);
    res.writeHead(404); res.end(); return;
  }
  const t = tag(id, entry);

  // parse client range: "bytes=S-" or "bytes=S-E" (default whole file)
  const m = /bytes=(\d+)-(\d+)?/.exec(req.headers.range || "");
  const startPos = m ? parseInt(m[1]) : 0;
  const clientEnd = m?.[2] ? parseInt(m[2]) : Infinity;

  const t0 = Date.now();
  let closed = false;
  let cur: Pending | null = null;
  let next: Pending | null = null;
  let wake: (() => void) | null = null;
  // the only close listener on this response
  res.on("close", () => {
    closed = true;
    cur?.ctrl.abort();
    next?.ctrl.abort();
    wake?.();
  });
  const drain = () => new Promise<void>((r) => { wake = r; res.once("drain", r); });

  let ending: Ending = "complete";
  let sent = 0;
  let retries = 0;
  try {
    let pos = startPos;
    let total = -1;
    while ((total < 0 || pos < total) && pos <= clientEnd) {
      if (closed) { ending = "client closed"; break; }
      const end = Math.min(pos + tuning.chunk - 1, clientEnd);
      if (next && next.from === pos) cur = next;
      else { next?.ctrl.abort(); cur = startChunk(entry, pos, end); }
      next = null;
      const chunk: Pending = cur;
      let received = 0;
      try {
        const upstream = await chunk.res;
        if (!(upstream.status === 206 || upstream.status === 200)) {
          console.error(`[relay] ${t} upstream ${upstream.status} at byte ${pos}`);
          entry.onUpstreamError?.(upstream.status);
          if (!res.headersSent) res.writeHead(upstream.status === 403 ? 403 : 502);
          ending = "upstream error";
          break;
        }
        // a 200 means the server IGNORED the Range — its body starts at byte 0.
        // Piping it as if it were bytes pos.. serves the wrong audio at the
        // wrong position (seeks landing "further into the song").
        if (upstream.status === 200 && pos > 0) {
          console.error(`[relay] ${t} upstream ignored Range at byte ${pos}`);
          if (!res.headersSent) res.writeHead(502);
          ending = "upstream error";
          break;
        }
        if (total < 0) {   // first chunk: learn size, answer the client
          // content-range total -> the URL's clen= param -> content-length.
          // NEVER a made-up huge number: gst maps time<->bytes with it, and a
          // lie sends every seek to absurd offsets (stalls, wrong landings).
          const cr = upstream.headers.get("content-range")?.split("/")[1];
          if (cr && cr !== "*") total = parseInt(cr);
          else {
            const clen = /[?&]clen=(\d+)/.exec(entry.url)?.[1];
            if (clen) total = parseInt(clen);
            else if (upstream.status === 200) {
              const cl = upstream.headers.get("content-length");
              total = cl ? parseInt(cl) : Number.MAX_SAFE_INTEGER;
            } else total = Number.MAX_SAFE_INTEGER;
          }
          const h: Record<string, string> = { "accept-ranges": "bytes" };
          const ct = upstream.headers.get("content-type");
          if (ct) h["content-type"] = ct;
          const last = Math.min(clientEnd, total - 1);
          if (req.headers.range) {
            h["content-range"] = `bytes ${startPos}-${last}/${total}`;
            h["content-length"] = String(last - startPos + 1);
            res.writeHead(206, h);
          } else {
            h["content-length"] = String(total);
            res.writeHead(200, h);
          }
          const size = total === Number.MAX_SAFE_INTEGER ? "unknown" : String(total);
          console.error(`[relay] ${t} open range=${req.headers.range ?? "none"} status=${res.statusCode} size=${size}`);
        }
        // pipeline: fetch the NEXT chunk while this one pipes — serial fetches
        // add a full upstream round-trip of dead air per MB after seeks
        const nPos = end + 1;
        if (!closed && nPos < total && nPos <= clientEnd)
          next = startChunk(entry, nPos, Math.min(nPos + tuning.chunk - 1, clientEnd));
        if (upstream.body) {
          const reader = upstream.body.getReader();
          for (;;) {
            const idle = setTimeout(() => { chunk.why = "body idle"; chunk.ctrl.abort(); }, tuning.idleMs);
            let r: ReadableStreamReadResult<Uint8Array>;
            try { r = await reader.read(); } finally { clearTimeout(idle); }
            if (r.done || closed) break;
            received += r.value.byteLength;
            sent += r.value.byteLength;
            if (!res.write(r.value) && !closed) await drain();
            if (closed) break;
          }
        }
        if (closed) { ending = "client closed"; break; }
        if (received === 0) throw new Error("empty body");
      } catch (e) {
        if (closed) { ending = "client closed"; break; }
        pos += received;
        const reason = chunk.why ?? `error ${String(e).split("\n")[0]}`;
        if (retries >= tuning.retries) {
          console.error(`[relay] ${t} gave up at byte ${pos}: ${reason}`);
          ending = chunk.why ? "timeout" : "upstream error";
          if (!res.headersSent) res.writeHead(chunk.why ? 504 : 502);
          break;
        }
        retries++;
        console.error(`[relay] ${t} retry ${retries}/${tuning.retries} at byte ${pos}: ${reason}`);
        continue;
      }
      // a short 206 advances by what arrived; the prefetch is dropped next pass
      pos += received;
      retries = 0;
    }
  } catch (e) {
    console.error(`[relay] ${t} failed: ${String(e).split("\n")[0]}`);
    if (!res.headersSent) res.writeHead(502);
    ending = "upstream error";
  } finally {
    cur?.ctrl.abort();
    next?.ctrl.abort();
  }
  // a short body under a sent content-length leaves the client waiting; cut it
  if (ending === "complete" || res.statusCode >= 400) res.end();
  else res.destroy();
  const status = res.statusCode >= 400 ? ` status=${res.statusCode}` : "";
  console.error(`[relay] ${t} end sent=${sent} in ${Date.now() - t0}ms ${ending}${status}`);
}
