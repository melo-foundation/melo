// Stream/video/playlist/radio functions. Settings come from loadSettings(),
// the yt-dlp path from YTDLP(), and yt-dlp runs with `--js-runtimes node`
// (YouTube's SABR/PO-token era requires a JS runtime; we ship Node anyway).

import { execFile } from "child_process";
import { promisify } from "util";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "path";
import vm from "node:vm";
import type { Innertube } from "youtubei.js";
import { YTDLP } from "./platform";
import { loadSettings, localePref } from "./settings";
import { dataDir } from "./env";
import {
  writeNetscapeCookieFile,
  parseNetscapeCookieFile,
  mergeGuestCookies,
  cookiesTxtPath,
} from "./guest-cookies";
import { getDownloadedUrl, getTrackMetadata } from "./library";
import { resolveCookies } from "./innertube";
import { relayUrl } from "./stream-relay";
import { looksStale, ytdlpChannel } from "./ytdlp";
import { notify } from "./rpc";
import { mintPoToken, poTokenSession, type PoToken } from "./potoken";

/** True only for googlevideo CDN URLs that 403 a plain GET. */
export function needsStreamRelay(url: string): boolean {
  if (!url) return false;
  try {
    const u = new URL(url);
    if (u.hostname === "127.0.0.1" || u.hostname === "localhost") return false;
    return u.hostname === "googlevideo.com" || u.hostname.endsWith(".googlevideo.com");
  } catch {
    return false;
  }
}

function ytdlpHttpHeaders(data: { http_headers?: unknown }): Record<string, string> | undefined {
  const h = data.http_headers;
  if (!h || typeof h !== "object" || Array.isArray(h)) return undefined;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(h as Record<string, unknown>)) {
    if (typeof v === "string" && v) out[k] = v;
  }
  return Object.keys(out).length ? out : undefined;
}

const execFileAsync = promisify(execFile);

// ---- fast in-process stream resolution (youtubei.js) --------------------
// yt-dlp with `--js-runtimes node` costs ~6s per stream (and ~20s whenever
// YouTube ships a new player build). youtubei.js deciphers in-process in
// well under a second; yt-dlp remains the fallback for anything it can't do.
let itSession: Promise<Innertube> | null = null;

// youtubei.js is external to the bundle (~930KB) and loads lazily inside
// getSession(). v17 removed its bundled JS interpreter, so a node:vm evaluator
// is registered for sig/nsig deciphering; the extracted script is a function
// body (top-level return) and must be wrapped. It is YouTube's player code,
// which yt-dlp's EJS runs through node as well.
function installEvalShim(Platform: any): void {
  if (Platform.shim.eval?.__melo) return;
  // The extracted program is SELF-CONTAINED: it ends with `return process(...)`
  // with the sig/nsig inputs already baked in, and evaluates to {sig, n}.
  // Named exports (`nsigFunction`, `rawValues`) are never bound, so pulling
  // them out fails with "Failed to decipher nsig". Run it and return its value.
  Platform.shim.eval = async (data: any, _env: Record<string, unknown>) => {
    const ctx = vm.createContext(Object.create(null));
    return vm.runInContext(
      `"use strict";(function(){\n${data.output}\n})()`, ctx, { timeout: 5000 });
  };
  Platform.shim.eval.__melo = true;
}

// In-process resolution via youtubei.js: ~250ms vs ~4250ms for a yt-dlp spawn,
// same opus itag 251. yt-dlp is the fallback (e.g. non-music videos, which
// YTMUSIC reports as having no audio format). The URL's `pot=` is replaced:
// youtubei.js puts a session-bound token there, which googlevideo walls; it
// must be bound to the video id. MELO_NO_FAST_STREAMS=1 forces yt-dlp.
const FAST_STREAMS = !process.env.MELO_NO_FAST_STREAMS;

export function warmStreamSession(): void {
  if (!FAST_STREAMS) return;
  getSession().catch(() => { itSession = null; sessionKey = ""; });
}

// Session follows the cookie settings (guest profile / browser / none) and is
// recreated whenever they change — streams must use the same identity yt-dlp
// would have used.
let sessionKey = "";

function getSession(): Promise<Innertube> {
  const s = loadSettings();
  const { hl, gl } = localePref();
  // locale is part of the session identity: a stale session would keep serving
  // titles in the previous language after the setting changed
  const key = `${s.cookieSource}:${s.browser}:${s.cookieProfile}:${hl}-${gl}`;
  if (!itSession || key !== sessionKey) {
    sessionKey = key;
    itSession = (async () => {
      const { Innertube, UniversalCache, Platform } = await import("youtubei.js");
      installEvalShim(Platform);
      let cookie: string | undefined;
      try {
        const cookies = await resolveCookies(s.cookieSource, s.browser, s.cookieProfile);
        const yt = cookies.filter(
          (c) => c.domain.includes("youtube.com") || c.domain.includes(".google.com"));
        if (yt.length) cookie = yt.map((c) => `${c.name}=${c.value}`).join("; ");
      } catch { /* anonymous session */ }
      const pot = await poTokenSession();
      // Same locale the browse/search module sends. Without it youtubei.js
      // picks its own default, so a track's title could differ between the
      // list it was browsed in and the stream that played it.
      const { hl, gl } = localePref();
      return Innertube.create({
        cache: new UniversalCache(true, join(dataDir(), "yjs-cache")),
        cookie,
        lang: hl,
        location: gl,
        ...(pot ? { po_token: await pot.mint(pot.visitorData), visitor_data: pot.visitorData } : {}),
      });
    })();
  }
  return itSession;
}

