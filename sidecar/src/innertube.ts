import { localePref, loadSettings } from "./settings";
import { createHash } from "crypto";
import type { CookieSource } from "./settings";
import { getGuestCookies, clearGuestCache, captureResponseCookies, dumpBrowserCookies, hasSignInCookie, KeyringError, KEYRING_FAILED, withConsent } from "./guest-cookies";
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
  // YouTube Music only, where its byline links them
  artists?: string[];
  album?: string;
  albumId?: string;
  year?: number;
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
  videoCount: number;      // 0: not given (a YouTube Music album says none)
  thumbnail: string;
  kind?: string;           // YouTube Music's own label: "Album", "Single", "EP", "Playlist"
  year?: number;
  browseId?: string;       // a YouTube Music album's MPRE page: it opens as that page
}

// One entry per browser. The account menu asks about every installed browser;
// with a single slot, asking about Firefox would evict the browser in use, and
// its next request would pay for a fresh extraction.
const browserCookies = new Map<string, Cookie[]>();
// who each identity is, keyed like identityKey(); cleared with the cookies
const accountCache = new Map<string, AccountInfo | null>();
const premiumCache = new Map<string, boolean>();   // by browser
let cachedVisitorData: string | null = null;

// Reads in flight, so callers asking at once share one read (and one prompt).
const browserReads = new Map<string, Promise<Cookie[]>>();
// Browsers whose keyring gave no key this session. Each read would prompt
// again, so none is made until the browser is picked again.
const unreadBrowsers = new Map<string, KeyringError>();

/** The browser's YouTube cookies, read once a session (see dumpBrowserCookies). */
async function extractBrowserCookies(browser: string): Promise<Cookie[]> {
  const hit = browserCookies.get(browser);
  if (hit) return hit;
  const denied = unreadBrowsers.get(browser);
  if (denied) throw denied;
  let read = browserReads.get(browser);
  if (!read) {
    read = dumpBrowserCookies(browser).then((all) => {
      const cookies = all.map((c) => ({ domain: c.domain, name: c.name, value: c.value }));
      if (browserReads.get(browser) === read) browserCookies.set(browser, cookies);
      return cookies;
    }, (e) => {
      if (e instanceof KeyringError && browserReads.get(browser) === read) unreadBrowsers.set(browser, e);
      throw e;
    }).finally(() => { if (browserReads.get(browser) === read) browserReads.delete(browser); });
    browserReads.set(browser, read);
  }
  return read;
}

/** The browser's keyring gave no key this session. */
export function browserUnread(browser: string): boolean {
  return unreadBrowsers.has(browser);
}

/** yt-dlp said the browser's keyring gave no key: remembered as a read's
 *  would be, but only when melo's own read of that browser also came back
 *  without the sign-in cookies (a stream run's jar is not seen). */
export function noteKeyringFailure(browser: string, stderr: string | undefined): void {
  if (!browser || !stderr || !KEYRING_FAILED.test(stderr)) return;
  const held = browserCookies.get(browser);
  if (!held || hasSignInCookie(held)) return;
  unreadBrowsers.set(browser, new KeyringError(stderr));
  browserCookies.delete(browser);
}

/** The keyring denial is forgotten: the next read asks it again. */
export function retryBrowser(browser: string): void {
  unreadBrowsers.delete(browser);
}

