import { buildHeaders } from "./innertube";
import type { CookieSource } from "./settings";
import { captureResponseCookies } from "./guest-cookies";

const CPN_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

export function generateCPN(): string {
  let cpn = "";
  for (let i = 0; i < 16; i++) {
    cpn += CPN_CHARS[Math.floor(Math.random() * CPN_CHARS.length)];
  }
  return cpn;
}

const BASE = "https://www.youtube.com";
const CVER = "2.20260301.00.00";
const UA = "Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0";

// Cached tracking sessions keyed by CPN
interface TrackingSession {
  playbackUrl: string;
  delayplayUrl: string;
  watchtimeUrl: string;
  ptrackingUrl: string;
  atrUrl: string;
  qoeUrl: string;
  startTime: number;
  cpn: string;
  duration: string;
  videoId: string;
  channelId: string;
  cookieSource: CookieSource;
  browser: string;
  profile: string;
}

const sessions = new Map<string, TrackingSession>();

/** Build the extra params appended to tracking base URLs (matching real player behavior) */
function trackingParams(session: TrackingSession, extra: Record<string, string> = {}): string {
  const rt = ((Date.now() - session.startTime) / 1000).toFixed(3);
  const params = new URLSearchParams({
    cpn: session.cpn,
    ver: "2",
    cmt: "0",
    fmt: "251",
    fs: "0",
    rt,
    euri: "",
    lact: String(Math.floor(Math.random() * 2000) + 500),
    cl: "877086333",
    mos: "0",
    volume: "100",
    muted: "0",
    cbr: "Firefox",
    cbrver: "137.0",
    c: "WEB",
    cver: CVER,
    cplayer: "UNIPLAYER",
    cos: "X11",
    cplatform: "DESKTOP",
    hl: "en_US",
    cr: "US",
    ...extra,
  });
  return "&" + params.toString();
}

/** Headers for tracking GET requests (cookies + referer, no content-type) */
async function trkHeaders(
  cookieSource: CookieSource,
  browser: string,
  profile: string,
  videoId: string,
): Promise<Record<string, string>> {
  const headers = await buildHeaders(BASE, cookieSource, browser, profile);
  delete headers["Content-Type"];
  delete headers["X-Origin"];
  headers["User-Agent"] = UA;
  headers["Referer"] = `${BASE}/watch?v=${videoId}`;
  return headers;
}