/** Swap the URL's session-bound `pot=` for one bound to this video. */
function withVideoPot(url: string, token: string): string {
  const stripped = url.replace(/([?&])pot=[^&]*/, "$1");
  return `${stripped}${stripped.includes("?") ? "&" : "?"}pot=${token}`;
}

async function innertubeStream(videoId: string): Promise<CachedStream | null> {
  // Every `return null` says why. A silent decline here reads downstream as
  // "yt-dlp is broken", with no trace that the fast path gave up.
  const decline = (why: string) => {
    console.error(`[streams] innertube declined ${videoId}: ${why}`);
    return null;
  };
  const pot = await poTokenSession();
  if (!pot) return decline("no PO token session");   // every URL would be walled
  const yt = await getSession();
  const info = await yt.getBasicInfo(videoId, { client: "YTMUSIC" });
  const status = info.playability_status?.status;
  if (status !== "OK")
    return decline(`playability ${status ?? "unknown"}`
      + (info.playability_status?.reason ? ` (${info.playability_status.reason})` : ""));
  const fmts = (info.streaming_data?.adaptive_formats ?? [])
    .filter((f: any) => f.has_audio && !f.has_video);
  const pick = fmts.find((f: any) => f.itag === 251)
    ?? fmts.find((f: any) => f.itag === 140) ?? fmts[0];
  if (!pick) return decline("no audio-only format");
  const deciphered = await pick.decipher(yt.session.player);
  if (typeof deciphered !== "string" || !deciphered.startsWith("http"))
    return decline("decipher produced no url");
  const url = withVideoPot(deciphered, await pot.mint(videoId));

  // Verify at the FAR END, not the start. A walled URL still serves its first
  // bytes happily, so a `bytes=0-1` probe passes on a
  // stream that dies a minute in.
  const clen = Number(/[?&]clen=(\d+)/.exec(url)?.[1] ?? 0);
  if (!clen) return decline("url carries no clen");
  const probe = await fetch(url, { headers: { Range: `bytes=${clen - 1}-${clen - 1}` } })
    .catch(() => null);
  probe?.body?.cancel?.();
  if (!probe || probe.status !== 206) {
    return decline(`url walled (${probe?.status ?? "no response"})`);
  }

  const b = info.basic_info;
  return {
    videoId,
    raw: url,
    headers: undefined,
    title: b.title ?? "",
    channel: b.author ?? "",
    duration: b.duration ?? 0,
    thumbnail: b.thumbnail?.[0]?.url ?? `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`,
    expiresAt: cacheExpiryMs(url),
  };
}

// Playlist/radio listing via youtubei.js. yt-dlp needs a full subprocess for
// what is one API call: measured 2543ms -> 484ms for a playlist and 4328ms ->
// 795ms for a radio seed. This runs BEFORE the user can even click a track.
function hmsToSeconds(t: string): number {
  const parts = t.split(":").map((x) => parseInt(x, 10));
  if (parts.some(Number.isNaN)) return 0;
  return parts.reduce((acc, n) => acc * 60 + n, 0);
}

function flatFromInnertube(v: any): FlatTrack | null {
  // YouTube now returns LockupView for playlist and watch-next items: the id
  // lives in content_id, the duration only in a thumbnail badge ("3:55").
  // Classic shapes (id / video_id) are still handled for older renderers.
  const id = v?.content_id ?? v?.id ?? v?.video_id;
  if (typeof id !== "string" || id.length !== 11) return null;

  const md = v?.metadata;
  const title = md?.title?.text ?? v?.title?.text ?? v?.title?.runs?.[0]?.text ?? "";

  let channel = v?.author?.name ?? v?.author?.text ?? "";
  let views = "";
  let age = "";
  // LockupMetadataView.metadata is a ContentMetadataView: one row carries the
  // channel, another "752M views" and "2 years ago". All three are worth
  // keeping — a row showing only a title and a channel is the one that looks
  // empty on a wide window.
  for (const row of md?.metadata?.metadata_rows ?? []) {
    for (const part of row?.metadata_parts ?? []) {
      const t = part?.text?.text;
      if (typeof t !== "string" || !t) continue;
      if (/^[\d.,]+[KMB]?\s+views?$/i.test(t)) views = t;
      else if (/ago$/.test(t)) age = t;
      else if (!channel) channel = t;
    }
  }

  let duration = v?.duration?.seconds ?? v?.duration_seconds ?? 0;
  if (!duration) {
    for (const ov of v?.content_image?.overlays ?? []) {
      for (const b of ov?.badges ?? []) {
        if (typeof b?.text === "string" && /^\d+(:\d\d)+$/.test(b.text)) {
          duration = hmsToSeconds(b.text);
          break;
        }
      }
      if (duration) break;
    }
  }

  const imgs = v?.content_image?.image ?? v?.thumbnails ?? v?.thumbnail ?? [];
  return {
    id, title, channel, duration, views, age,
    thumbnail: imgs[0]?.url ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
  };
}

// ---- paged listing -------------------------------------------------------
// Continuation state lives in youtubei.js objects and cannot be serialised, so
// a session holds it server-side behind an opaque cursor. Sources continue by:
//   playlist  -> page.getContinuation()
//   watchnext -> info.getWatchNextContinuation()        (seeded mixes)
//   panel     -> re-query /next from the last video id  (seedless RD mixes;
//                no continuation token, but isInfinite)
type ListKind = "playlist" | "watchnext" | "panel";

interface ListSession {
  kind: ListKind;
  playlistId: string;
  page: any;          // playlist page | VideoInfo | last panel object
  lastId: string;     // panel only: the id to advance from
  seen: Set<string>;
  exhausted: boolean;
  at: number;
}

const listSessions = new Map<string, ListSession>();
const LIST_SESSION_TTL_MS = 30 * 60 * 1000;
const LIST_SESSION_MAX = 16;