export function clearCookieCache(): void {
  browserCookies.clear();
  browserReads.clear();
  unreadBrowsers.clear();
  accountCache.clear();
  cachedVisitorData = null;
  musicVisitorData = "";
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

// Premium from the top bar's logo, as yt-dlp's _is_premium_subscriber reads it;
// null when the response carries no logo
export function parsePremium(data: any): boolean | null {
  const logo = findKey(data?.topbar, "topbarLogoRenderer");
  if (!logo) return null;
  return logo.iconImage?.iconType === "YOUTUBE_PREMIUM_LOGO" || /premium/i.test(textOf(logo.tooltipText));
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
  premiumCache.delete(browser);
}

// Whether the browser's account is Premium, from the home page's top bar: one
// request per browser, kept like the account. null: not known (no answer).
export async function fetchBrowserPremium(browser: string): Promise<boolean | null> {
  const hit = premiumCache.get(browser);
  if (hit !== undefined) return hit;
  const origin = "https://www.youtube.com";
  try {
    const headers = await buildHeaders(origin, "browser", browser, "");
    // signed out: nobody to be Premium
    if (!headers["Authorization"]) { premiumCache.set(browser, false); return false; }
    headers["User-Agent"] = USER_AGENT;
    const res = await fetch(`${origin}/youtubei/v1/browse?prettyPrint=false`, {
      method: "POST",
      headers,
      body: JSON.stringify({ browseId: "FEwhat_to_watch", context: { client: {
        clientName: "WEB", clientVersion: "2.20260301.00.00", hl: localePref().hl, gl: localePref().gl,
      } } }),
    });
    if (!res.ok) { console.error(`[account] ${browser}: Premium unknown (browse ${res.status})`); return null; }
    const premium = parsePremium(await res.json());
    console.error(`[account] ${browser}: Premium ${premium === null ? "unknown (no logo)" : premium ? "yes" : "no"}`);
    if (premium !== null) premiumCache.set(browser, premium);
    return premium;
  } catch (e) {
    console.error(`[account] ${browser}: Premium unknown (${String(e).split("\n")[0]})`);
    return null;
  }
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
  // a refused sign-in: the browser's cookies are read again next time
  if (res.status === 401 && source === "browser") forgetBrowser(browser);
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

  headers["Cookie"] = withConsent(cookieHeader);

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
  const client: Record<string, string | undefined> = {
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
  artists?: string[];   // a song's, where its byline links them
  album?: string;
  albumId?: string;
  year?: number;
  browseId?: string;    // an album's MPRE page
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
    "Accept-Language": `${localePref().hl},${localePref().hl.split("-")[0]};q=0.5`,
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
  };
  headers["Cookie"] = withConsent(cookieHeader);

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

  const client: Record<string, string | undefined> = {
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
  // whether each identity is there, never any part of it
  const vi = /VISITOR_INFO1_LIVE=[^;]+/.test(headers["Cookie"] || "") ? "set" : "-";
  console.error(
    `[rec] ${kind}: ${tracks.length} tracks cookieVisitor=${vi} ` +
    `vd=${cachedVisitorData ? "set" : "-"} ` +
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

  const client: Record<string, string | undefined> = {
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
      title: decodeTitle(vr.title?.runs?.[0]?.text || ""),
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
  type?: "any" | "video" | "channel" | "playlist" | "movie" | "song" | "album";   // song, album: YouTube Music
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
        const parsed = parseLockupVideo(lvm, false);
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

export function parseSearchResponse(data: any): InnerTubeSearchResult {
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

export function parseLockupVideo(lvm: any, stored = true): SearchResult | null {
  const meta = lvm.metadata?.lockupMetadataViewModel;
  const raw = meta?.title?.content || "";
  const title = stored ? decodeTitle(raw) : raw;

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

  return { id: lvm.contentId, title, channel, duration: lockupDuration(thumbVm), thumbnail, views, age };
}

/** A lockup's length from its thumbnail badge, in either of YouTube's two forms. */
function lockupDuration(thumbVm: any): number {
  let duration = 0;
  for (const o of Array.isArray(thumbVm?.overlays) ? thumbVm.overlays : []) {
    const badges = [
      ...(o?.thumbnailOverlayBadgeViewModel?.thumbnailBadges ?? []),
      ...(o?.thumbnailBottomOverlayViewModel?.badges ?? []),
    ];
    for (const b of badges) {
      const text = b?.thumbnailBadgeViewModel?.text || "";
      if (text.includes(":")) duration = parseDuration(text);
    }
  }
  return duration;
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

// A video's stored title can itself be HTML-escaped ("&lt;i&gt;", "can&#39;t"), and
// YouTube's web search shows it decoded once; every other source sends it as stored.
// One pass, so a typed "&lt;" (stored "&amp;lt;") stays "&lt;". Names and descriptions
// are never escaped and never go through this.
const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };
export function decodeTitle(s: string): string {
  if (!s || s.indexOf("&") < 0) return s;
  return s.replace(/&(#x[0-9a-f]{1,6}|#[0-9]{1,7}|[a-z]{2,4});/gi, (m, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return n > 0 && n <= 0x10ffff && !(n >= 0xd800 && n <= 0xdfff) ? String.fromCodePoint(n) : m;
    }
    const v = NAMED[e];
    return v === undefined ? m : v;
  });
}

export function textOf(v: any): string {
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
    const title = decodeTitle(meta?.title?.content || "");

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
    return { id: lvm.contentId, title, channel, duration: lockupDuration(thumbVm), thumbnail };
  }

  // Old format: compactVideoRenderer
  const cvr = item?.compactVideoRenderer;
  if (cvr?.videoId) {
    const title = decodeTitle(cvr.title?.simpleText || cvr.title?.runs?.[0]?.text || "");
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
    // Quick picks put the album in a third column
    const albumRuns = cols[2]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || [];
    return rememberMusic<HomeItem>({ kind: "song", videoId, playlistId: "", title: decodeTitle(textOf(first)), description: channel, channel,
                           thumbnail: lastThumb(song.thumbnail), ...bylineInfo([...runs, ...albumRuns]) });
  }
  const card = it?.musicTwoRowItemRenderer;
  if (!card) return null;
  const nav = card.navigationEndpoint || {};
  const bid: string = nav.browseEndpoint?.browseId || "";
  const overlay: string = findKey(card.thumbnailOverlay, "watchPlaylistEndpoint")?.playlistId || "";
  const base = { videoId: "", title: textOf(card.title), description: textOf(card.subtitle), channel: "",
                 thumbnail: lastThumb(card.thumbnailRenderer) };
  if (nav.watchEndpoint?.videoId)
    return rememberMusic<HomeItem>({ ...base, title: decodeTitle(base.title), kind: "song", videoId: nav.watchEndpoint.videoId, playlistId: "", ...bylineInfo(card.subtitle?.runs) });
  if (bid.startsWith("VL")) return { ...base, kind: "playlist", playlistId: bid.slice(2) };
  if (nav.watchPlaylistEndpoint?.playlistId) return { ...base, kind: "playlist", playlistId: nav.watchPlaylistEndpoint.playlistId };
  if (bid.startsWith("RD")) return { ...base, kind: "playlist", playlistId: bid };
  // an album opens from its MPRE page; its playlist is what Play, Save and Sync use
  if (bid.startsWith("MPRE")) return overlay ? { ...base, kind: "album", playlistId: overlay, browseId: bid } : null;
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

// ---- YouTube Music search and suggestions (Settings → Source) ----

export type DataSource = "youtube" | "ytmusic";
// A continuation is answered only by the service that issued it.
const YTM_TOKEN = "ytm:";
const MUSIC_ORIGIN = "https://music.youtube.com";

// Search filter params, as YouTube Music's own chips send them.
const YTM_SONGS = "EgWKAQIIAWoMEA4QChADEAQQCRAF";
const YTM_VIDEOS = "EgWKAQIQAWoMEA4QChADEAQQCRAF";
const YTM_PLAYLISTS = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU=";
const YTM_ALBUMS = "EgWKAQIYAWoMEA4QChADEAQQCRAF";

function ytmFallback(what: string, why: unknown): void {
  console.error(`[ytm] ${what}: ${String(why).split("\n")[0]}; using YouTube`);
}

async function musicPost(endpoint: string, body: Record<string, unknown>,
                         cookieSource: CookieSource, browser: string, profile: string): Promise<any> {
  const headers = await buildHeaders(MUSIC_ORIGIN, cookieSource, browser, profile);
  const client: Record<string, string | undefined> = {
    clientName: "WEB_REMIX", clientVersion: "1.20260301.01.00",
    hl: localePref().hl, gl: localePref().gl,
  };
  if (musicVisitorData) client.visitorData = musicVisitorData;
  const res = await fetch(`${MUSIC_ORIGIN}/youtubei/v1/${endpoint}?prettyPrint=false`, {
    method: "POST", headers, body: JSON.stringify({ context: { client }, ...body }),
  });
  if (cookieSource === "guest") captureResponseCookies(profile, res);
  if (!res.ok) throw new Error(`YouTube Music ${endpoint} failed: ${res.status} ${res.statusText}`);
  return res.json();
}

/** The YouTube Music params for melo's filters; undefined when YouTube Music has no equivalent. */
export function musicSearchParams(f?: SearchFilters): string | undefined {
  if (f?.sort && f.sort !== "relevance") return undefined;
  if (f?.uploadDate && f.uploadDate !== "any") return undefined;
  if (f?.duration && f.duration !== "any") return undefined;
  switch (f?.type ?? "any") {
    case "any": return YTM_SONGS;
    case "song": return YTM_SONGS;
    case "video": return YTM_VIDEOS;
    case "album": return YTM_ALBUMS;
    case "playlist": return YTM_PLAYLISTS;
    default: return undefined;
  }
}

// googleusercontent art is sized by its URL; the list stops at 120 px for songs
function musicThumb(sources: any[] | undefined): string {
  const url = pickThumb(sources);
  const want = wantedThumbWidth();
  return /=w\d+-h\d+/.test(url) ? url.replace(/=w\d+-h\d+/, `=w${want}-h${want}`) : url;
}

// "881M views" is compacted like YouTube's; "110M plays" is already short
function musicViews(segs: string[], fallback: string): string {
  const v = segs.find((s) => /views?$/i.test(s));
  return v ? compactViews(v) : fallback;
}

// A byline's linked runs: each artist links to its channel, the album to its
// MPRE page; a bare four-digit run is the year. An uploader's own channel
// (USER_CHANNEL) is not an artist.
export interface BylineInfo { artists?: string[]; album?: string; albumId?: string; year?: number }
export function bylineInfo(runs: any[] | undefined): BylineInfo {
  const out: BylineInfo = {};
  const artists: string[] = [];
  for (const r of Array.isArray(runs) ? runs : []) {
    const text = String(r?.text ?? "").trim();
    const be = r?.navigationEndpoint?.browseEndpoint;
    const id: string = be?.browseId || "";
    const page: string = be?.browseEndpointContextSupportedConfigs?.browseEndpointContextMusicConfig?.pageType || "";
    if (id.startsWith("MPRE")) { if (!out.album) { out.album = text; out.albumId = id; } }
    else if (id.startsWith("UC")) { if (page !== "MUSIC_PAGE_TYPE_USER_CHANNEL" && text) artists.push(text); }
    else if (!be && /^\d{4}$/.test(text)) out.year = parseInt(text, 10);
  }
  if (artists.length) out.artists = artists;
  return out;
}

// googleusercontent art is square album art, sized by its URL
export function isMusicArt(url: string): boolean {
  return /^https:\/\/(lh\d|yt\d)\.(googleusercontent|ggpht)\.com\//.test(url) && /=w\d+-h\d+/.test(url);
}
export function musicArtAt(url: string, px: number): string {
  return url.replace(/=w\d+-h\d+/, `=w${px}-h${px}`);
}

// What YouTube Music said about a track, by video id: a track queued from a
// search keeps only {id,title,channel,...}, so adding it to the library later
// finds its album here. Tracks with an album only; 5000 entries, oldest out.
export interface MusicTrackInfo { title: string; artist: string; artists?: string[]; album: string; albumId?: string; year?: number; cover?: string }
const musicInfo = new Map<string, MusicTrackInfo>();
function rememberMusic<T extends { title: string; channel: string; thumbnail: string } & BylineInfo>(t: T): T {
  const id: string = (t as any).id || (t as any).videoId || "";
  if (!id || !t.album) return t;
  musicInfo.delete(id);
  musicInfo.set(id, { title: t.title, artist: t.channel || (t.artists ?? []).join(", "), artists: t.artists,
                      album: t.album, albumId: t.albumId, year: t.year,
                      cover: isMusicArt(t.thumbnail) ? t.thumbnail : undefined });
  if (musicInfo.size > 5000) musicInfo.delete(musicInfo.keys().next().value!);
  return t;
}
export function knownMusicInfo(videoId: string): MusicTrackInfo | undefined {
  return musicInfo.get(videoId);
}

type MusicListItem =
  | { kind: "track"; track: SearchResult }
  | { kind: "playlist"; playlist: SearchPlaylistResult }
  | null;

function columnText(r: any, i: number): string {
  return textOf(r?.flexColumns?.[i]?.musicResponsiveListItemFlexColumnRenderer?.text);
}

/** One musicResponsiveListItemRenderer: a song or video, or an album or playlist. Artists, podcasts and profiles are dropped. */
export function parseMusicListItem(r: any): MusicListItem {
  if (!r) return null;
  const title = columnText(r, 0);
  const segs = columnText(r, 1).split(/\s+•\s+/).map((s) => s.trim()).filter(Boolean);
  const thumbnail = musicThumb(r.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails);
  const videoId: string = r.playlistItemData?.videoId
    || findKey(r.overlay, "watchEndpoint")?.videoId || "";
  const runs: any[] = r.flexColumns?.[1]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || [];
  if (videoId) {
    const duration = parseDuration(segs.find((s) => /^\d+(:\d\d)+$/.test(s)) || "");
    return { kind: "track", track: rememberMusic({ id: videoId, title: decodeTitle(title), channel: segs[0] || "", duration, thumbnail,
                                                   views: musicViews(segs, columnText(r, 2)), ...bylineInfo(runs) }) };
  }
  const bid: string = r.navigationEndpoint?.browseEndpoint?.browseId || "";
  const overlayList: string = findKey(r.overlay, "watchPlaylistEndpoint")?.playlistId || "";
  let playlistId = "";
  if (bid.startsWith("VL")) playlistId = bid.slice(2);
  else if (bid.startsWith("MPRE")) playlistId = overlayList;   // an album plays as its playlist
  if (!playlistId) return null;
  // the artist or author is the linked run; unlinked, it follows the type label when there is one
  const linked = runs.find((x) => x?.navigationEndpoint?.browseEndpoint)?.text;
  const channel = linked || (segs.length >= 3 ? segs[1] : segs[0]) || "";
  const count = segs.map((s) => s.match(/^([\d,]+)\s+(songs?|tracks?|videos?)$/i)).find(Boolean);
  // "Album • Daft Punk • 2013": the label leads, unlinked, when the row has one
  const kind = segs.length >= 2 && !runs[0]?.navigationEndpoint && segs[0] !== channel
               && !/^\d{4}$/.test(segs[0]) ? segs[0] : "";
  const { year } = bylineInfo(runs);
  return { kind: "playlist", playlist: { playlistId, title, channel, thumbnail,
                                         videoCount: count ? parseInt(count[1].replace(/,/g, ""), 10) : 0,
                                         ...(kind ? { kind } : {}), ...(year ? { year } : {}),
                                         ...(bid.startsWith("MPRE") ? { browseId: bid } : {}) } };
}

function collectMusicItems(items: any[] | undefined, out: InnerTubeSearchResult): void {
  for (const it of items || []) {
    const parsed = parseMusicListItem(it?.musicResponsiveListItemRenderer);
    if (parsed?.kind === "track") out.results.push(parsed.track);
    else if (parsed?.kind === "playlist") out.playlists.push(parsed.playlist);
  }
}

function shelfContinuation(shelf: any): string {
  const t = shelf?.continuations?.[0]?.nextContinuationData?.continuation
    || continuationToken(shelf?.contents);
  return t ? YTM_TOKEN + t : "";
}

/** A search page: every shelf's rows, plus the rows the unfiltered page lists one per section. */
export function parseMusicSearch(data: any): InnerTubeSearchResult {
  const out: InnerTubeSearchResult = { results: [], playlists: [] };
  const tabs = data?.contents?.tabbedSearchResultsRenderer?.tabs;
  const sections = tabs?.[0]?.tabRenderer?.content?.sectionListRenderer?.contents;
  for (const s of Array.isArray(sections) ? sections : []) {
    const shelf = s?.musicShelfRenderer;
    if (shelf) {
      collectMusicItems(shelf.contents, out);
      const c = shelfContinuation(shelf);
      if (c && !out.continuation) out.continuation = c;
    }
    collectMusicItems(s?.itemSectionRenderer?.contents, out);
  }
  return out;
}

export function parseMusicSearchContinuation(data: any): InnerTubeSearchResult {
  const out: InnerTubeSearchResult = { results: [], playlists: [] };
  const shelf = data?.continuationContents?.musicShelfContinuation;
  if (shelf) {
    collectMusicItems(shelf.contents, out);
    const c = shelfContinuation(shelf);
    if (c) out.continuation = c;
  }
  for (const a of data?.onResponseReceivedCommands || []) {
    const items = a?.appendContinuationItemsAction?.continuationItems;
    collectMusicItems(items, out);
    const t = continuationToken(items);
    if (t && !out.continuation) out.continuation = YTM_TOKEN + t;
  }
  return out;
}

/**
 * YouTube Music search. The tracks are the Songs (or Videos) list, which pages;
 * with no filter, the albums and playlists come from the unfiltered page.
 */
export async function fetchMusicSearch(query: string, cookieSource: CookieSource, browser: string, profile: string,
                                       filters?: SearchFilters): Promise<InnerTubeSearchResult> {
  const params = musicSearchParams(filters) ?? YTM_SONGS;
  const ask = (p?: string) => musicPost("search", { query, ...(p ? { params: p } : {}) }, cookieSource, browser, profile);
  // Any is the songs with the top page's albums and playlists; a type is its own list
  const any = (filters?.type ?? "any") === "any";
  const [list, top] = await Promise.all([ask(params), any ? ask().catch(() => null) : null]);
  const r = parseMusicSearch(list);
  if (top) r.playlists = parseMusicSearch(top).playlists;
  return r;
}

const SINGLE_WAIT_MS = 2500;
export interface SingleInfo { browseId: string; duration: number; track?: SearchResult }

/**
 * Search's singles, read from their album pages after the results show: each one's
 * summed length, and a one-track single's song, which it then lists as. A page that
 * fails or takes over 2.5 s is left out.
 */
export async function singlesInfo(browseIds: string[],
                                  fetchAlbum: (browseId: string) => Promise<MusicAlbum | null>): Promise<SingleInfo[]> {
  const out = await Promise.all(browseIds.filter((id) => id.startsWith("MPRE")).map(async (browseId) => {
    const a = await Promise.race([fetchAlbum(browseId).catch(() => null),
                                  new Promise<null>((ok) => setTimeout(() => ok(null), SINGLE_WAIT_MS))]);
    if (!a || !a.tracks.length) return null;
    const duration = a.tracks.reduce((n, t) => n + (t.duration || 0), 0);
    return { browseId, duration, ...(a.tracks.length === 1 ? { track: a.tracks[0] } : {}) };
  }));
  return out.filter((x): x is SingleInfo => x !== null);
}

export async function fetchMusicSearchContinuation(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<InnerTubeSearchResult> {
  const raw = token.startsWith(YTM_TOKEN) ? token.slice(YTM_TOKEN.length) : token;
  return parseMusicSearchContinuation(await musicPost("search", { continuation: raw }, cookieSource, browser, profile));
}

/** Search from the chosen source; YouTube Music falls back to YouTube when it fails, finds nothing or cannot filter that way. */
export async function searchFrom(source: DataSource, query: string, cookieSource: CookieSource, browser: string, profile: string,
                                 filters?: SearchFilters): Promise<InnerTubeSearchResult> {
  if (source === "ytmusic" && musicSearchParams(filters) !== undefined) {
    try {
      const r = await fetchMusicSearch(query, cookieSource, browser, profile, filters);
      if (r.results.length || r.playlists.length) return r;
      ytmFallback("search", "no results");
    } catch (e) { ytmFallback("search", e); }
  }
  return fetchSearch(query, cookieSource, browser, profile, filters);
}

/** The next page from whichever service issued the token; a failed YouTube Music page ends the list. */
export async function searchContinuationFrom(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<InnerTubeSearchResult> {
  if (!token.startsWith(YTM_TOKEN)) return fetchSearchContinuation(token, cookieSource, browser, profile);
  try { return await fetchMusicSearchContinuation(token, cookieSource, browser, profile); }
  catch (e) {
    console.error(`[ytm] search continuation: ${String(e).split("\n")[0]}`);
    return { results: [], playlists: [] };
  }
}

export interface MusicAlbum {
  title: string;
  artist: string;
  artists?: string[];
  kind: string;            // "Album", "Single", "EP"
  year?: number;
  thumbnail: string;
  playlistId: string;      // the OLAK5uy_ list its play button plays
  tracks: SearchResult[];
  continuation: string;    // raw; a shelf of more than 100 tracks pages
}

// An album page's rows carry no art and, unless a track's artist differs,
// no artist: both come from the header
function albumTracks(items: any[] | undefined, album: { title: string; artist: string; artists?: string[];
                     year?: number; thumbnail: string; browseId: string }): SearchResult[] {
  const out: SearchResult[] = [];
  for (const it of items || []) {
    const r = it?.musicResponsiveListItemRenderer;
    const id: string = r?.playlistItemData?.videoId || findKey(r?.overlay, "watchEndpoint")?.videoId || "";
    if (!id) continue;   // greyed out: not playable here
    const runs: any[] = r.flexColumns?.[1]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || [];
    const artists = bylineInfo(runs).artists ?? album.artists;
    const fixed = textOf(r.fixedColumns?.[0]?.musicResponsiveListItemFixedColumnRenderer?.text);
    out.push(rememberMusic({ id, title: decodeTitle(columnText(r, 0)), channel: columnText(r, 1) || album.artist,
                             duration: parseDuration(fixed), thumbnail: album.thumbnail,
                             views: columnText(r, 2),
                             ...(artists ? { artists } : {}),
                             album: album.title, albumId: album.browseId,
                             ...(album.year ? { year: album.year } : {}) }));
  }
  return out;
}

/** A YouTube Music album page (browse MPRE…): its header and its track shelf. Null when the page has neither. */
export function parseMusicAlbum(data: any, browseId: string): MusicAlbum | null {
  const two = data?.contents?.twoColumnBrowseResultsRenderer;
  const header = findKey(two?.tabs, "musicResponsiveHeaderRenderer");
  const shelf = findKey(two?.secondaryContents, "musicShelfRenderer");
  if (!header || !shelf) return null;
  const strap: any[] = header.straplineTextOne?.runs || [];
  const sub = textOf(header.subtitle).split(/\s+•\s+/).map((s) => s.trim()).filter(Boolean);
  const year = sub.find((s) => /^\d{4}$/.test(s));
  const info = { title: textOf(header.title), artist: textOf(header.straplineTextOne), artists: bylineInfo(strap).artists,
                 year: year ? parseInt(year, 10) : undefined, browseId,
                 thumbnail: musicThumb(header.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails) };
  const tracks = albumTracks(shelf.contents, info);
  const playlistId: string = findKey(shelf.contents, "watchEndpoint")?.playlistId || "";
  return { title: info.title, artist: info.artist, ...(info.artists ? { artists: info.artists } : {}), kind: sub.find((s) => !/^\d{4}$/.test(s)) || "",
           ...(info.year ? { year: info.year } : {}), thumbnail: info.thumbnail, playlistId, tracks,
           continuation: shelf.continuations?.[0]?.nextContinuationData?.continuation || "" };
}

const ALBUM_MAX_PAGES = 4;

/** The album page and, for a shelf over 100 tracks, its further pages: one complete list. */
// album pages for 5 minutes: a search reads its singles, and opening one reads it again
const ALBUM_CACHE_MS = 5 * 60_000;
const albumCache = new Map<string, { at: number; album: MusicAlbum }>();
export function clearAlbumCacheForTest(): void { albumCache.clear(); }

export async function fetchMusicAlbum(browseId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<MusicAlbum | null> {
  const key = [browseId, cookieSource, browser, profile].join("|");
  const hit = albumCache.get(key);
  if (hit && Date.now() - hit.at < ALBUM_CACHE_MS) return hit.album;
  const album = await fetchMusicAlbumPage(browseId, cookieSource, browser, profile);
  if (album) albumCache.set(key, { at: Date.now(), album });
  return album;
}

async function fetchMusicAlbumPage(browseId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<MusicAlbum | null> {
  const album = parseMusicAlbum(await musicPost("browse", { browseId }, cookieSource, browser, profile), browseId);
  if (!album) return null;
  const info = { title: album.title, artist: album.artist, year: album.year, thumbnail: album.thumbnail, browseId,
                 artists: album.artists };
  for (let page = 0; album.continuation && page < ALBUM_MAX_PAGES; page++) {
    const more = await musicPost("browse", { continuation: album.continuation }, cookieSource, browser, profile).catch(() => null);
    const shelf = more?.continuationContents?.musicShelfContinuation;
    const rows = albumTracks(shelf?.contents, info);
    album.continuation = rows.length ? shelf?.continuations?.[0]?.nextContinuationData?.continuation || "" : "";
    album.tracks.push(...rows);
  }
  album.continuation = "";
  return album;
}

function panelItems(data: any): { items: any[]; continuation: string } {
  const found: { list: any } = { list: null };
  const walk = (o: any, depth: number): void => {
    if (!o || typeof o !== "object" || found.list || depth > 14) return;
    if (o.playlistPanelRenderer) { found.list = o.playlistPanelRenderer; return; }
    if (o.playlistPanelContinuation) { found.list = o.playlistPanelContinuation; return; }
    for (const v of Object.values(o)) walk(v, depth + 1);
  };
  // a continuation response repeats the first page under contents
  walk(data?.continuationContents ?? data?.contents, 0);
  const list = found.list;
  const token = list?.continuations?.[0]?.nextRadioContinuationData?.continuation
    || list?.continuations?.[0]?.nextContinuationData?.continuation || "";
  return { items: Array.isArray(list?.contents) ? list.contents : [], continuation: token ? YTM_TOKEN + token : "" };
}

export function parsePanelVideo(item: any): SearchResult | null {
  const v = item?.playlistPanelVideoRenderer
    || item?.playlistPanelVideoWrapperRenderer?.primaryRenderer?.playlistPanelVideoRenderer;
  const id = v?.videoId;
  if (typeof id !== "string" || !id) return null;
  const segs = textOf(v.longBylineText).split(/\s+•\s+/).map((s: string) => s.trim());
  const views = musicViews(segs, "");
  return rememberMusic({
    id, title: decodeTitle(textOf(v.title)),
    channel: textOf(v.shortBylineText) || segs[0] || "",
    duration: parseDuration(textOf(v.lengthText)),
    thumbnail: musicThumb(v.thumbnail?.thumbnails) || `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
    ...(views ? { views } : {}),
    ...bylineInfo(v.longBylineText?.runs),
  });
}

// ---- YouTube Music track info, for tagging ----

// type: ATV is an art track (the album's audio), OMV an official music video, UGC an upload
export interface MusicWatchInfo {
  videoId: string;
  type: string;
  title: string;
  artist: string;            // the byline's artist segment, "A & B" as written
  artists?: string[];
  album?: string;
  albumId?: string;
  year?: number;
  cover: string;             // the largest thumbnail; square art only for an ATV
  counterpart?: MusicWatchInfo;   // an OMV's audio track, when YouTube Music pairs one
}

function watchInfoOf(v: any): MusicWatchInfo | null {
  if (typeof v?.videoId !== "string" || !v.videoId) return null;
  const type: string = v.navigationEndpoint?.watchEndpoint?.watchEndpointMusicSupportedConfigs
    ?.watchEndpointMusicConfig?.musicVideoType || "";
  const thumbs: any[] = (v.thumbnail?.thumbnails || []).filter((t: any) => typeof t?.url === "string");
  const segs = textOf(v.longBylineText).split(/\s+•\s+/).map((s: string) => s.trim());
  return {
    videoId: v.videoId, type: type.replace(/^MUSIC_VIDEO_TYPE_/, ""), title: decodeTitle(textOf(v.title)),
    artist: segs[0] || textOf(v.shortBylineText), cover: thumbs.length ? thumbs[thumbs.length - 1].url : "",
    ...bylineInfo(v.longBylineText?.runs),
  };
}

/** The asked-for track in a /next queue, with its audio counterpart when the queue pairs one. */
export function parseMusicWatchInfo(data: any, videoId: string): MusicWatchInfo | null {
  for (const item of panelItems(data).items) {
    const w = item?.playlistPanelVideoWrapperRenderer;
    const primary = watchInfoOf(w ? w.primaryRenderer?.playlistPanelVideoRenderer : item?.playlistPanelVideoRenderer);
    if (!primary || primary.videoId !== videoId) continue;
    const other = watchInfoOf(w?.counterpart?.[0]?.counterpartRenderer?.playlistPanelVideoRenderer);
    return other ? { ...primary, counterpart: other } : primary;
  }
  return null;
}

/** One track's YouTube Music info: /next for the video alone, one request. */
export async function fetchMusicWatchInfo(videoId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<MusicWatchInfo | null> {
  const data = await musicPost("next", { videoId, isAudioOnly: true, enablePersistentPlaylistPanel: true },
                               cookieSource, browser, profile);
  return parseMusicWatchInfo(data, videoId);
}

const isTrack = (t: SearchResult | null): t is SearchResult => t !== null;

/** The radio's queue as suggestions: the playing track left out, the one after it the autoplay. */
export function parseMusicNext(data: any, videoId: string): NextResult {
  const { items, continuation } = panelItems(data);
  const tracks = items.map(parsePanelVideo).filter(isTrack).filter((t) => t.id !== videoId);
  return { autoplay: tracks[0] ?? null, suggestions: tracks.slice(1), continuation, info: null };
}

export function parseMusicNextContinuation(data: any): { suggestions: SearchResult[]; continuation: string } {
  const { items, continuation } = panelItems(data);
  return { suggestions: items.map(parsePanelVideo).filter(isTrack), continuation };
}

const RADIO_BODY = { isAudioOnly: true, enablePersistentPlaylistPanel: true, tunerSettingValue: "AUTOMIX_SETTING_NORMAL" };

export async function fetchMusicNext(videoId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<NextResult> {
  return parseMusicNext(await musicPost("next", { videoId, playlistId: "RDAMVM" + videoId, ...RADIO_BODY },
                                        cookieSource, browser, profile), videoId);
}

export async function fetchMusicNextContinuation(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<{ suggestions: SearchResult[]; continuation: string }> {
  const raw = token.startsWith(YTM_TOKEN) ? token.slice(YTM_TOKEN.length) : token;
  return parseMusicNextContinuation(await musicPost("next", { continuation: raw, ...RADIO_BODY }, cookieSource, browser, profile));
}

/** A mix's queue from YouTube Music's /next, the seed included; null when it has none. */
export async function fetchMusicRadio(playlistId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<SearchResult[] | null> {
  const videoId = playlistId.startsWith("RDAMVM") ? playlistId.slice(6) : undefined;
  const data = await musicPost("next", { playlistId, ...(videoId ? { videoId } : {}), ...RADIO_BODY },
                               cookieSource, browser, profile);
  const tracks = panelItems(data).items.map(parsePanelVideo).filter(isTrack);
  return tracks.length ? tracks : null;
}

/**
 * Suggestions from the chosen source. YouTube Music's radio supplies the list;
 * YouTube's /next, asked alongside, supplies the track info and is the
 * fallback when YouTube Music fails or sends nothing.
 */
export async function nextFrom(source: DataSource, videoId: string, cookieSource: CookieSource, browser: string, profile: string): Promise<NextResult> {
  if (source !== "ytmusic") return fetchNext(videoId, cookieSource, browser, profile);
  const web = fetchNext(videoId, cookieSource, browser, profile)
    .catch((): NextResult => ({ autoplay: null, suggestions: [], continuation: "", info: null }));
  try {
    const m = await fetchMusicNext(videoId, cookieSource, browser, profile);
    if (m.autoplay || m.suggestions.length) return { ...m, info: (await web).info };
    ytmFallback("next", "no suggestions");
  } catch (e) { ytmFallback("next", e); }
  return web;
}

export async function nextContinuationFrom(token: string, cookieSource: CookieSource, browser: string, profile: string): Promise<{ suggestions: SearchResult[]; continuation: string }> {
  if (!token.startsWith(YTM_TOKEN)) return fetchNextContinuation(token, cookieSource, browser, profile);
  try { return await fetchMusicNextContinuation(token, cookieSource, browser, profile); }
  catch (e) {
    console.error(`[ytm] next continuation: ${String(e).split("\n")[0]}`);
    return { suggestions: [], continuation: "" };
  }
}
