import { dataDir } from "./env";
import { join } from "path";
import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync, renameSync, cpSync, rmSync, readdirSync, mkdtempSync, chmodSync } from "fs";
import { execFile, spawn, type ChildProcess } from "child_process";
import { promisify } from "util";
import { tmpdir } from "os";
import { YTDLP, USER_AGENT } from "./platform";

const execFileAsync = promisify(execFile);

interface GuestCookie {
  domain: string;
  path: string;
  secure: boolean;
  expiry: number;
  name: string;
  value: string;
}

export interface Cookie {
  domain: string;
  name: string;
  value: string;
}


const cachedCookies = new Map<string, Cookie[]>();

function profilesDir(): string {
  return join(dataDir(), "guest-cookies");
}

function cookiesJsonPath(profile: string): string {
  return join(profilesDir(), `${profile}.json`);
}

export function cookiesTxtPath(profile: string): string {
  return join(profilesDir(), `${profile}.txt`);
}

/** Profile names = the .json files in the profiles dir (Default if none). */
export function listProfiles(): string[] {
  try {
    const names = readdirSync(profilesDir())
      .filter((f) => f.endsWith(".json"))
      .map((f) => f.slice(0, -5))
      .sort();
    return names.length ? names : ["Default"];
  } catch {
    return ["Default"];
  }
}

/**
 * Parse a single Set-Cookie header into structured data.
 */
function parseSetCookie(header: string): GuestCookie | null {
  const parts = header.split(";").map((s) => s.trim());
  if (parts.length === 0) return null;

  const [nameValue, ...attrs] = parts;
  const eqIdx = nameValue.indexOf("=");
  if (eqIdx < 0) return null;

  const name = nameValue.slice(0, eqIdx).trim();
  const value = nameValue.slice(eqIdx + 1).trim();
  if (!name) return null;

  let domain = ".youtube.com";
  let path = "/";
  let secure = false;
  let expiry = 0;

  for (const attr of attrs) {
    const lower = attr.toLowerCase();
    if (lower.startsWith("domain=")) {
      domain = attr.slice(7).trim();
      if (!domain.startsWith(".")) domain = "." + domain;
    } else if (lower.startsWith("path=")) {
      path = attr.slice(5).trim();
    } else if (lower === "secure") {
      secure = true;
    } else if (lower.startsWith("max-age=")) {
      const maxAge = parseInt(attr.slice(8).trim(), 10);
      if (!isNaN(maxAge)) {
        expiry = Math.floor(Date.now() / 1000) + maxAge;
      }
    } else if (lower.startsWith("expires=")) {
      const date = new Date(attr.slice(8).trim());
      if (!isNaN(date.getTime())) {
        expiry = Math.floor(date.getTime() / 1000);
      }
    }
  }

  // Session cookie — set expiry far in the future
  if (expiry === 0) {
    expiry = Math.floor(Date.now() / 1000) + 86400 * 365;
  }

  return { domain, path, secure, expiry, name, value };
}

/**
 * Fetch fresh guest cookies from YouTube.
 */
async function fetchGuestCookies(): Promise<GuestCookie[]> {
  const res = await fetch("https://www.youtube.com", {
    headers: { "User-Agent": USER_AGENT },
    redirect: "follow",
  });

  const setCookieHeaders = res.headers.getSetCookie();
  const cookies: GuestCookie[] = [];

  for (const header of setCookieHeaders) {
    const parsed = parseSetCookie(header);
    if (parsed) cookies.push(parsed);
  }

  return cookies;
}

function saveGuestCookies(profile: string, cookies: GuestCookie[]): void {
  mkdirSync(profilesDir(), { recursive: true, mode: 0o700 });
  writeFileSync(cookiesJsonPath(profile), JSON.stringify(cookies, null, 2), { mode: 0o600 });
  // mode on writeFileSync only applies when it creates the file, so an install
  // that predates this keeps 0644 until something says otherwise.
  tighten(cookiesJsonPath(profile));
}

// The cookie store defaults to a guest identity, but the browser-import path
// merges the user's real Google session into these same files. Every other
// account on the machine could read them at the default umask.
function tighten(path: string, mode = 0o600): void {
  try { chmodSync(path, mode); } catch { /* not ours, or gone */ }
}