function reapListSessions(): void {
  const cutoff = Date.now() - LIST_SESSION_TTL_MS;
  for (const [k, v] of listSessions) if (v.at < cutoff) listSessions.delete(k);
  // Evict least recently used, not oldest-inserted: `at` is refreshed on every
  // moreList() call, so the list being actively scrolled survives. Map order is
  // insertion order, which would have evicted exactly the wrong session.
  while (listSessions.size > LIST_SESSION_MAX) {
    let lru = "";
    let lruAt = Infinity;
    for (const [k, v] of listSessions) if (v.at < lruAt) { lruAt = v.at; lru = k; }
    if (!lru) break;
    listSessions.delete(lru);
  }
}

function pushUnique(s: ListSession, rows: (FlatTrack | null)[], out: FlatTrack[]): number {
  let added = 0;
  for (const f of rows) {
    if (f && !s.seen.has(f.id)) { s.seen.add(f.id); out.push(f); added++; }
  }
  return added;
}

function panelOf(data: any): any {
  const found: { p: any } = { p: null };
  const walk = (o: any): void => {
    if (!o || typeof o !== "object" || found.p) return;
    if (Array.isArray(o.contents) && o.contents.some((c: any) => c?.playlistPanelVideoRenderer)) {
      found.p = o;
      return;
    }
    for (const v of Object.values(o)) walk(v);
  };
  walk(data);
  return found.p;
}

function collectFrom(s: ListSession, out: FlatTrack[]): number {
  if (s.kind === "playlist") return pushUnique(s, (s.page?.items ?? []).map(flatFromInnertube), out);
  if (s.kind === "watchnext") return pushUnique(s, (s.page?.watch_next_feed ?? []).map(flatFromInnertube), out);
  const items = (s.page?.contents ?? []).map((c: any) => flatFromPanelItem(c?.playlistPanelVideoRenderer));
  const n = pushUnique(s, items, out);
  const ids = (s.page?.contents ?? [])
    .map((c: any) => c?.playlistPanelVideoRenderer?.videoId).filter(Boolean);
  if (ids.length) s.lastId = ids[ids.length - 1];
  return n;
}

async function advanceSession(s: ListSession): Promise<void> {
  if (s.kind === "playlist") {
    if (!s.page?.has_continuation) { s.exhausted = true; return; }
    s.page = await s.page.getContinuation();
  } else if (s.kind === "watchnext") {
    s.page = await s.page.getWatchNextContinuation();
  } else {
    const yt = await getSession();
    const res: any = await yt.actions.execute("/next",
      { playlistId: s.playlistId, videoId: s.lastId, client: "WEB" });
    s.page = panelOf(res?.data);
    if (!s.page) s.exhausted = true;
  }
}

export interface OpenedList { title: string; tracks: FlatTrack[]; cursor: string; api: string }

/** First page of a list plus a cursor for more, or null if innertube can't. */
async function openList(playlistId: string, want: number): Promise<OpenedList | null> {
  const t0 = Date.now();
  const yt = await getSession();
  reapListSessions();

  const mk = (kind: ListKind, page: any, seed: string): ListSession =>
    ({ kind, playlistId, page, lastId: "", seen: new Set(seed ? [seed] : []),
       exhausted: false, at: Date.now() });

  let s: ListSession | null = null;
  let title = "";
  const seed = mixSeedVideoId(playlistId);
  if (seed) {
    // The mix's own queue first: watch_next_feed is personalised
    // recommendations beside the video, which put non-music a few rows in.
    // /next with the playlist id returns playlistPanelVideoRenderer rows (the
    // queue), paged by the "panel" session. The sidebar is the fallback for a
    // seeded mix that serves no panel.
    try {
      const res: any = await yt.actions.execute("/next", { playlistId, client: "WEB" });
      const panel = panelOf(res?.data);
      if (panel) s = mk("panel", panel, "");
    } catch (e) {
      console.error(`[streams] mix panel failed for ${playlistId}: ${String(e).split("\n")[0]}`);
    }
    if (!s) s = mk("watchnext", await yt.getInfo(seed), seed);
  } else {
    try {
      const page: any = await yt.getPlaylist(playlistId);
      s = mk("playlist", page, "");
      title = page?.info?.title ?? "";
    } catch (e) {
      console.error(`[streams] getPlaylist rejected ${playlistId}: ${String(e).split("\n")[0]}`);
      if (playlistId.startsWith("RD")) {
        const res: any = await yt.actions.execute("/next", { playlistId, client: "WEB" });
        const panel = panelOf(res?.data);
        if (panel) s = mk("panel", panel, "");
      }
    }
  }
  if (!s) return null;

  const tracks: FlatTrack[] = [];
  collectFrom(s, tracks);
  let guard = 0;
  while (tracks.length < want && !s.exhausted && guard++ < RADIO_MAX_PAGES) {
    try { await advanceSession(s); } catch { s.exhausted = true; break; }
    if (collectFrom(s, tracks) === 0) s.exhausted = true;
  }
  if (!tracks.length) return null;

  let cursor = "";
  if (!s.exhausted) { cursor = randomUUID(); listSessions.set(cursor, s); }
  const api = s.kind === "playlist" ? "getPlaylist"
            : s.kind === "watchnext" ? "watch-next(getInfo)" : "next-panel";
  console.error(`[list] ${playlistId} api=${api} tracks=${tracks.length} want=${want} ` +
                `more=${cursor ? "yes" : "no"} in ${Date.now() - t0}ms`);
  return { title, tracks, cursor, api };
}

/** One upstream page, not a target count: accumulating costs ~2.3s per top-up
 *  and the caller tops up again. Repeats only while a page yields nothing new
 *  (watch-next re-serves held ids), which is not the end of the feed.
 *  Returns an empty cursor when the source runs dry. */
