import { localePref, loadSettings } from "./settings";
import { createHash } from "crypto";
import type { CookieSource } from "./settings";
import { getGuestCookies, clearGuestCache, captureResponseCookies, dumpBrowserCookies } from "./guest-cookies";
import { USER_AGENT } from "./platform";

interface Cookie {
  domain: string;
  name: string;
  value: string;
}

interface SearchResult {
  id: string;
  title: string;
  channel: string;
  duration: number;
  thumbnail: string;
  // "752K views" / "2 years ago": present in every renderer
  views?: string;
  age?: string;
}

export interface ChipItem {
  text: string;
  token: string;
  isSelected: boolean;
}

export interface RecommendedResult {
  tracks: SearchResult[];
  chips: ChipItem[];
  continuation?: string;
}

interface SearchPlaylistResult {
  playlistId: string;
  title: string;
  channel: string;
  videoCount: number;
  thumbnail: string;
}

// One entry per browser. The account menu asks about every installed browser;
// with a single slot, asking about Firefox would evict the browser in use, and
// its next request would pay for a fresh extraction.
const browserCookies = new Map<string, Cookie[]>();
// who each identity is, keyed like identityKey(); cleared with the cookies
const accountCache = new Map<string, AccountInfo | null>();
let cachedVisitorData: string | null = null;

/**
 * Extract cookies from browser via yt-dlp --cookies-from-browser → temp Netscape file
 */
async function extractBrowserCookies(browser: string): Promise<Cookie[]> {
  const hit = browserCookies.get(browser);
  if (hit) return hit;
  // one reader for the browser's store, shared with a profile made from the
  // browser — see dumpBrowserCookies for why a non-zero exit is not a failure
  const cookies = (await dumpBrowserCookies(browser))
    .map((c) => ({ domain: c.domain, name: c.name, value: c.value }));
  browserCookies.set(browser, cookies);
  return cookies;
}

export function clearCookieCache(): void {
  browserCookies.clear();
  accountCache.clear();
  cachedVisitorData = null;
  clearGuestCache();
}

/**
 * Resolve cookies based on source setting.
 */
export async function resolveCookies(source: CookieSource, browser: string, profile: string): Promise<Cookie[]> {
  switch (source) {
    case "browser":
      return extractBrowserCookies(browser);
    case "guest":
      return getGuestCookies(profile);
    case "none":
      return [];
  }
}

// Thumbnails come as 360x202 and 720x404; WebP has no scaled decode, so a 720
// for a 360 card decodes 4x the pixels (28% of cycles during a scroll). Take
// the smallest that covers the target, else the biggest. The target is
// `ui.thumbQuality`, which Qt also sizes its decode from (GridUi.cardPx);
// saveSettings refreshes the sidecar's copy when it changes.
const THUMB_WIDTH: Record<string, number> = { low: 180, medium: 360, high: 720 };
export function wantedThumbWidth(): number {
  try {
    const q = String((loadSettings().ui as any)?.thumbQuality ?? "medium");
    return THUMB_WIDTH[q] ?? 360;
  } catch { return 360; }
}

export function pickThumb(sources: any[] | undefined | null, want?: number): string {
  const target = want ?? wantedThumbWidth();
  const s = (sources ?? []).filter((t: any) => typeof t?.url === "string");
  if (!s.length) return "";
  const fits = s.filter((t: any) => (t.width ?? 0) >= target)
                .sort((a: any, b: any) => (a.width ?? 0) - (b.width ?? 0));
  return (fits[0] ?? s[s.length - 1]).url;
}

function getCookieValue(cookies: Cookie[], name: string): string | undefined {
  return cookies.find((c) => c.name === name)?.value;
}

/**
 * Compute SAPISIDHASH for YouTube API auth
 * Format: SHA1(timestamp + " " + SAPISID + " " + origin)
 */
function computeSapisidHash(sapisid: string, origin: string): string {
  const timestamp = Math.floor(Date.now() / 1000);
  const input = `${timestamp} ${sapisid} ${origin}`;
  const hash = createHash("sha1").update(input).digest("hex");
  return `${timestamp}_${hash}`;
}

// The cookies a browser would send to this host (RFC 6265 domain-match). Sent
// the whole Google jar, youtube.com redirects to accounts.google.com/
// CookieMismatch and the home-page scrape finds no ytInitialData.
export function cookiesForHost(cookies: Cookie[], host: string): Cookie[] {
  const h = host.toLowerCase();
  return cookies.filter((c) => {
    const d = c.domain.replace(/^\./, "").toLowerCase();
    return h === d || h.endsWith("." + d);
  });
}

// Who a signed-in session is, from InnerTube's account_menu (what youtube.com's
// avatar menu calls): name, @handle and photo from its header; no header means
// signed out (null). Searched for, not walked by path, so a moved wrapper does
// not read as signed out.
export interface AccountInfo { name: string; handle: string; photo: string }

function findKey(o: any, key: string, depth = 0): any {
  if (!o || typeof o !== "object" || depth > 12) return null;
  if (key in o) return o[key];
  for (const v of Array.isArray(o) ? o : Object.values(o)) {
    const hit = findKey(v, key, depth + 1);
    if (hit) return hit;
  }
  return null;
}

export function parseAccountMenu(data: any): AccountInfo | null {
  const h = findKey(data, "activeAccountHeaderRenderer");
  if (!h) return null;
  const name = textOf(h.accountName);
  if (!name) return null;
  const thumbs = h.accountPhoto?.thumbnails;
  return {
    name,
    handle: textOf(h.channelHandle),
    photo: Array.isArray(thumbs) && thumbs.length ? String(thumbs[thumbs.length - 1].url ?? "") : "",
  };
}