function loadGuestCookies(profile: string): GuestCookie[] {
  try {
    const raw = readFileSync(cookiesJsonPath(profile), "utf-8");
    const cookies: GuestCookie[] = JSON.parse(raw);
    const now = Math.floor(Date.now() / 1000);
    return cookies.filter((c) => c.expiry > now);
  } catch {
    return [];
  }
}

/**
 * Merge new cookies into the guest cookie store (upsert by domain+name).
 * Also invalidates the in-memory cache so next read picks up changes.
 */
export function mergeGuestCookies(profile: string, newCookies: GuestCookie[]): void {
  if (newCookies.length === 0) return;

  const stored = loadGuestCookies(profile);
  const map = new Map<string, GuestCookie>();
  for (const c of stored) map.set(`${c.domain}\t${c.name}`, c);

  const newNames: string[] = [];
  const updatedNames: string[] = [];
  for (const c of newCookies) {
    const key = `${c.domain}\t${c.name}`;
    if (map.has(key)) updatedNames.push(c.name);
    else newNames.push(c.name);
    map.set(key, c);
  }

  const merged = Array.from(map.values());
  saveGuestCookies(profile, merged);
  cachedCookies.set(profile, merged.map((c) => ({ domain: c.domain, name: c.name, value: c.value })));

  if (newNames.length > 0) console.log(`[guest-cookies:${profile}] New cookies: ${newNames.join(", ")}`);
  if (updatedNames.length > 0) console.log(`[guest-cookies:${profile}] Updated cookies: ${updatedNames.join(", ")}`);
  console.log(`[guest-cookies:${profile}] Total: ${merged.length} cookies`);
}

/**
 * Extract Set-Cookie headers from a fetch Response and merge into guest store.
 */
export function captureResponseCookies(profile: string, res: Response): void {
  const setCookieHeaders = res.headers.getSetCookie();
  if (!setCookieHeaders || setCookieHeaders.length === 0) return;

  const cookies: GuestCookie[] = [];
  for (const header of setCookieHeaders) {
    const parsed = parseSetCookie(header);
    if (parsed) cookies.push(parsed);
  }

  if (cookies.length > 0) {
    console.log(`[guest-cookies:${profile}] Captured ${cookies.length} cookies from ${new URL(res.url).pathname}`);
    mergeGuestCookies(profile, cookies);
  }
}

/**
 * Parse a Netscape-format cookie file back into GuestCookie array.
 */
export function parseNetscapeCookieFile(path: string): GuestCookie[] {
  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch {
    return [];
  }

  const cookies: GuestCookie[] = [];
  for (const line of raw.split("\n")) {
    if (line.startsWith("#") || !line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 7) continue;
    let expiry = parseInt(parts[4], 10) || 0;
    // Session cookies (expiry 0) — set far-future expiry like parseSetCookie does
    if (expiry === 0) {
      expiry = Math.floor(Date.now() / 1000) + 86400 * 365;
    }
    cookies.push({
      domain: parts[0].trim(),
      path: parts[2].trim(),
      secure: parts[3].trim() === "TRUE",
      expiry,
      name: parts[5].trim(),
      value: parts[6].trim(),
    });
  }
  return cookies;
}

/**
 * Find Chrome executable on Windows.
 */
function findChromeExe(): string | null {
  if (process.platform !== "win32") return null;
  const candidates = [
    join(process.env.LOCALAPPDATA || "", "Google", "Chrome", "Application", "chrome.exe"),
    join(process.env.PROGRAMFILES || "", "Google", "Chrome", "Application", "chrome.exe"),
    join(process.env["PROGRAMFILES(X86)"] || "", "Google", "Chrome", "Application", "chrome.exe"),
  ];
  return candidates.find((p) => existsSync(p)) || null;
}

/**
 * Find Chrome's default user data directory on Windows.
 */
function findChromeDataDir(): string | null {
  if (process.platform !== "win32") return null;
  const dir = join(process.env.LOCALAPPDATA || "", "Google", "Chrome", "User Data");
  return existsSync(dir) ? dir : null;
}