export async function moreList(cursor: string, _want?: number) {
  const s = listSessions.get(cursor);
  if (!s) {
    console.error(`[list] MORE cursor unknown (expired or evicted); ` +
                  `${listSessions.size} live session(s)`);
    return { ok: false as const, error: "expired" };
  }
  const t0 = Date.now();
  s.at = Date.now();
  const tracks: FlatTrack[] = [];
  let guard = 0;
  let dud = 0;
  while (tracks.length === 0 && !s.exhausted && guard++ < RADIO_MAX_PAGES) {
    try { await advanceSession(s); } catch { s.exhausted = true; break; }
    if (collectFrom(s, tracks) === 0) { if (++dud >= 2) s.exhausted = true; }
  }
  if (s.exhausted) listSessions.delete(cursor);
  console.error(`[list] ${s.playlistId} api=${s.kind} MORE tracks=${tracks.length} ` +
                `more=${s.exhausted ? "no" : "yes"} in ${Date.now() - t0}ms`);
  return { ok: true as const, tracks, cursor: s.exhausted ? "" : cursor };
}

/** Radio seed -> up-next feed. Returns null when this cannot serve it. */
const RADIO_TARGET = 50;      // what the yt-dlp path returned (--playlist-items 1:50)
const RADIO_MAX_PAGES = 4;   // guard against a feed that never stops paging
const MIX_FIRST_PAGE = 20;   // clicking a mix: return one page, refill does the rest
// First page for the paged list view: ONE upstream page, nothing more. Asking
// for 60 costs 2-3 watch-next/panel round trips before anything appears (an
// open of ~3.4s instead of ~1s). Scroll pagination fills the rest, so the
// only thing that matters here is time-to-first-rows.
const LIST_FIRST_PAGE = 1;

/** Video id a mix is seeded from, or "" for mix types that carry none. */
function mixSeedVideoId(playlistId: string): string {
  const seeded = (s: string) => (s.length === 11 ? s : "");
  if (playlistId.startsWith("RDAMVM")) return seeded(playlistId.slice(6));
  if (playlistId.startsWith("RDMM")) return seeded(playlistId.slice(4));   // "My Mix"
  // RDAMPL*/RDCLAK*/RDGM* are playlist- or cluster-seeded: no video id.
  if (/^RD(AMPL|CLAK|GM|EM|TM)/.test(playlistId)) return "";
  if (playlistId.startsWith("RD")) return seeded(playlistId.slice(2));
  return "";
}

/** Rows from the watch /next playlist panel — the only innertube route that
 *  serves seedless mixes (RDGM*). getPlaylist calls those "unviewable" and the
 *  yt-dlp fallback costs ~4.6-5s; this returns a full panel in ~1.5s. */
function flatFromPanelItem(v: any): FlatTrack | null {
  const id = v?.videoId;
  if (typeof id !== "string" || id.length !== 11) return null;
  const thumbs = v?.thumbnail?.thumbnails ?? [];
  return {
    id,
    title: v?.title?.simpleText ?? v?.title?.runs?.[0]?.text ?? "",
    channel: v?.shortBylineText?.runs?.[0]?.text ?? v?.longBylineText?.runs?.[0]?.text ?? "",
    duration: hmsToSeconds(v?.lengthText?.simpleText ?? ""),
    thumbnail: thumbs[thumbs.length - 1]?.url ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
  };
}

async function innertubeMixPanel(playlistId: string): Promise<FlatTrack[] | null> {
  const t0 = Date.now();
  const yt = await getSession();
  const res: any = await yt.actions.execute("/next", { playlistId, client: "WEB" });
  // box the result: assigning inside the closure defeats TS narrowing
  const found: { panel: any[] | null } = { panel: null };
  const walk = (o: any): void => {
    if (!o || typeof o !== "object" || found.panel) return;
    if (Array.isArray(o.contents) && o.contents.some((c: any) => c?.playlistPanelVideoRenderer)) {
      found.panel = o.contents;
      return;
    }
    for (const v of Object.values(o)) walk(v);
  };
  walk(res?.data);
  if (!found.panel) return null;
  const out: FlatTrack[] = [];
  for (const it of found.panel) {
    const f = flatFromPanelItem(it?.playlistPanelVideoRenderer);
    if (f) out.push(f);
  }
  if (!out.length) return null;
  console.error(`[list] ${playlistId} api=next-panel tracks=${out.length} in ${Date.now() - t0}ms`);
  return out;
}

// Clicking a mix calls yt/getPlaylistTracks (show the queue) then radio/start
// (play it). Watch-next is not deterministic, so without this cache playback
// would start from an order the UI never showed. It also saves ~2.5s.
interface RadioList {
  tracks: FlatTrack[];
  seen: Set<string>;
  info: any;           // live VideoInfo, kept so later calls can page further
  at: number;
  exhausted: boolean;
}
const radioListCache = new Map<string, RadioList>();
const RADIO_LIST_TTL_MS = 5 * 60 * 1000;


