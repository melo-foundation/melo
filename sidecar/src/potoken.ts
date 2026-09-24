// PO token minting (BotGuard / Web Anti-Abuse). Without a valid Proof-of-Origin
// token, googlevideo 403s every byte past a per-file wall (~27-50% in), so
// playback dies a minute in and scrubbing fails. YouTube validates the token,
// so a shape-valid placeholder is not enough. One BotGuard run (~1s) per
// integrity token (~12h), then per-video tokens mint in ~0ms, so the minter is
// cached, never set up per track. bgutils-js + jsdom stay external to the bundle: BotGuard
// fingerprints the DOM and refuses a hand-written shim.

import { log } from "./rpc";

interface Minter {
  mintAsWebsafeString(contentBinding: string): Promise<string>;
}

interface Session {
  visitorData: string;
  minter: Minter;
  expiresAt: number;
}

const REQUEST_KEY = "O43z0dpjhgX20SCx4KAo";
const GOOG_BASE = "https://jnn-pa.googleapis.com";
const GOOG_API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw";
const BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

// Refresh a little before the reported TTL so a long queue never mints against
// an integrity token that expires mid-track.
const TTL_SAFETY_MS = 30 * 60 * 1000;

let session: Promise<Session> | null = null;

/** Install the globals BotGuard's VM expects. Node 22 makes `navigator` a
 *  getter-only global, so Object.assign() throws — defineProperty each one. */
function installDom(dom: { window: Record<string, unknown> }): void {
  const w = dom.window as Record<string, any>;
  const globals: Record<string, unknown> = {
    window: w, document: w.document, location: w.location, navigator: w.navigator,
  };
  for (const [k, v] of Object.entries(globals)) {
    Object.defineProperty(globalThis, k, { value: v, writable: true, configurable: true });
  }
}

async function createSession(): Promise<Session> {
  const { JSDOM } = await import("jsdom");
  const { getChallenge, BotGuardClient } = await import("bgutils-js/botguard");
  const { WebPoMinter } = await import("bgutils-js/webpo");

  // The token is bound to an identity; YouTube's own homepage issues one.
  const html = await (await fetch("https://www.youtube.com", {
    headers: { "User-Agent": BROWSER_UA },
  })).text();
  const m = /"visitorData":"([^"]+)"/.exec(html);
  if (!m) throw new Error("no visitorData on youtube.com");
  const visitorData = JSON.parse(`"${m[1]}"`) as string;

  installDom(new JSDOM("<!doctype html><html><body></body></html>",
    { url: "https://www.youtube.com/" }) as never);

  const challenge = await getChallenge({
    requestKey: REQUEST_KEY,
    fetchFunction: fetch as never,
  });
  const js = challenge.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!js) throw new Error("challenge carried no interpreter");
  new Function(js)();

  const client = await BotGuardClient.create({
    program: challenge.program,
    globalName: challenge.globalName,
    globalObject: globalThis,
  });

  const webPoSignalOutput: unknown[] = [];
  const botguardResponse = await client.snapshot({ webPoSignalOutput } as never);

  const res = await fetch(`${GOOG_BASE}/$rpc/google.internal.waa.v1.Waa/GenerateIT`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json+protobuf",
      "x-goog-api-key": GOOG_API_KEY,
      "x-user-agent": "grpc-web-javascript/0.1",
    },
    body: JSON.stringify([REQUEST_KEY, botguardResponse]),
  });
  const [integrityToken, ttlSecs] = (await res.json()) as [string, number];
  if (!integrityToken) throw new Error("no integrity token returned");

  const minter = await WebPoMinter.create({ integrityToken }, webPoSignalOutput as never);
  const ttlMs = Math.max((ttlSecs ?? 0) * 1000 - TTL_SAFETY_MS, 60_000);
  log(`[potoken] session ready (ttl ${ttlSecs}s)`);
  return { visitorData, minter, expiresAt: Date.now() + ttlMs };
}

function getSession(): Promise<Session> {
  if (!session) session = createSession().catch((e) => { session = null; throw e; });
  return session.then((s) => {
    if (Date.now() < s.expiresAt) return s;
    session = null;
    return getSession();
  });
}

export interface PoToken { token: string; visitorData: string }

export interface PoTokenSession {
  visitorData: string;
  /** Mint for an arbitrary binding: the visitor id for a session token, or a
   *  video id for the `pot=` that goes on a stream URL. The two are NOT
   *  interchangeable — a session-bound token on a stream URL is walled. */
  mint(binding: string): Promise<string>;
}

/** The live minter, or null if BotGuard is unreachable. */
export async function poTokenSession(): Promise<PoTokenSession | null> {
  try {
    const s = await getSession();
    return { visitorData: s.visitorData, mint: (b) => s.minter.mintAsWebsafeString(b) };
  } catch (e) {
    log(`[potoken] session unavailable: ${String(e).split("\n")[0]}`);
    return null;
  }
}

/** Mint a gvs PO token bound to `videoId`, or null if BotGuard is unreachable.
 *  Callers fall back to resolving without one (which still plays the opening
 *  of a track) rather than failing the request outright. */
export async function mintPoToken(videoId: string): Promise<PoToken | null> {
  try {
    const s = await getSession();
    return { token: await s.minter.mintAsWebsafeString(videoId), visitorData: s.visitorData };
  } catch (e) {
    log(`[potoken] mint failed: ${String(e).split("\n")[0]}`);
    return null;
  }
}

/** Build the BotGuard session ahead of the first play. Setup costs ~1.5s
 *  (measured: first resolve 5683ms vs 4110ms warm), and it is pure latency on
 *  whatever track the user clicks first. Fire-and-forget from initialize: a
 *  failure here just leaves the session null so the first mint retries. */
export function warmPoTokenSession(): void {
  const t0 = Date.now();
  getSession().then(
    () => log(`[potoken] prewarmed in ${Date.now() - t0}ms`),
    () => { /* mintPoToken() logs and retries on demand */ },
  );
}
