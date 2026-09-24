import http from "node:http";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";

// Localhost relay for googlevideo stream URLs. Some clients' URLs (IOS) 403
// plain GETs and only accept ranged requests — GStreamer's souphttpsrc opens
// with a plain GET. The relay always sends a Range upstream (passing the
// player's own Range through for seeks) and can attach extra headers.
interface Entry {
  url: string;
  headers?: Record<string, string>;
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

export async function relayUrl(
  target: string, headers?: Record<string, string>,
  onUpstreamError?: (status: number) => void,
): Promise<string> {
  await ensureServer();
  const existing = idByUrl.get(target);
  if (existing && entries.has(existing)) {
    const e = entries.get(existing)!;
    // keep the newest owner's hook; a caller with none (the silence scan)
    // must not erase the deck's
    if (onUpstreamError) e.onUpstreamError = onUpstreamError;
    return `http://127.0.0.1:${port}/s/${existing}`;
  }

  const id = randomUUID();
  entries.set(id, { url: target, headers, onUpstreamError });
  idByUrl.set(target, id);
  while (entries.size > 64) {
    const oldest = entries.keys().next().value as string;
    const stale = entries.get(oldest);
    entries.delete(oldest);
    if (stale && idByUrl.get(stale.url) === oldest) idByUrl.delete(stale.url);
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

// googlevideo 403s plain GETs and open-ended ranges (bytes=N-) on the clients
// that need relaying; only bounded ranges succeed. souphttpsrc sends
// open-ended ranges, so the relay fetches bounded 1MB chunks and stitches them.
// Chunk size is not capped: a gated client 403s any range ending past a
// per-file wall (~27% in), and picking the right client removes the wall.
const CHUNK = 1024 * 1024;

async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  const id = (req.url || "").split("/s/")[1];
  const entry = id ? entries.get(id) : undefined;
  if (!entry) { res.writeHead(404); res.end(); return; }

  // parse client range: "bytes=S-" or "bytes=S-E" (default whole file)
  const m = /bytes=(\d+)-(\d+)?/.exec(req.headers.range || "");
  const startPos = m ? parseInt(m[1]) : 0;
  const clientEnd = m?.[2] ? parseInt(m[2]) : Infinity;

  let closed = false;
  res.on("close", () => { closed = true; });

  try {
    let pos = startPos;
    let total = -1;
    const fetchChunk = (p: number) => fetch(entry.url, {
      headers: { Range: `bytes=${p}-${Math.min(p + CHUNK - 1, clientEnd)}`, ...(entry.headers || {}) },
    });
    let nextFetch: Promise<Response> | null = null;
    while (!closed && (total < 0 || pos < total) && pos <= clientEnd) {
      const end = Math.min(pos + CHUNK - 1, clientEnd);
      const upstream = await (nextFetch ?? fetchChunk(pos));
      nextFetch = null;
      if (!(upstream.status === 206 || upstream.status === 200)) {
        console.error(`[relay] upstream ${upstream.status} at byte ${pos}`);
        entry.onUpstreamError?.(upstream.status);
        if (!res.headersSent) res.writeHead(upstream.status === 403 ? 403 : 502);
        break;
      }
      // a 200 means the server IGNORED the Range — its body starts at byte 0.
      // Piping it as if it were bytes pos.. serves the wrong audio at the
      // wrong position (seeks landing "further into the song").
      if (upstream.status === 200 && pos > 0) {
        console.error(`[relay] upstream ignored Range at byte ${pos}`);
        if (!res.headersSent) res.writeHead(502);
        break;
      }
      if (total < 0) {   // first chunk: learn size, answer the client
        // content-range total -> the URL's clen= param -> content-length.
        // NEVER a made-up huge number: gst maps time<->bytes with it, and a
        // lie sends every seek to absurd offsets (stalls, wrong landings).
        const t = upstream.headers.get("content-range")?.split("/")[1];
        if (t && t !== "*") total = parseInt(t);
        else {
          const clen = /[?&]clen=(\d+)/.exec(entry.url)?.[1];
          if (clen) total = parseInt(clen);
          else if (upstream.status === 200) {
            const cl = upstream.headers.get("content-length");
            total = cl ? parseInt(cl) : Number.MAX_SAFE_INTEGER;
          } else total = Number.MAX_SAFE_INTEGER;
        }
        if (total === Number.MAX_SAFE_INTEGER)
          console.error("[relay] stream size unknown (no content-range/clen) — seeks will misbehave");
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
      }
      // pipeline: fetch the NEXT chunk while this one pipes — serial fetches
      // add a full upstream round-trip of dead air per MB after seeks
      const nPos = end + 1;
      if (!closed && (total < 0 || nPos < total) && nPos <= clientEnd) {
        nextFetch = fetchChunk(nPos);
        nextFetch.catch(() => {});   // abandoned on break/close — don't reject unhandled
      }
      if (upstream.body) {
        const body = Readable.fromWeb(upstream.body as never);
        await new Promise<void>((resolve, reject) => {
          body.pipe(res, { end: false });
          body.on("end", resolve);
          body.on("error", reject);
          res.on("close", () => { body.destroy(); resolve(); });
        });
      }
      pos = end + 1;
    }
  } catch (e) {
    console.error(`[relay] failed: ${String(e).split("\n")[0]}`);
    if (!res.headersSent) res.writeHead(502);
  }
  res.end();
}