async function innertubeRadio(
  playlistId: string, target: number = RADIO_TARGET,
): Promise<FlatTrack[] | null> {
  const t0 = Date.now();
  let pagesFetched = 0;
  let entry = radioListCache.get(playlistId);
  const wasCached = !!entry;
  if (entry && Date.now() - entry.at > RADIO_LIST_TTL_MS) {
    radioListCache.delete(playlistId);
    entry = undefined;
  }

  if (!entry) {
    const seed = mixSeedVideoId(playlistId);
    if (seed.length !== 11) return null;
    const yt = await getSession();
    entry = { tracks: [], seen: new Set([seed]), info: await yt.getInfo(seed),
              at: Date.now(), exhausted: false };
    collectRadioPage(entry);
    if (!entry.tracks.length) return null;
    radioListCache.set(playlistId, entry);
    while (radioListCache.size > 16) radioListCache.delete(radioListCache.keys().next().value as string);
  }

  // Extend the SAME list rather than refetching. A second fetch of the
  // watch-next feed returns a different order, which would make the queue the
  // UI shows disagree with the track that actually plays.
  for (let page = 1; page < RADIO_MAX_PAGES && entry.tracks.length < target && !entry.exhausted; page++) {
    try {
      entry.info = await entry.info.getWatchNextContinuation();
      pagesFetched++;
    } catch {
      entry.exhausted = true;
      break;
    }
    if (collectRadioPage(entry) === 0) entry.exhausted = true;
  }
  const out = entry.tracks.slice(0, target);
  console.error(
    `[list] ${playlistId} api=watch-next(getInfo) tracks=${out.length} want=${target} ` +
    `pool=${entry.tracks.length} pages=${wasCached ? 0 : 1}+${pagesFetched} ` +
    `${entry.exhausted ? "feedExhausted " : ""}${wasCached ? "cached " : ""}in ${Date.now() - t0}ms`);
  return out;
}

/** Append this page's items to the list, skipping ones already present. */
function collectRadioPage(entry: RadioList): number {
  let added = 0;
  for (const v of entry.info?.watch_next_feed ?? []) {
    const f = flatFromInnertube(v);
    if (f && !entry.seen.has(f.id)) { entry.seen.add(f.id); entry.tracks.push(f); added++; }
  }
  return added;
}

const YTDLP_COMMON = ["--js-runtimes", "node", "--no-warnings"];

// ---- stream client gating (PO-token era) --------------------------------
// On ANDROID_VR YouTube serves only the first ~27% of a file (~60s) and 403s
// past it; the wall is per client, not a chunk-size limit. web_music serves
// whole files; web_embedded covers what web_music refuses (non-music videos).
// Both give opus itag 251 with ranged seeks and need a real gvs PO token
// (src/potoken.ts). null = yt-dlp's default client, tried first: what it
// resolves to changes (walled ANDROID_VR or fully readable VISIONOS), so the
// URL's tail is verified and the explicit clients are the fallback.
const STREAM_CLIENTS: readonly (string | null)[] = [null, "web_music", "web_embedded"];

// These clients need an identity, or googlevideo 403s every ranged fetch (and
// returns an empty body for a plain GET): cookies, else a visitor id fetched
// once per process. "Has cookies" means the file has entries: an empty guest
// profile writes a header-only file yt-dlp accepts with no identity. The
// token must be gvs only; a `player` PO token makes format extraction fail.
function cookieFileHasEntries(path: string): boolean {
  try {
    return readFileSync(path, "utf8")
      .split("\n")
      .some((l) => l.trim() !== "" && !l.startsWith("#"));
  } catch {
    return false;
  }
}

/** True when the cookie args will actually carry an identity to googlevideo. */
function cookiesCarryIdentity(cookies: string[]): boolean {
  if (cookies[0] === "--cookies-from-browser") return true;
  if (cookies[0] === "--cookies") return cookieFileHasEntries(cookies[1]);
  return false;
}

let visitorData: string | null = null;

async function guestVisitorData(): Promise<string> {
  if (visitorData === null) {
    try {
      const res = await fetch("https://www.youtube.com", {
        headers: { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" },
      });
      const m = /"visitorData":"([^"]+)"/.exec(await res.text());
      visitorData = m ? (JSON.parse(`"${m[1]}"`) as string) : "";
    } catch {
      visitorData = "";
    }
  }
  return visitorData;
}

async function streamClientArgs(
  client: string | null, haveIdentity: boolean, pot: PoToken | null,
): Promise<string[]> {
  // Default client: let yt-dlp choose, and do not name a po_token client
  // (the token is keyed by client name, which we do not know here). It works
  // without one; if that stops being true the tail probe rejects it.
  if (client === null) {
    if (haveIdentity) return [];
    const vd = await guestVisitorData();
    return vd ? ["--extractor-args", `youtube:visitor_data=${vd}`] : [];
  }
  const parts = [`player_client=${client}`];
  if (pot) {
    // The token is bound to the identity it was minted against, so that same
    // visitor_data has to ride along or googlevideo rejects the pairing.
    parts.push(`po_token=${client}.gvs+${pot.token}`, `visitor_data=${pot.visitorData}`);
  } else if (!haveIdentity) {
    const vd = await guestVisitorData();
    if (vd) parts.push(`visitor_data=${vd}`);
  }
  return ["--extractor-args", `youtube:${parts.join(";")}`];
}

export async function cookieArgs(): Promise<string[]> {
  const s = loadSettings();
  switch (s.cookieSource) {
    case "browser":
      return ["--cookies-from-browser", s.browser];
    case "guest":
      return ["--cookies", await writeNetscapeCookieFile(s.cookieProfile)];
    case "none":
      return [];
  }
}

/** After yt-dlp runs in guest mode, merge any new cookies back into the store. */
export function syncYtDlpCookies(): void {
  const s = loadSettings();
  if (s.cookieSource !== "guest") return;
  try {
    const cookies = parseNetscapeCookieFile(cookiesTxtPath(s.cookieProfile));
    if (cookies.length > 0) mergeGuestCookies(s.cookieProfile, cookies);
  } catch { /* ignore */ }
}

export interface StreamResult {
  ok: true; url: string; title: string; channel: string; duration: number; thumbnail: string;
}
export interface StreamError { ok: false; error: string }