/**
 * Extract cookies from Chrome on Windows over CDP. Chrome decrypts them itself,
 * which gets past App-Bound Encryption: headless Chrome on a temp copy of the
 * profile, then Storage.getCookies.
 */
async function importChromeViaCDP(profile: string): Promise<number> {
  const chromeExe = findChromeExe();
  if (!chromeExe) throw new Error("Chrome not found");

  const chromeDataDir = findChromeDataDir();
  if (!chromeDataDir) throw new Error("Chrome user data not found");

  // mkdtemp, not a Date.now() name: it creates at 0700 with a suffix nobody
  // can guess. Chrome's cookie DB and the CDP port that reads it are both
  // sitting in here, and the CDP port has no authentication of its own.
  const tmpDir = mkdtempSync(join(tmpdir(), "melo-chrome-"));
  let chromeProc: ChildProcess | null = null;

  try {
    // Copy minimal profile files so Chrome can decrypt cookies
    mkdirSync(join(tmpDir, "Default", "Network"), { recursive: true });

    // Local State has the encryption key
    const localStateSrc = join(chromeDataDir, "Local State");
    if (existsSync(localStateSrc)) cpSync(localStateSrc, join(tmpDir, "Local State"));

    // Cookies file (newer Chrome uses Network/ subfolder)
    const cookiesSrc = existsSync(join(chromeDataDir, "Default", "Network", "Cookies"))
      ? join(chromeDataDir, "Default", "Network", "Cookies")
      : join(chromeDataDir, "Default", "Cookies");
    if (!existsSync(cookiesSrc)) throw new Error("Chrome Cookies file not found");
    cpSync(cookiesSrc, join(tmpDir, "Default", "Network", "Cookies"));

    // Also copy Cookies-journal if it exists (SQLite WAL)
    const journalSrc = cookiesSrc + "-journal";
    if (existsSync(journalSrc)) cpSync(journalSrc, join(tmpDir, "Default", "Network", "Cookies-journal"));

    const port = 19222 + Math.floor(Math.random() * 10000);

    chromeProc = spawn(chromeExe, [
      `--user-data-dir=${tmpDir}`,
      `--remote-debugging-port=${port}`,
      "--headless=new",
      "--disable-gpu",
      "--no-first-run",
      "--disable-features=Translate",
      "--disable-extensions",
      "--disable-sync",
      "about:blank",
    ], { stdio: "ignore" });

    // Wait for Chrome to start and listen on the debug port
    let wsUrl = "";
    for (let attempt = 0; attempt < 20; attempt++) {
      await new Promise((r) => setTimeout(r, 500));
      try {
        const res = await fetch(`http://127.0.0.1:${port}/json/version`);
        const data = await res.json();
        wsUrl = data.webSocketDebuggerUrl;
        if (wsUrl) break;
      } catch { /* not ready yet */ }
    }
    if (!wsUrl) throw new Error("Chrome debugging port did not respond");

    // Connect via WebSocket and get cookies
    const cookies = await new Promise<any[]>((resolve, reject) => {
      const ws = new WebSocket(wsUrl);
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error("CDP timeout"));
      }, 10000);

      ws.onopen = () => {
        ws.send(JSON.stringify({ id: 1, method: "Storage.getCookies" }));
      };

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(String(event.data));
          if (msg.id === 1) {
            clearTimeout(timeout);
            ws.close();
            if (msg.result?.cookies) {
              resolve(msg.result.cookies);
            } else {
              reject(new Error(msg.error?.message || "No cookies in response"));
            }
          }
        } catch (err) {
          clearTimeout(timeout);
          ws.close();
          reject(err);
        }
      };

      ws.onerror = (err) => {
        clearTimeout(timeout);
        reject(new Error("WebSocket error: " + String(err)));
      };
    });

    // Filter to YouTube/Google cookies and convert to GuestCookie format
    const ytCookies: GuestCookie[] = cookies
      .filter((c: any) => c.domain.includes("youtube.com") || c.domain.includes("google.com"))
      .map((c: any) => ({
        domain: c.domain.startsWith(".") ? c.domain : "." + c.domain,
        path: c.path || "/",
        secure: c.secure || false,
        expiry: c.expires > 0 ? Math.floor(c.expires) : Math.floor(Date.now() / 1000) + 86400 * 365,
        name: c.name,
        value: c.value,
      }));

    if (ytCookies.length > 0) {
      mergeGuestCookies(profile, ytCookies);
      console.log(`[guest-cookies:${profile}] Imported ${ytCookies.length} cookies from Chrome via CDP`);
    }

    return ytCookies.length;
  } finally {
    if (chromeProc) {
      try { chromeProc.kill(); } catch { /* ignore */ }
    }
    try { rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
  }
}