function identityKey(source: CookieSource, browser: string, profile: string): string {
  return source === "browser" ? `browser:${browser}` : source === "guest" ? `guest:${profile}` : "none";
}

// Forget what a browser held. Its cookies and the account they name are read
// once and kept, and a sign-in or sign-out in the browser changes neither;
// dropping them makes the next status, and the next request, read the store
// again.
export function forgetBrowser(browser: string): void {
  browserCookies.delete(browser);
  accountCache.delete(identityKey("browser", browser, ""));
}

// Signed in means YouTube names an account: during a sign-out the auth cookie
// can outlive YouTube's acceptance of it. Only a request with no answer falls
// back to the cookie, so a network blip does not read as a sign-out.
export function signedInFrom(hasCookie: boolean, asked: { answered: boolean; account: AccountInfo | null }): boolean {
  if (!hasCookie) return false;
  return asked.answered ? asked.account !== null : true;
}

// Who an identity is signed in as. No Authorization header means no signed-in
// cookie, so there is nobody to ask about and no request is made. A signed-out
// answer is cached (with the cookies, so a switch or a failure clears it); a
// failed request is not, so the next open of the menu asks again.
export async function fetchAccountInfo(source: CookieSource, browser: string, profile: string): Promise<AccountInfo | null> {
  const key = identityKey(source, browser, profile);
  if (accountCache.has(key)) return accountCache.get(key) ?? null;
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, source, browser, profile);
  if (!headers["Authorization"]) { accountCache.set(key, null); return null; }
  headers["User-Agent"] = USER_AGENT;
  const res = await fetch(`${origin}/youtubei/v1/account/account_menu?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify({ context: { client: {
      clientName: "WEB", clientVersion: "2.20260301.00.00", hl: localePref().hl, gl: localePref().gl,
    } } }),
  });
  // no answer is not "no account": the caller falls back to the cookie
  if (!res.ok) throw new Error(`account_menu ${res.status}`);
  const info = parseAccountMenu(await res.json());
  accountCache.set(key, info);
  return info;
}

// The auth cookie as this host sees it: SAPISIDHASH comes from document.cookie,
// which on youtube.com holds only youtube.com's cookies. Counting a SAPISID a
// signed-out Chromium left on .google.com.br would sign requests with a hash of
// a cookie youtube.com never sees.
export function authCookie(cookies: Cookie[], host: string): string {
  const seen = cookiesForHost(cookies, host);
  return getCookieValue(seen, "SAPISID") || getCookieValue(seen, "__Secure-3PAPISID") || "";
}

// The same question buildHeaders asks. It sends an Authorization header
// exactly when this is true, so anything reporting "signed in" to the user
// agrees with what goes on the wire.
export function hasAuthCookie(cookies: Cookie[]): boolean {
  return !!authCookie(cookies, "www.youtube.com");
}

/**
 * Build request headers with cookies + optional SAPISIDHASH auth.
 * Shared by all InnerTube API callers and watchtime reporting.
 */
export async function buildHeaders(origin: string, cookieSource: CookieSource, browser: string, profile: string): Promise<Record<string, string>> {
  let cookies: Cookie[] = [];
  try {
    cookies = await resolveCookies(cookieSource, browser, profile);
  } catch { /* continue without cookies */ }

  const ytCookies = cookiesForHost(cookies, new URL(origin).hostname);
  const cookieHeader = ytCookies.map((c) => `${c.name}=${c.value}`).join("; ");

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Origin": origin,
    "Referer": `${origin}/`,
    "X-Origin": origin,
  };

  if (cookieHeader) {
    headers["Cookie"] = cookieHeader;
  }

  const sapisid = authCookie(cookies, new URL(origin).hostname);
  if (sapisid) {
    headers["Authorization"] = `SAPISIDHASH ${computeSapisidHash(sapisid, origin)}`;
    headers["X-Goog-AuthUser"] = "0";
  }

  return headers;
}

/**
 * Fetch YouTube Music home page via InnerTube browse API.
 */
export interface HomeResult {
  sections: HomeSection[];
  chips: HomeChip[];
  continuation: string;
  authStatus: "signed-in" | "cookies-only" | "no-cookies";
  cookieCount: number;
  browser: string;
}

export async function fetchMusicHome(cookieSource: CookieSource, browser: string, profile: string, params?: string): Promise<HomeResult> {
  const origin = "https://music.youtube.com";

  let cookies: Cookie[] = [];
  try {
    cookies = await resolveCookies(cookieSource, browser, profile);
  } catch (err) {
    console.warn("Cookie resolution failed, continuing unauthenticated:", err);
  }

  const ytCookies = cookiesForHost(cookies, "music.youtube.com");

  const sapisid = authCookie(cookies, "music.youtube.com");
  let authStatus: HomeResult["authStatus"] = "no-cookies";
  if (sapisid) authStatus = "signed-in";
  else if (ytCookies.length > 0) authStatus = "cookies-only";

  const headers = await buildHeaders(origin, cookieSource, browser, profile);

  const body = {
    context: {
      client: {
        clientName: "WEB_REMIX",
        clientVersion: "1.20260301.01.00",
        hl: localePref().hl,
        gl: localePref().gl,
      },
    },
    browseId: "FEmusic_home",
    ...(params ? { params } : {}),
  };

  const res = await fetch(`${origin}/youtubei/v1/browse?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) {
    clearCookieCache();
    throw new Error(`InnerTube browse failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  const home = parseMusicHome(data);
  if (home.visitorData) musicVisitorData = home.visitorData;
  return { sections: home.sections, chips: home.chips, continuation: home.continuation,
           authStatus, cookieCount: ytCookies.length, browser };
}

// The rest of the home page. YouTube Music sends two or three shelves and a
// token for the next ones, loaded as the page is scrolled. A continuation is
// answered only for the visitor that opened the page, so the first page's
// visitorData goes with it.
export async function fetchMusicHomeContinuation(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<{ sections: HomeSection[]; continuation: string }> {
  const origin = "https://music.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);
  const client: Record<string, string> = {
    clientName: "WEB_REMIX", clientVersion: "1.20260301.01.00",
    hl: localePref().hl, gl: localePref().gl,
  };
  if (musicVisitorData) client.visitorData = musicVisitorData;
  const res = await fetch(`${origin}/youtubei/v1/browse?prettyPrint=false`, {
    method: "POST", headers, body: JSON.stringify({ context: { client }, continuation: token }),
  });
  if (cookieSource === "guest") captureResponseCookies(profile, res);
  if (!res.ok) throw new Error(`InnerTube home continuation failed: ${res.status} ${res.statusText}`);
  return parseMusicHomeContinuation(await res.json());
}

// A home item is a playlist, a song (Quick picks, first on a signed-in page),
// an album or an artist.
export type HomeItemKind = "playlist" | "album" | "song" | "artist";
export interface HomeItem {
  kind: HomeItemKind;
  videoId: string;      // a song's
  playlistId: string;   // what opening it plays: a playlist, an album's playlist, an artist's radio
  title: string;
  description: string;
  channel: string;
  thumbnail: string;
}
export interface HomeSection { title: string; items: HomeItem[] }
export interface HomeChip { text: string; params: string; isSelected: boolean }
let musicVisitorData = "";

/**
 * Fetch topic filter chips from the YouTube homepage HTML.
 * Tracks are fetched separately via yt-dlp (more reliable).
 */
export async function fetchRecommendedChips(cookieSource: CookieSource, browser: string, profile: string): Promise<ChipItem[]> {
  let cookies: Cookie[] = [];
  try {
    cookies = await resolveCookies(cookieSource, browser, profile);
  } catch { /* continue without cookies */ }

  const ytCookies = cookiesForHost(cookies, "www.youtube.com");
  const cookieHeader = ytCookies.map((c) => `${c.name}=${c.value}`).join("; ");

  const headers: Record<string, string> = {
    "User-Agent": USER_AGENT,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": `${localePref().hl}-${localePref().gl},${localePref().hl};q=0.5`,
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
  };
  if (cookieHeader) headers["Cookie"] = cookieHeader;

  const res = await fetch("https://www.youtube.com", { headers });
  if (cookieSource === "guest") captureResponseCookies(profile, res);
  if (!res.ok) return [];

  const html = await res.text();
  const match = html.match(/var\s+ytInitialData\s*=\s*(\{.+?\});\s*<\/script>/s);
  if (!match) return [];

  // Cache visitorData for chip continuation requests
  const vdMatch = html.match(/"visitorData"\s*:\s*"([^"]+)"/);
  if (vdMatch) cachedVisitorData = vdMatch[1];

  const data = JSON.parse(match[1]);
  return parseChipsFromBrowse(data);
}

/**
 * Fetch recommended videos filtered by a topic chip via continuation token.
 */
export async function fetchRecommendedByChip(token: string, cookieSource: CookieSource, browser: string, profile: string, count: number = 30): Promise<RecommendedResult> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);
  headers["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0";

  const client: Record<string, string> = {
    clientName: "WEB",
    clientVersion: "2.20260301.00.00",
    hl: localePref().hl,
    gl: localePref().gl,
  };
  if (cachedVisitorData) client.visitorData = cachedVisitorData;

  const body = {
    context: { client },
    continuation: token,
  };

  const res = await fetch(`${origin}/youtubei/v1/browse?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) {
    throw new Error(`InnerTube chip filter failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  const parsed = parseChipContinuationResponse(data, count);
  const chips = parseChipsFromContinuation(data);
  logRecPage("byChip", headers, parsed.tracks);
  return { tracks: parsed.tracks, chips, continuation: parsed.continuation };
}

// One line per recommended page: which visitor identity the request rode on
// vs the innertube visitorData, plus a content sample — for pinning down the
// reported "one generic page mid-feed" (not reproducible synthetically).
function logRecPage(kind: string, headers: Record<string, string>, tracks: SearchResult[]): void {
  const vi = /VISITOR_INFO1_LIVE=([^;]+)/.exec(headers["Cookie"] || "")?.[1] || "-";
  console.error(
    `[rec] ${kind}: ${tracks.length} tracks cookieVisitor=${vi.slice(0, 8)} ` +
    `vd=${(cachedVisitorData || "-").slice(0, 8)} ` +
    `sample=${tracks.slice(0, 3).map((t) => JSON.stringify(t.title.slice(0, 40))).join(" | ")}`,
  );
}

/**
 * Fetch next page of recommended videos using a pagination continuation token.
 */
export async function fetchRecommendedContinuation(
  token: string,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
): Promise<RecommendedResult> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);
  headers["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0";

  const client: Record<string, string> = {
    clientName: "WEB",
    clientVersion: "2.20260301.00.00",
    hl: localePref().hl,
    gl: localePref().gl,
  };
  if (cachedVisitorData) client.visitorData = cachedVisitorData;

  const body = {
    context: { client },
    continuation: token,
  };

  const res = await fetch(`${origin}/youtubei/v1/browse?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) {
    throw new Error(`InnerTube recommended continuation failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  const parsed = parseChipContinuationResponse(data, 100);
  logRecPage("cont", headers, parsed.tracks);
  return { tracks: parsed.tracks, chips: [], continuation: parsed.continuation };
}

function parseChipRenderer(chip: any): ChipItem | null {
  const renderer = chip?.chipCloudChipRenderer;
  if (!renderer) return null;
  const text = renderer.text?.simpleText || renderer.text?.runs?.[0]?.text || "";
  const token = renderer.navigationEndpoint?.continuationCommand?.token || "";
  const isSelected = renderer.isSelected === true;
  if (!text) return null;
  return { text, token, isSelected };
}

function parseChipsFromBrowse(data: any): ChipItem[] {
  const richGrid = data?.contents?.twoColumnBrowseResultsRenderer
    ?.tabs?.[0]?.tabRenderer?.content?.richGridRenderer;
  const chipBar = richGrid?.header?.feedFilterChipBarRenderer?.contents;
  if (!Array.isArray(chipBar)) return [];
  return chipBar.map(parseChipRenderer).filter((c: ChipItem | null): c is ChipItem => c !== null);
}

function parseChipsFromContinuation(data: any): ChipItem[] {
  const actions = data?.onResponseReceivedActions;
  if (!Array.isArray(actions)) return [];
  for (const action of actions) {
    const items = action?.reloadContinuationItemsCommand?.continuationItems;
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const chipBar = item?.feedFilterChipBarRenderer?.contents;
      if (Array.isArray(chipBar)) {
        return chipBar.map(parseChipRenderer).filter((c: ChipItem | null): c is ChipItem => c !== null);
      }
    }
  }
  return [];
}

function parseChipContinuationResponse(data: any, count: number): { tracks: SearchResult[]; continuation?: string } {
  const results: SearchResult[] = [];
  let continuation: string | undefined;
  const actions = data?.onResponseReceivedActions;
  if (!Array.isArray(actions)) return { tracks: results };

  for (const action of actions) {
    const items = action?.reloadContinuationItemsCommand?.continuationItems;
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      if (results.length >= count) break;

      // Direct video item (videoRenderer or lockupViewModel)
      const parsed = parseRichItemVideo(item);
      if (parsed && parsed.title && isFeedRecommendation(parsed.id)) {
        results.push(parsed);
        continue;
      }

      skipShelf(item);
    }

    // Extract pagination continuation token
    continuation = extractContinuationToken(items) || continuation;
  }

  // Also check appendContinuationItemsAction for pagination tokens
  for (const action of actions) {
    const items = action?.appendContinuationItemsAction?.continuationItems;
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      if (results.length >= count) break;
      const parsed = parseRichItemVideo(item);
      if (parsed && parsed.title && isFeedRecommendation(parsed.id)) {
        results.push(parsed);
        continue;
      }
      skipShelf(item);
    }
    continuation = extractContinuationToken(items) || continuation;
  }

  return { tracks: results, continuation };
}

// Feed lockups carry videos (11-char ids) and RD mixes — both are real
// recommendations melo renders. Anything else a lockup can hold (PL
// playlists, podcasts) would enter as a fake unplayable "track".
function isFeedRecommendation(id: string): boolean {
  return /^[\w-]{11}$/.test(id) || id.startsWith("RD");
}

// Curated shelves ("Trending", "Popular music videos", …) ride the feed as
// single labeled bands of ~12 GENERIC items. Flattened into the
// recommendations they read as "12 mainstream things in a row" mid-feed.
// Drop them; the feed's own rich items are the actual recommendations.
function skipShelf(item: any): void {
  const shelf = item?.richSectionRenderer?.content?.richShelfRenderer;
  if (shelf?.contents?.length) {
    const title = shelf?.title?.runs?.[0]?.text || shelf?.title?.simpleText || "?";
    console.error(`[rec] skipped shelf "${title}" (${shelf.contents.length} items)`);
  }
}

/** Extract a video from a richItemRenderer (handles both videoRenderer and lockupViewModel) */
function parseRichItemVideo(item: any): SearchResult | null {
  const content = item?.richItemRenderer?.content;
  if (!content) return null;

  // Old format: videoRenderer
  const vr = content.videoRenderer;
  if (vr?.videoId) {
    return {
      id: vr.videoId,
      title: vr.title?.runs?.[0]?.text || "",
      channel: vr.ownerText?.runs?.[0]?.text || "",
      duration: parseDuration(vr.lengthText?.simpleText || ""),
      thumbnail: pickThumb(vr.thumbnail?.thumbnails),
    };
  }

  // New format: lockupViewModel
  const lvm = content.lockupViewModel;
  if (lvm?.contentId) {
    return parseLockupVideo(lvm);
  }

  return null;
}


export interface SearchFilters {
  sort?: "relevance" | "date" | "views" | "rating";
  type?: "any" | "video" | "channel" | "playlist" | "movie";
  uploadDate?: "any" | "hour" | "today" | "week" | "month" | "year";
  duration?: "any" | "short" | "medium" | "long";
}

export interface InnerTubeSearchResult {
  results: SearchResult[];
  playlists: SearchPlaylistResult[];
  continuation?: string;
}

/**
 * Encode search filters into YouTube's protobuf params format.
 * Structure: { 1: sort, 2: { 1: uploadDate, 2: type, 3: duration } }
 */
function encodeSearchParams(filters: SearchFilters): string | undefined {
  const bytes: number[] = [];

  // Field 1 (varint): sort
  const sortMap: Record<string, number> = { date: 1, views: 2, rating: 3 };
  if (filters.sort && sortMap[filters.sort]) {
    bytes.push(8, sortMap[filters.sort]); // tag = (1<<3)|0 = 8
  }

  // Field 2 (embedded message): filters
  const inner: number[] = [];

  const dateMap: Record<string, number> = { hour: 1, today: 2, week: 3, month: 4, year: 5 };
  if (filters.uploadDate && dateMap[filters.uploadDate]) {
    inner.push(8, dateMap[filters.uploadDate]); // inner field 1
  }

  const typeMap: Record<string, number> = { video: 1, channel: 2, playlist: 3, movie: 4 };
  if (filters.type && typeMap[filters.type]) {
    inner.push(16, typeMap[filters.type]); // inner field 2
  }

  const durMap: Record<string, number> = { short: 1, medium: 2, long: 3 };
  if (filters.duration && durMap[filters.duration]) {
    inner.push(24, durMap[filters.duration]); // inner field 3
  }

  if (inner.length > 0) {
    bytes.push(18, inner.length, ...inner); // tag = (2<<3)|2 = 18, then length
  }

  if (bytes.length === 0) return undefined;
  return Buffer.from(bytes).toString("base64");
}

/**
 * Search YouTube via InnerTube search API.
 * Returns both videos and playlists in a single response.
 */
export async function fetchSearch(
  query: string,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
  filters?: SearchFilters,
): Promise<InnerTubeSearchResult> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);

  const body: Record<string, unknown> = {
    context: {
      client: {
        clientName: "WEB",
        clientVersion: "2.20260301.00.00",
        hl: localePref().hl,
        gl: localePref().gl,
      },
    },
    query,
  };

  const params = filters ? encodeSearchParams(filters) : undefined;
  if (params) body.params = params;

  const res = await fetch(`${origin}/youtubei/v1/search?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) {
    throw new Error(`InnerTube search failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return parseSearchResponse(data);
}

/**
 * Fetch next page of search results using a continuation token.
 */
export async function fetchSearchContinuation(
  token: string,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
): Promise<InnerTubeSearchResult> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);

  const body = {
    context: {
      client: {
        clientName: "WEB",
        clientVersion: "2.20260301.00.00",
        hl: localePref().hl,
        gl: localePref().gl,
      },
    },
    continuation: token,
  };

  const res = await fetch(`${origin}/youtubei/v1/search?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) {
    throw new Error(`InnerTube search continuation failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return parseSearchContinuationResponse(data);
}

function parseSearchContinuationResponse(data: any): InnerTubeSearchResult {
  const results: SearchResult[] = [];
  const playlists: SearchPlaylistResult[] = [];
  let continuation: string | undefined;

  const actions = data?.onResponseReceivedCommands;
  if (!Array.isArray(actions)) return { results, playlists };

  for (const action of actions) {
    const items = action?.appendContinuationItemsAction?.continuationItems;
    if (!Array.isArray(items)) continue;

    for (const item of items) {
      const sectionItems = item?.itemSectionRenderer?.contents;
      if (Array.isArray(sectionItems)) {
        parseSearchItems(sectionItems, results, playlists);
      }
    }

    // Extract continuation token from the continuationItems array
    continuation = extractContinuationToken(items);
  }

  return { results, playlists, continuation };
}

/** "2,678,290 views" -> "2.7M views": the lockups already write it this way. */
function compactViews(text: string): string {
  const t = (text || "").trim();
  // Already compact ("752K views"): leave it. Stripping non-digits reads that
  // as 752 and hands back "752 views" — the suffix, and three orders of
  // magnitude, gone.
  if (/[KMB]\s*views?$/i.test(t)) return t;
  const n = Number(t.replace(/[^\d]/g, ""));
  if (!Number.isFinite(n) || n <= 0) return t;
  const fmt = (v: number, u: string) =>
    (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + u + " views";
  if (n >= 1e9) return fmt(n / 1e9, "B");
  if (n >= 1e6) return fmt(n / 1e6, "M");
  if (n >= 1e3) return fmt(n / 1e3, "K");
  return n + " views";
}

function parseSearchItems(items: any[], results: SearchResult[], playlists: SearchPlaylistResult[]): void {
  for (const item of items) {
    // Video (old format)
    const vr = item?.videoRenderer;
    if (vr?.videoId) {
      results.push({
        id: vr.videoId,
        title: vr.title?.runs?.[0]?.text || "",
        channel: vr.ownerText?.runs?.[0]?.text || "",
        duration: parseDuration(vr.lengthText?.simpleText || ""),
        thumbnail: pickThumb(vr.thumbnail?.thumbnails),
          views: compactViews(vr.viewCountText?.simpleText || ""),
          age: vr.publishedTimeText?.simpleText || "",
      });
      continue;
    }

    // Playlist (old format)
    const pr = item?.playlistRenderer;
    if (pr?.playlistId) {
      playlists.push({
        playlistId: pr.playlistId,
        title: pr.title?.simpleText || "",
        channel: pr.shortBylineText?.runs?.[0]?.text || "",
        videoCount: parseInt(pr.videoCount || "0", 10),
        thumbnail: pickThumb(pr.thumbnails?.[0]?.thumbnails),
      });
      continue;
    }

    // lockupViewModel (new format — used for both videos and playlists)
    const lvm = item?.lockupViewModel;
    if (lvm?.contentId) {
      if (lvm.contentType === "LOCKUP_CONTENT_TYPE_VIDEO") {
        const parsed = parseLockupVideo(lvm);
        if (parsed) results.push(parsed);
      } else if (
        lvm.contentType === "LOCKUP_CONTENT_TYPE_PLAYLIST" ||
        lvm.contentType === "LOCKUP_CONTENT_TYPE_PODCAST"
      ) {
        const parsed = parseLockupPlaylist(lvm);
        if (parsed) playlists.push(parsed);
      }
    }
  }
}

function extractContinuationToken(items: any[]): string | undefined {
  for (const item of items) {
    const token = item?.continuationItemRenderer?.continuationEndpoint
      ?.continuationCommand?.token;
    if (token) return token;
  }
  return undefined;
}

function parseSearchResponse(data: any): InnerTubeSearchResult {
  const results: SearchResult[] = [];
  const playlists: SearchPlaylistResult[] = [];
  let continuation: string | undefined;

  const sections = data?.contents?.twoColumnSearchResultsRenderer
    ?.primaryContents?.sectionListRenderer?.contents;
  if (!Array.isArray(sections)) return { results, playlists };

  for (const section of sections) {
    const items = section?.itemSectionRenderer?.contents;
    if (Array.isArray(items)) {
      parseSearchItems(items, results, playlists);
    }
  }

  // Extract continuation token from the sectionListRenderer contents
  continuation = extractContinuationToken(sections);

  return { results, playlists, continuation };
}

function parseLockupVideo(lvm: any): SearchResult | null {
  const meta = lvm.metadata?.lockupMetadataViewModel;
  const title = meta?.title?.content || "";

  // rows[0] is the channel; the row after it carries the view count and the
  // age, which is the information a wide row has space for and lacked
  let channel = "";
  let views = "";
  let age = "";
  const rows = meta?.metadata?.contentMetadataViewModel?.metadataRows;
  if (Array.isArray(rows)) {
    for (const r of rows) {
      for (const part of r?.metadataParts ?? []) {
        const t = part?.text?.content;
        if (typeof t !== "string" || !t) continue;
        if (/^[\d.,]+[KMB]?\s+views?$/i.test(t)) views = compactViews(t);
        else if (/ago$/.test(t)) age = t;
        else if (!channel) channel = t;
      }
    }
  }

  const thumbVm = lvm.contentImage?.thumbnailViewModel
    || lvm.contentImage?.collectionThumbnailViewModel?.primaryThumbnail?.thumbnailViewModel;
  const thumbnail = pickThumb(thumbVm?.image?.sources);

  let duration = 0;
  const overlays = thumbVm?.overlays;
  if (Array.isArray(overlays)) {
    for (const o of overlays) {
      // Old format: thumbnailOverlayBadgeViewModel.thumbnailBadges
      const badges = o?.thumbnailOverlayBadgeViewModel?.thumbnailBadges;
      if (Array.isArray(badges)) {
        for (const b of badges) {
          const text = b?.thumbnailBadgeViewModel?.text || "";
          if (text && text.includes(":")) {
            duration = parseDuration(text);
          }
        }
      }
      // New format: thumbnailBottomOverlayViewModel.badges
      const bottomBadges = o?.thumbnailBottomOverlayViewModel?.badges;
      if (Array.isArray(bottomBadges)) {
        for (const b of bottomBadges) {
          const text = b?.thumbnailBadgeViewModel?.text || "";
          if (text && text.includes(":")) {
            duration = parseDuration(text);
          }
        }
      }
    }
  }

  return { id: lvm.contentId, title, channel, duration, thumbnail, views, age };
}

function parseLockupPlaylist(lvm: any): SearchPlaylistResult | null {
  const meta = lvm.metadata?.lockupMetadataViewModel;
  const title = meta?.title?.content || "";

  let channel = "";
  const rows = meta?.metadata?.contentMetadataViewModel?.metadataRows;
  if (Array.isArray(rows) && rows.length > 0) {
    channel = rows[0]?.metadataParts?.[0]?.text?.content || "";
  }

  const thumbVm = lvm.contentImage?.collectionThumbnailViewModel?.primaryThumbnail?.thumbnailViewModel
    || lvm.contentImage?.thumbnailViewModel;
  const thumbnail = pickThumb(thumbVm?.image?.sources);

  // Video count from overlay badge
  let videoCount = 0;
  const overlays = thumbVm?.overlays;
  if (Array.isArray(overlays)) {
    for (const o of overlays) {
      const badges = o?.thumbnailOverlayBadgeViewModel?.thumbnailBadges;
      if (Array.isArray(badges)) {
        for (const b of badges) {
          const text = b?.thumbnailBadgeViewModel?.text || "";
          const match = text.match(/(\d+)\s*video/);
          if (match) videoCount = parseInt(match[1], 10);
        }
      }
    }
  }

  return { playlistId: lvm.contentId, title, channel, videoCount, thumbnail };
}

export interface VideoInfo {
  views: string;
  // "1.8B" — the unit-free form, for a meta rail that labels it itself
  viewsShort: string;
  published: string;
  age: string;
  likes: string;
  subscribers: string;
  description: string;
}

export interface NextResult {
  autoplay: SearchResult | null;
  suggestions: SearchResult[];
  // secondaryResults ends in a continuation item: the related list is paged,
  // 20 at a time
  continuation: string;
  info: VideoInfo | null;
}

/**
 * Fetch "up next" autoplay video + related suggestions for a videoId
 * via InnerTube next endpoint. Uses browser cookies for personalized results.
 */
export async function fetchNext(videoId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<NextResult> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);

  const body = {
    context: {
      client: {
        clientName: "WEB",
        clientVersion: "2.20260301.00.00",
        hl: localePref().hl,
        gl: localePref().gl,
      },
    },
    videoId,
  };

  const res = await fetch(`${origin}/youtubei/v1/next?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);

  if (!res.ok) return { autoplay: null, suggestions: [], continuation: "", info: null };

  const data = await res.json();
  return parseNextResponse(data);
}

/** Next page of the related list, from the token the previous page ended on. */
export async function fetchNextContinuation(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<{ suggestions: SearchResult[]; continuation: string }> {
  const origin = "https://www.youtube.com";
  const headers = await buildHeaders(origin, cookieSource, browser, profile);

  const res = await fetch(`${origin}/youtubei/v1/next?prettyPrint=false`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      context: {
        client: {
          clientName: "WEB",
          clientVersion: "2.20260301.00.00",
          hl: localePref().hl,
          gl: localePref().gl,
        },
      },
      continuation: token,
    }),
  });

  if (cookieSource === "guest") captureResponseCookies(profile, res);
  if (!res.ok) return { suggestions: [], continuation: "" };

  const data = await res.json();
  const items = data?.onResponseReceivedEndpoints?.[0]
    ?.appendContinuationItemsAction?.continuationItems;
  const suggestions: SearchResult[] = [];
  if (Array.isArray(items))
    for (const item of items) {
      const parsed = parseNextItem(item);
      if (parsed) suggestions.push(parsed);
    }
  return { suggestions, continuation: continuationToken(items) };
}

/** The trailing continuationItemRenderer of a results array, if there is one. */
function continuationToken(items: any): string {
  if (!Array.isArray(items)) return "";
  for (const item of items)
    if (item?.continuationItemRenderer)
      return item.continuationItemRenderer.continuationEndpoint
        ?.continuationCommand?.token || "";
  return "";
}

function textOf(v: any): string {
  if (!v) return "";
  if (typeof v.simpleText === "string") return v.simpleText;
  if (Array.isArray(v.runs)) return v.runs.map((r: any) => r?.text || "").join("");
  return "";
}

function parseVideoInfo(watchNext: any): VideoInfo | null {
  const contents = watchNext?.results?.results?.contents;
  if (!Array.isArray(contents)) return null;
  const primary = contents.find((c: any) => c?.videoPrimaryInfoRenderer)?.videoPrimaryInfoRenderer;
  const secondary = contents.find((c: any) => c?.videoSecondaryInfoRenderer)?.videoSecondaryInfoRenderer;
  if (!primary && !secondary) return null;

  const vc = primary?.viewCount?.videoViewCountRenderer;
  const like = primary?.videoActions?.menuRenderer?.topLevelButtons?.[0]
    ?.segmentedLikeDislikeButtonViewModel?.likeButtonViewModel?.likeButtonViewModel
    ?.toggleButtonViewModel?.toggleButtonViewModel?.defaultButtonViewModel
    ?.buttonViewModel;

  return {
    views: textOf(vc?.viewCount) || textOf(vc?.shortViewCount),
    viewsShort: textOf(vc?.extraShortViewCount) || textOf(vc?.shortViewCount)
      || textOf(vc?.viewCount),
    published: textOf(primary?.dateText),
    age: textOf(primary?.relativeDateText),
    likes: typeof like?.title === "string" ? like.title : "",
    subscribers: textOf(secondary?.owner?.videoOwnerRenderer?.subscriberCountText),
    description: secondary?.attributedDescription?.content
      || textOf(secondary?.description) || "",
  };
}

export function parseNextResponse(data: any): NextResult {
  const watchNext = data?.contents?.twoColumnWatchNextResults;

  // 1. Extract autoplay videoId
  let autoplay: SearchResult | null = null;
  const autoplayId = watchNext?.autoplay?.autoplay?.sets?.[0]
    ?.autoplayVideo?.watchEndpoint?.videoId;

  // 2. Extract suggestions from secondaryResults
  const suggestions: SearchResult[] = [];
  const results = watchNext?.secondaryResults?.secondaryResults?.results;
  if (Array.isArray(results)) {
    for (const item of results) {
      const parsed = parseNextItem(item);
      if (parsed) {
        // If this is the autoplay video, capture its full info
        if (parsed.id === autoplayId && !autoplay) {
          autoplay = parsed;
        } else {
          suggestions.push(parsed);
        }
      }
    }
  }

  // If autoplay wasn't found in suggestions, create a stub with just the ID
  if (!autoplay && autoplayId) {
    autoplay = { id: autoplayId, title: "", channel: "", duration: 0, thumbnail: "" };
  }

  return {
    autoplay,
    suggestions,
    continuation: continuationToken(results),
    info: parseVideoInfo(watchNext),
  };
}

function parseNextItem(item: any): SearchResult | null {
  // New format: lockupViewModel
  const lvm = item?.lockupViewModel;
  if (lvm && lvm.contentId && lvm.contentType === "LOCKUP_CONTENT_TYPE_VIDEO") {
    const meta = lvm.metadata?.lockupMetadataViewModel;
    const title = meta?.title?.content || "";

    // Channel name is in the first metadataRow's first part
    let channel = "";
    const rows = meta?.metadata?.contentMetadataViewModel?.metadataRows;
    if (Array.isArray(rows) && rows.length > 0) {
      channel = rows[0]?.metadataParts?.[0]?.text?.content || "";
    }

    // Thumbnail: try direct thumbnailViewModel first, then collectionThumbnailViewModel
    const thumbVm = lvm.contentImage?.thumbnailViewModel
      || lvm.contentImage?.collectionThumbnailViewModel?.primaryThumbnail?.thumbnailViewModel;
    const thumbnail = pickThumb(thumbVm?.image?.sources);

    // Duration from overlay badge
    let duration = 0;
    const overlays = thumbVm?.overlays;
    if (Array.isArray(overlays)) {
      for (const o of overlays) {
        const badges = o?.thumbnailOverlayBadgeViewModel?.thumbnailBadges;
        if (Array.isArray(badges)) {
          for (const b of badges) {
            const text = b?.thumbnailBadgeViewModel?.text || "";
            if (text && text.includes(":")) {
              duration = parseDuration(text);
            }
          }
        }
      }
    }

    return { id: lvm.contentId, title, channel, duration, thumbnail };
  }

  // Old format: compactVideoRenderer
  const cvr = item?.compactVideoRenderer;
  if (cvr?.videoId) {
    const title = cvr.title?.simpleText || cvr.title?.runs?.[0]?.text || "";
    const channel = cvr.longBylineText?.runs?.[0]?.text ||
      cvr.shortBylineText?.runs?.[0]?.text || "";
    const durationText = cvr.lengthText?.simpleText || "";
    const thumbnail = pickThumb(cvr.thumbnail?.thumbnails);
    return { id: cvr.videoId, title, channel, duration: parseDuration(durationText), thumbnail };
  }

  return null;
}

function parseDuration(text: string): number {
  const parts = text.split(":").map(Number);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return 0;
}

function lastThumb(t: any): string {
  const list = t?.musicThumbnailRenderer?.thumbnail?.thumbnails;
  return Array.isArray(list) && list.length ? String(list[list.length - 1].url ?? "") : "";
}

function parseHomeItem(it: any): HomeItem | null {
  const song = it?.musicResponsiveListItemRenderer;
  if (song) {
    const cols = song.flexColumns || [];
    const first = cols[0]?.musicResponsiveListItemFlexColumnRenderer?.text;
    const videoId = findKey(first, "watchEndpoint")?.videoId || findKey(song, "watchEndpoint")?.videoId || "";
    if (!videoId) return null;
    // the artist is the second column up to its first separator
    const runs = cols[1]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || [];
    const artist: string[] = [];
    for (const r of runs) { if (String(r.text).includes("•")) break; artist.push(r.text) }
    const channel = artist.join("").trim();
    return { kind: "song", videoId, playlistId: "", title: textOf(first), description: channel, channel,
             thumbnail: lastThumb(song.thumbnail) };
  }
  const card = it?.musicTwoRowItemRenderer;
  if (!card) return null;
  const nav = card.navigationEndpoint || {};
  const bid: string = nav.browseEndpoint?.browseId || "";
  const overlay: string = findKey(card.thumbnailOverlay, "watchPlaylistEndpoint")?.playlistId || "";
  const base = { videoId: "", title: textOf(card.title), description: textOf(card.subtitle), channel: "",
                 thumbnail: lastThumb(card.thumbnailRenderer) };
  if (nav.watchEndpoint?.videoId) return { ...base, kind: "song", videoId: nav.watchEndpoint.videoId, playlistId: "" };
  if (bid.startsWith("VL")) return { ...base, kind: "playlist", playlistId: bid.slice(2) };
  if (nav.watchPlaylistEndpoint?.playlistId) return { ...base, kind: "playlist", playlistId: nav.watchPlaylistEndpoint.playlistId };
  if (bid.startsWith("RD")) return { ...base, kind: "playlist", playlistId: bid };
  // an album opens as the playlist its play button plays; melo has no album page
  if (bid.startsWith("MPRE")) return overlay ? { ...base, kind: "album", playlistId: overlay } : null;
  // melo has no artist page either: an artist is kept only with a radio to play
  if (bid.startsWith("UC")) return overlay ? { ...base, kind: "artist", playlistId: overlay } : null;
  return null;
}

function parseShelves(contents: any[]): HomeSection[] {
  const sections: HomeSection[] = [];
  for (const section of contents || []) {
    const shelf = section?.musicCarouselShelfRenderer || section?.musicImmersiveCarouselShelfRenderer;
    if (!shelf) continue;
    const header = shelf.header ? Object.values(shelf.header)[0] as any : null;
    const title = textOf(header?.title);
    if (!title) continue;
    const items = (shelf.contents || []).map(parseHomeItem).filter((x: HomeItem | null): x is HomeItem => x !== null);
    if (items.length) sections.push({ title, items });
  }
  return sections;
}

function nextContinuation(list: any): string {
  return list?.continuations?.[0]?.nextContinuationData?.continuation || "";
}

export function parseMusicHome(data: any): { sections: HomeSection[]; chips: HomeChip[]; continuation: string; visitorData: string } {
  const list = data?.contents?.singleColumnBrowseResultsRenderer?.tabs?.[0]?.tabRenderer?.content?.sectionListRenderer;
  const chips: HomeChip[] = (list?.header?.chipCloudRenderer?.chips || []).map((c: any) => {
    const chip = c.chipCloudChipRenderer || {};
    return { text: textOf(chip.text), params: chip.navigationEndpoint?.browseEndpoint?.params || "",
             isSelected: chip.isSelected === true };
  }).filter((c: HomeChip) => c.text);
  return { sections: parseShelves(list?.contents), chips, continuation: nextContinuation(list),
           visitorData: data?.responseContext?.visitorData || "" };
}

export function parseMusicHomeContinuation(data: any): { sections: HomeSection[]; continuation: string } {
  const list = data?.continuationContents?.sectionListContinuation;
  return { sections: parseShelves(list?.contents), continuation: nextContinuation(list) };
}