// Resolved URLs are reusable until the CDN's own `expire=`, so a replay or a
// prefetch-then-click costs nothing instead of another ~4s yt-dlp spawn. The
// RAW url is cached, not the relay URL: relay ids are UUIDs evicted after 64
// entries, so a stale one 404s. Re-wrapping on each hit is free.
interface CachedStream {
  videoId: string;
  raw: string;
  headers?: Record<string, string>;
  title: string; channel: string; duration: number; thumbnail: string;
  expiresAt: number;
}
const streamCache = new Map<string, CachedStream>();
const EXPIRY_MARGIN_MS = 5 * 60 * 1000;

function cacheExpiryMs(rawUrl: string): number {
  const m = /[?&]expire=(\d+)/.exec(rawUrl);
  // No expire= means unknown lifetime — keep it briefly so a prefetch still
  // pays off, rather than trusting it for hours.
  if (!m) return Date.now() + 5 * 60 * 1000;
  return parseInt(m[1]) * 1000 - EXPIRY_MARGIN_MS;
}

async function toStreamResult(c: CachedStream): Promise<StreamResult> {
  return {
    ok: true,
    url: needsStreamRelay(c.raw)
      ? await relayUrl(c.raw, c.headers, () => invalidateStreamCache(c.videoId))
      : c.raw,
    title: c.title, channel: c.channel, duration: c.duration, thumbnail: c.thumbnail,
  };
}

/** Drop a cached URL — call when a stream 403s so the retry re-resolves. */
export function invalidateStreamCache(videoId: string): void {
  if (streamCache.delete(videoId)) console.error(`[streams] dropped dead URL for ${videoId}`);
}

async function resolveWithClient(
  videoId: string, client: string | null, cookies: string[], haveIdentity: boolean,
  pot: PoToken | null,
): Promise<CachedStream> {
  const { stdout } = await execFileAsync(
    YTDLP(),
    [...cookies, ...(await streamClientArgs(client, haveIdentity, pot)),
     ...YTDLP_COMMON, "-f", "bestaudio/best", "-j",
     `https://www.youtube.com/watch?v=${videoId}`],
    // maxBuffer as in every sibling call: `-j` output with a large caption
    // list exceeds Node's 1MB default and execFile kills the process. This
    // fallback runs only after the fast path already failed.
    { timeout: 30000, maxBuffer: 10 * 1024 * 1024 },
  );
  const data = JSON.parse(stdout);
  const raw = typeof data.url === "string" ? data.url : "";
  return {
    videoId,
    raw,
    headers: ytdlpHttpHeaders(data),
    title: data.title,
    channel: data.channel || data.uploader || "",
    duration: data.duration,
    thumbnail: data.thumbnail,
    expiresAt: cacheExpiryMs(raw),
  };
}

/** A walled URL serves its first bytes and 403s later, so probe the LAST byte.
 *  Without this, web_embedded's dead URLs would be returned AND cached, and
 *  the player would burn three decks on them before giving up. */
async function tailIsReadable(raw: string, headers?: Record<string, string>): Promise<boolean> {
  const clen = Number(/[?&]clen=(\d+)/.exec(raw)?.[1] ?? 0);
  if (!clen) return true;   // unknown length: nothing to check against
  try {
    const r = await fetch(raw, {
      headers: { Range: `bytes=${clen - 1}-${clen - 1}`, ...(headers || {}) },
    });
    r.body?.cancel?.();
    return r.status === 206;
  } catch {
    return true;   // network hiccup — don't reject a possibly-fine URL
  }
}

export async function runYtdlpStream(videoId: string): Promise<StreamResult> {
  const hit = streamCache.get(videoId);
  if (hit && Date.now() < hit.expiresAt) {
    console.error(`[streams] cache hit for ${videoId}`);
    return toStreamResult(hit);
  }
  if (hit) streamCache.delete(videoId);

  const cookies = await cookieArgs();
  const haveIdentity = cookiesCarryIdentity(cookies);
  const pot = await mintPoToken(videoId);

  // Tried in order, not raced: racing cost ~770ms on every cold music resolve
  // to save ~3.3s on rare non-music videos, and web_embedded resolves music
  // to a URL delivering 0 bytes, so it must never beat web_music.
  let lastErr: unknown;
  for (const client of STREAM_CLIENTS) {
    try {
      const resolved = await resolveWithClient(videoId, client, cookies, haveIdentity, pot);
      if (needsStreamRelay(resolved.raw) && !(await tailIsReadable(resolved.raw, resolved.headers))) {
        console.error(`[streams] ${client ?? "default"} returned a walled URL for ${videoId} — trying next`);
        lastErr = new Error(`${client} URL is not fully readable`);
        continue;
      }
      streamCache.set(videoId, resolved);
      // cookie writeback is not something the player is waiting on
      setImmediate(syncYtDlpCookies);
      return toStreamResult(resolved);
    } catch (err) {
      lastErr = err;
      const msg = String((err as { stderr?: string })?.stderr || err).split("\n")[0];
      console.error(`[streams] ${client ?? "default"} failed for ${videoId}: ${msg}`);
    }
  }
  throw lastErr;
}

// Report a stale-looking failure to the UI at most once per session: the fix
// is a yt-dlp channel change, which is the user's call, not something to do
// behind their back.
let staleNotified = false;
function maybeReportStale(message: string): void {
  if (staleNotified || !looksStale(message)) return;
  if (ytdlpChannel() === "nightly") return;   // already on the faster channel
  staleNotified = true;
  console.error(`[ytdlp] extraction looks stale on the stable channel: ${message.slice(0, 90)}`);
  notify("ytdlp/stale", { message: message.slice(0, 200), channel: "stable" });
}