// A guest profile is YouTube's cookies and nothing else: youtube.com and its
// subdomains, matched as a browser matches a cookie domain, so no google.com
// cookie (.google.com.br included) gets in.
export function youtubeCookies<T extends { domain: string }>(cookies: T[]): T[] {
  return cookies.filter((c) => {
    const d = c.domain.replace(/^\./, "").toLowerCase();
    return d === "youtube.com" || d.endsWith(".youtube.com");
  });
}

// Reads a browser's cookie store (live browser mode and new profile from a
// browser). yt-dlp writes --cookies before it touches the URL, so a refusal on
// that video exits 1 with the jar already on disk. Only a missing or empty jar
// is a failure; then the exec error is thrown with its stderr.
export async function dumpBrowserCookies(browser: string): Promise<GuestCookie[]> {
  // mkdtemp: for the seconds this runs the file is the user's logged-in
  // Google session in plaintext, so its name must not be guessable
  const dir = mkdtempSync(join(tmpdir(), "melo-cookies-"));
  const file = join(dir, "cookies.txt");
  try {
    let exitError: any = null;
    try {
      await execFileAsync(
        YTDLP(),
        [
          "--cookies-from-browser", browser,
          "--cookies", file,
          "--skip-download",
          "--flat-playlist",
          "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        ],
        { timeout: 15000 },
      );
    } catch (e) {
      exitError = e;
    }
    const all = existsSync(file) ? parseNetscapeCookieFile(file) : [];
    if (all.length === 0) throw exitError ?? new Error("yt-dlp wrote no cookies");
    return all;
  } finally {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
  }
}

/**
 * Import cookies from a browser via yt-dlp, filter to YouTube domains, and
 * merge into the guest cookie store. Returns number of cookies imported.
 */
export async function importBrowserCookies(browser: string, profile: string): Promise<number> {
  let all: GuestCookie[];
  try {
    all = await dumpBrowserCookies(browser);
  } catch (e: any) {
    const stderr = e?.stderr || String(e);
    if (stderr.includes("Failed to decrypt with DPAPI")) {
      // Chrome on Windows: App-Bound Encryption blocks yt-dlp.
      // Try extracting via CDP (let Chrome itself decrypt).
      if (process.platform === "win32" && browser.toLowerCase().startsWith("chrome")) {
        console.log("[guest-cookies] DPAPI failed, trying Chrome CDP fallback...");
        return importChromeViaCDP(profile);
      }
      throw new Error("Failed to decrypt with DPAPI");
    }
    throw e;
  }

  const ytCookies = youtubeCookies(all);
  if (ytCookies.length > 0) {
    mergeGuestCookies(profile, ytCookies);
    console.log(`[guest-cookies:${profile}] Imported ${ytCookies.length} cookies from ${browser}`);
  }
  return ytCookies.length;
}

/**
 * Main entry point. Returns cached → disk → fresh-fetch cookies.
 */
export async function getGuestCookies(profile: string): Promise<Cookie[]> {
  const cached = cachedCookies.get(profile);
  if (cached) return cached;

  let stored = loadGuestCookies(profile);
  if (stored.length === 0) {
    console.log(`[guest-cookies:${profile}] No stored cookies, fetching fresh...`);
    stored = await fetchGuestCookies();
    if (stored.length > 0) {
      saveGuestCookies(profile, stored);
      console.log(`[guest-cookies:${profile}] Saved ${stored.length} cookies`);
    }
  } else {
    console.log(`[guest-cookies:${profile}] Loaded ${stored.length} cookies from disk`);
  }

  const result = stored.map((c) => ({ domain: c.domain, name: c.name, value: c.value }));
  cachedCookies.set(profile, result);
  return result;
}

/** Content last written per profile, so an unchanged store skips the write. */
const lastWritten = new Map<string, string>();

export async function writeNetscapeCookieFile(profile: string): Promise<string> {
  let stored = loadGuestCookies(profile);
  if (stored.length === 0) {
    stored = await fetchGuestCookies();
    if (stored.length > 0) saveGuestCookies(profile, stored);
  }

  const lines = ["# Netscape HTTP Cookie File"];
  for (const c of stored) {
    const flag = c.domain.startsWith(".") ? "TRUE" : "FALSE";
    const secureTxt = c.secure ? "TRUE" : "FALSE";
    lines.push(`${c.domain}\t${flag}\t${c.path}\t${secureTxt}\t${c.expiry}\t${c.name}\t${c.value}`);
  }

  const path = cookiesTxtPath(profile);
  const body = lines.join("\n") + "\n";
  // Called on EVERY stream resolve, on the path the player is waiting on.
  // The store usually hasn't changed between tracks, so skip the write when
  // the file already holds exactly this content.
  if (lastWritten.get(profile) === body && existsSync(path)) return path;
  mkdirSync(profilesDir(), { recursive: true, mode: 0o700 });
  writeFileSync(path, body, { mode: 0o600 });
  tighten(path);
  lastWritten.set(profile, body);
  return path;
}

/**
 * Reset guest session — clear everything and fetch fresh cookies.
 */
export async function resetGuestSession(profile: string): Promise<void> {
  cachedCookies.delete(profile);
  try { unlinkSync(cookiesJsonPath(profile)); } catch { /* ignore */ }
  try { unlinkSync(cookiesTxtPath(profile)); } catch { /* ignore */ }

  console.log(`[guest-cookies:${profile}] Session reset, fetching fresh cookies...`);
  const fresh = await fetchGuestCookies();
  if (fresh.length > 0) {
    saveGuestCookies(profile, fresh);
    console.log(`[guest-cookies:${profile}] New session: ${fresh.length} cookies`);
  }
  cachedCookies.set(profile, fresh.map((c) => ({ domain: c.domain, name: c.name, value: c.value })));
}

/**
 * Clear in-memory cache (all profiles or a specific one).
 */
export function clearGuestCache(profile?: string): void {
  if (profile) {
    cachedCookies.delete(profile);
  } else {
    cachedCookies.clear();
  }
}

/**
 * Create a new cookie profile with fresh cookies.
 */
export async function createProfile(name: string): Promise<void> {
  console.log(`[guest-cookies] Creating profile: ${name}`);
  const fresh = await fetchGuestCookies();
  if (fresh.length > 0) {
    saveGuestCookies(name, fresh);
    console.log(`[guest-cookies:${name}] Created with ${fresh.length} cookies`);
  }
  cachedCookies.set(name, fresh.map((c) => ({ domain: c.domain, name: c.name, value: c.value })));
}

/**
 * Delete a cookie profile — removes JSON + TXT files and cache.
 */
export function deleteProfile(name: string): void {
  console.log(`[guest-cookies] Deleting profile: ${name}`);
  cachedCookies.delete(name);
  try { unlinkSync(cookiesJsonPath(name)); } catch { /* ignore */ }
  try { unlinkSync(cookiesTxtPath(name)); } catch { /* ignore */ }
}

/**
 * Rename a cookie profile — renames files on disk and updates cache.
 */
export function renameProfile(oldName: string, newName: string): void {
  console.log(`[guest-cookies] Renaming profile: ${oldName} → ${newName}`);
  const cached = cachedCookies.get(oldName);
  if (cached) {
    cachedCookies.set(newName, cached);
    cachedCookies.delete(oldName);
  }

  try {
    if (existsSync(cookiesJsonPath(oldName))) {
      renameSync(cookiesJsonPath(oldName), cookiesJsonPath(newName));
    }
  } catch (err) {
    console.error(`[guest-cookies] Failed to rename JSON:`, err);
  }

  try {
    if (existsSync(cookiesTxtPath(oldName))) {
      renameSync(cookiesTxtPath(oldName), cookiesTxtPath(newName));
    }
  } catch (err) {
    console.error(`[guest-cookies] Failed to rename TXT:`, err);
  }
}