export async function reportPlayback(
  videoId: string,
  duration: number,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
): Promise<string> {
  const cpn = generateCPN();
  const startTime = Date.now();

  // Fetch the watch page to extract real tracking URLs (with ei tokens)
  let session: TrackingSession | null = null;
  try {
    const pageHeaders = await buildHeaders(BASE, cookieSource, browser, profile);
    delete pageHeaders["Content-Type"];
    delete pageHeaders["X-Origin"];
    pageHeaders["User-Agent"] = UA;
    pageHeaders["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
    pageHeaders["Accept-Language"] = "en-US,en;q=0.5";

    const pageRes = await fetch(`${BASE}/watch?v=${videoId}`, { headers: pageHeaders });
    if (cookieSource === "guest") captureResponseCookies(profile, pageRes);
    const html = await pageRes.text();

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let playerData: any;
    for (const re of [
      /var\s+ytInitialPlayerResponse\s*=\s*(\{.+?\});\s*var\s+/s,
      /ytInitialPlayerResponse\s*=\s*(\{.+?\});\s*<\/script>/s,
    ]) {
      const m = html.match(re);
      if (m) {
        playerData = JSON.parse(m[1]);
        break;
      }
    }

    if (playerData?.playbackTracking) {
      const t = playerData.playbackTracking;
      session = {
        playbackUrl: t.videostatsPlaybackUrl?.baseUrl || "",
        delayplayUrl: t.videostatsDelayplayUrl?.baseUrl || "",
        watchtimeUrl: t.videostatsWatchtimeUrl?.baseUrl || "",
        ptrackingUrl: t.ptrackingUrl?.baseUrl || "",
        atrUrl: t.atrUrl?.baseUrl || "",
        qoeUrl: t.qoeUrl?.baseUrl || "",
        startTime,
        cpn,
        duration: String(playerData?.videoDetails?.lengthSeconds || Math.round(duration)),
        videoId,
        channelId: playerData?.videoDetails?.channelId || "",
        cookieSource,
        browser,
        profile,
      };
      sessions.set(cpn, session);
      console.log(
        `[watchtime] extracted tracking URLs for ${videoId}: ` +
          `pb=${!!session.playbackUrl} dp=${!!session.delayplayUrl} wt=${!!session.watchtimeUrl} pt=${!!session.ptrackingUrl}`,
      );
    } else {
      console.warn(`[watchtime] no playbackTracking in watch page for ${videoId}`);
    }
  } catch (err) {
    console.error("[watchtime] failed to load watch page:", err);
  }

  // Fire playback tracking
  if (session?.playbackUrl) {
    try {
      const url = session.playbackUrl + trackingParams(session);
      const headers = await trkHeaders(cookieSource, browser, profile, videoId);
      const res = await fetch(url, { headers });
      if (cookieSource === "guest") captureResponseCookies(profile, res);
      console.log(`[watchtime] playback reported for ${videoId}, cpn=${cpn}`);
    } catch (err) {
      console.error("[watchtime] playback report failed:", err);
    }
  } else {
    console.log(`[watchtime] playback skipped (no tracking URL) for ${videoId}, cpn=${cpn}`);
  }

  return cpn;
}

export async function reportDelayplay(
  videoId: string,
  cpn: string,
  duration: number,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
): Promise<void> {
  const session = sessions.get(cpn);
  if (!session) {
    console.log(`[watchtime] delayplay skipped — no session for cpn=${cpn}`);
    return;
  }

  const headers = await trkHeaders(cookieSource, browser, profile, videoId);

  // Fire delayplay
  if (session.delayplayUrl) {
    try {
      const url = session.delayplayUrl + trackingParams(session);
      const res = await fetch(url, { headers });
      if (cookieSource === "guest") captureResponseCookies(profile, res);
      console.log(`[watchtime] delayplay reported for ${videoId}, cpn=${cpn}`);
    } catch (err) {
      console.error("[watchtime] delayplay report failed:", err);
    }
  }

  // Fire ptracking
  if (session.ptrackingUrl) {
    try {
      const url = session.ptrackingUrl + "&cpn=" + cpn + "&oid=" + session.channelId;
      const res = await fetch(url, { headers });
      if (cookieSource === "guest") captureResponseCookies(profile, res);
      console.log(`[watchtime] ptracking reported for ${videoId}`);
    } catch (err) {
      console.error("[watchtime] ptracking report failed:", err);
    }
  }
}

export async function reportWatchtime(
  videoId: string,
  cpn: string,
  st: number,
  et: number,
  duration: number,
  cookieSource: CookieSource,
  browser: string,
  profile: string,
): Promise<void> {
  const session = sessions.get(cpn);
  const stR = String(Math.round(st));
  const etR = String(Math.round(et));

  if (session?.watchtimeUrl) {
    try {
      const url =
        session.watchtimeUrl +
        trackingParams(session, {
          st: stR,
          et: etR,
          cmt: etR,
          len: session.duration,
          state: "8",
          rtn: etR,
          rti: etR,
        });
      const headers = await trkHeaders(cookieSource, browser, profile, videoId);
      const res = await fetch(url, { headers });
      if (cookieSource === "guest") captureResponseCookies(profile, res);
      console.log(`[watchtime] watchtime reported for ${videoId}: ${stR}-${etR}`);
    } catch (err) {
      console.error("[watchtime] watchtime report failed:", err);
    }
  } else {
    // Fallback: minimal approach (won't feed recommendations but logs the attempt)
    try {
      const headers = await buildHeaders(BASE, cookieSource, browser, profile);
      delete headers["Content-Type"];
      headers["User-Agent"] = UA;
      const params = new URLSearchParams({
        docid: videoId,
        cpn,
        ver: "2",
        c: "WEB",
        cver: CVER,
        len: String(Math.round(duration)),
        st: stR,
        et: etR,
        ei: "",
        vm: "",
      });
      const url = `${BASE}/api/stats/watchtime?${params}`;
      const res = await fetch(url, { headers });
      if (cookieSource === "guest") captureResponseCookies(profile, res);
      console.log(`[watchtime] watchtime reported for ${videoId}: ${stR}-${etR} (fallback)`);
    } catch (err) {
      console.error("[watchtime] watchtime report failed:", err);
    }
  }
}