export async function fetchStreamUrl(videoId: string): Promise<StreamResult | StreamError> {
  try {
    // Local-first: downloaded library tracks play from disk.
    const localUrl = getDownloadedUrl(videoId);
    if (localUrl) {
      const meta = getTrackMetadata(videoId);
      return {
        ok: true,
        url: localUrl,
        title: meta?.title || "",
        channel: meta?.channel || "",
        duration: meta?.duration || 0,
        thumbnail: meta?.thumbnail || "",
      };
    }
    // Cache covers BOTH resolvers, so a prefetch or replay skips them entirely.
    const hit = streamCache.get(videoId);
    if (hit && Date.now() < hit.expiresAt) {
      console.error(`[streams] cache hit for ${videoId}`);
      return toStreamResult(hit);
    }
    if (FAST_STREAMS) {
      const tf = Date.now();
      try {
        const fast = await innertubeStream(videoId);
        if (fast) {
          streamCache.set(videoId, fast);
          console.error(`[streams] innertube resolved ${videoId} in ${Date.now() - tf}ms`);
          return toStreamResult(fast);
        }
      } catch (e) {
        console.error(`[streams] innertube failed: ${String(e).split("\n")[0]}`);
      }
    }
    const t0 = Date.now();
    const res = await runYtdlpStream(videoId);
    console.error(`[streams] yt-dlp resolved ${videoId} in ${Date.now() - t0}ms`);
    return res;
  } catch (err: any) {
    const msg = err?.stderr || String(err);
    if (/name resolution|timed? ?out|temporarily unavailable|network/i.test(msg)) {
      try {
        return await runYtdlpStream(videoId);   // one retry on transient network errors
      } catch (retryErr: any) {
        const retryMsg = retryErr?.stderr || String(retryErr);
        const clean = retryMsg.replace(/^ERROR:\s*\[youtube\]\s*\S+:\s*/i, "").split("\n")[0];
        return { ok: false, error: clean || "Network error" };
      }
    }
    const clean = msg.replace(/^ERROR:\s*\[youtube\]\s*\S+:\s*/i, "").split("\n")[0];
    maybeReportStale(msg);
    return { ok: false, error: clean || "Failed to get stream" };
  }
}

/** Homepage recommended feed via yt-dlp flat-playlist. */
export async function fetchRecommendedTracks(count: number = 30): Promise<FlatTrack[]> {
  const { stdout } = await execFileAsync(
    YTDLP(),
    [...(await cookieArgs()), "--flat-playlist", "-j", "--no-warnings", "--no-cache-dir",
     "--playlist-items", `1:${count}`, "https://www.youtube.com/feed/recommended"],
    { timeout: 30000, maxBuffer: 10 * 1024 * 1024 },
  );
  syncYtDlpCookies();
  return stdout.trim().split("\n").filter(Boolean).map((line) => {
    const d = JSON.parse(line);
    return {
      id: d.id,
      title: d.title || "",
      channel: d.channel || d.uploader || "",
      duration: d.duration ?? 0,
      views: d.view_count ? compactCount(d.view_count) + " views" : "",
      thumbnail: d.thumbnails?.[d.thumbnails.length - 1]?.url || "",
    };
  });
}

interface FlatTrack {
  id: string; title: string; channel: string; duration: number; thumbnail: string;
  // "752M views" / "2 years ago": present in every lockup
  views?: string; age?: string;
}

/** 752341 -> "752K", the way the renderers already write it. */
function compactCount(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "";
  if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1).replace(/\.0$/, "") + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace(/\.0$/, "") + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1).replace(/\.0$/, "") + "K";
  return String(n);
}

function parseFlatPlaylist(stdout: string): { title: string; tracks: FlatTrack[] } {
  let playlistTitle = "";
  const tracks = stdout.trim().split("\n").filter(Boolean).map((line) => {
    const d = JSON.parse(line);
    if (!playlistTitle && d.playlist_title) playlistTitle = d.playlist_title;
    return {
      id: d.id,
      title: d.title || "",
      channel: d.channel || d.uploader || "",
      duration: d.duration ?? 0,
      thumbnail: d.thumbnails?.[d.thumbnails.length - 1]?.url || "",
    };
  });
  return { title: playlistTitle, tracks };
}

export async function fetchPlaylistTracks(playlistId: string) {
  if (FAST_STREAMS) {
    try {
      // One paged source for all three shapes (seeded mix -> watch-next,
      // real playlist -> getPlaylist, seedless mix -> /next panel). Returns a
      // cursor so the view can page on scroll instead of being truncated.
      const opened = await openList(playlistId, LIST_FIRST_PAGE);
      if (opened) {
        return { ok: true as const, title: opened.title, tracks: opened.tracks,
                 cursor: opened.cursor };
      }
    } catch (e) {
      console.error(`[streams] innertube list failed: ${String(e).split("\n")[0]}`);
    }
  }
  const ytT0 = Date.now();
  try {
    const isMix = playlistId.startsWith("RD");
    let url: string;
    if (isMix) {
      const seedId = playlistId.startsWith("RDAMPL") ? "" : playlistId.slice(2);
      url = seedId
        ? `https://www.youtube.com/watch?v=${seedId}&list=${playlistId}`
        : `https://www.youtube.com/playlist?list=${playlistId}`;
    } else {
      url = `https://music.youtube.com/playlist?list=${playlistId}`;
    }
    const { stdout } = await execFileAsync(
      YTDLP(),
      [...(await cookieArgs()), ...YTDLP_COMMON, "--flat-playlist", "-j",
       ...(isMix ? ["--playlist-items", "1:50"] : []), url],
      { timeout: 30000, maxBuffer: 10 * 1024 * 1024 },
    );
    syncYtDlpCookies();
    const { title, tracks } = parseFlatPlaylist(stdout);
    console.error(`[list] ${playlistId} api=yt-dlp tracks=${tracks.length} in ${Date.now() - ytT0}ms`);
    return { ok: true as const, title, tracks };
  } catch (err) {
    return { ok: false as const, error: String(err) };
  }
}

// --- Song radio (buffered, dedup by seen-set) ---

let radioBuffer: FlatTrack[] = [];
let radioSeen = new Set<string>();
let radioFetching = false;
let radioFetchPromise: Promise<void> | null = null;
let radioRefillTimer: ReturnType<typeof setTimeout> | null = null;
let radioSeedId = "";

async function fetchRadioTracks(
  playlistId: string, target: number = RADIO_TARGET,
): Promise<FlatTrack[]> {
  if (FAST_STREAMS) {
    const t0 = Date.now();
    try {
      // The panel is the radio: /next with the playlist id returns the mix's
      // queue. watch_next_feed is the related-videos sidebar, which would put
      // non-music two rows into a song radio.
      const panel = await innertubeMixPanel(playlistId);
      if (panel) {
        console.error(`[streams] mix panel ${playlistId} (${panel.length}) in ${Date.now() - t0}ms`);
        return panel;
      }
      // No panel (some seedless mixes): the sidebar is all there is.
      const fast = await innertubeRadio(playlistId, target);
      if (fast) {
        console.error(`[streams] innertube radio ${playlistId} (${fast.length}) in ${Date.now() - t0}ms`);
        return fast;
      }
    } catch (e) {
      console.error(`[streams] innertube radio failed: ${String(e).split("\n")[0]}`);
    }
  }
  let url: string;
  if (playlistId.startsWith("RDAMVM")) {
    const videoId = playlistId.slice(6);
    url = `https://www.youtube.com/watch?v=${videoId}&list=${playlistId}&start_radio=1`;
  } else {
    const seedId = playlistId.startsWith("RDAMPL") ? "" : playlistId.slice(2);
    url = seedId
      ? `https://www.youtube.com/watch?v=${seedId}&list=${playlistId}`
      : `https://www.youtube.com/playlist?list=${playlistId}`;
  }
  const { stdout } = await execFileAsync(
    YTDLP(),
    [...(await cookieArgs()), ...YTDLP_COMMON, "--flat-playlist", "-j",
     "--no-cache-dir", "--playlist-items", "1:50", url],
    { timeout: 30000, maxBuffer: 10 * 1024 * 1024 },
  );
  syncYtDlpCookies();
  return parseFlatPlaylist(stdout).tracks;
}

function refillRadio(seedId: string): void {
  radioFetching = true;
  radioFetchPromise = fetchRadioTracks("RDAMVM" + seedId)
    .then((newTracks) => {
      const fresh = newTracks.filter((t) => !radioSeen.has(t.id));
      for (const t of fresh) radioSeen.add(t.id);
      radioBuffer.push(...fresh);
    })
    .catch(() => {})
    .finally(() => { radioFetching = false; radioFetchPromise = null; });
}

export async function startSongRadio(playlistId: string, startIndex?: number) {
  try {
    // Only the first page is needed to start playing, and yt/getPlaylistTracks
    // has usually cached it (paging to 50 costs ~2.2s). The rest is appended to
    // the same cached list in the background, so the queue never disagrees
    // with what was shown.
    const allTracks = await fetchRadioTracks(playlistId, MIX_FIRST_PAGE);
    if (allTracks.length === 0) return { ok: false as const, error: "No tracks found" };
    // Return the FULL list and say where to start, rather than slicing: a
    // slice would drop the rows above the clicked one out of the queue, so
    // they could not be seen or gone back to.
    const idx = Math.min(Math.max(startIndex ?? 0, 0), allTracks.length - 1);
    const tracks = allTracks;
    radioSeen = new Set(allTracks.map((t) => t.id));
    radioBuffer = [];
    // Deferred: refilling spawns a second yt-dlp that would compete with the
    // resolve for the track the user is about to click. nextRadioTrack()
    // pulls it forward if the buffer is actually needed sooner.
    radioSeedId = tracks[tracks.length - 1].id;
    radioRefillTimer = setTimeout(() => { radioRefillTimer = null; refillRadio(radioSeedId); }, 4000);
    // background: extend the cached mix list to full length, off the critical path
    void fetchRadioTracks(playlistId, RADIO_TARGET).catch(() => {});
    return { ok: true as const, tracks, startIndex: idx };
  } catch (err) {
    return { ok: false as const, error: String(err) };
  }
}

/** Several radio tracks at once. Extended ONE track per advance, an endless
 *  mix would always look one song from running out. */
export async function nextRadioBatch(count: number) {
  const tracks: FlatTrack[] = [];
  for (let i = 0; i < Math.max(1, count); i++) {
    const r = await nextRadioTrack();
    if (!r.ok || !r.track) break;
    tracks.push(r.track);
  }
  return { ok: tracks.length > 0, tracks, remaining: radioBuffer.length };
}

export async function nextRadioTrack() {
  // needed before the deferred timer fired — start now instead of waiting
  if (radioBuffer.length === 0 && !radioFetchPromise && radioRefillTimer) {
    clearTimeout(radioRefillTimer);
    radioRefillTimer = null;
    refillRadio(radioSeedId);
  }
  if (radioBuffer.length === 0 && radioFetchPromise) await radioFetchPromise;
  if (radioBuffer.length === 0) return { ok: false as const };
  const track = radioBuffer.shift()!;
  if (radioBuffer.length < 5 && !radioFetching) {
    const seedId = radioBuffer.length > 0 ? radioBuffer[radioBuffer.length - 1].id : track.id;
    refillRadio(seedId);
  }
  return { ok: true as const, track, remaining: radioBuffer.length };
}
