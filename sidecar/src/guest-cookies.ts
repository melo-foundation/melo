import { dataDir } from "./env";
import { join } from "path";
import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync, renameSync, cpSync, readdirSync, chmodSync, openSync, closeSync, constants as fsc } from "fs";
import { spawn, spawnSync, type ChildProcess } from "child_process";
import { Socket } from "net";
import type { Readable, Writable } from "stream";
import { USER_AGENT } from "./platform";
import { ytdlp } from "./ytdlp";
import { makeTempDir, removeTempDir, trackChild } from "./ytdlp-proc";


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

// a file name holds 255 bytes, ".json" included; 64 astral letters are 256
const MAX_NAME_BYTES = 200;

// A profile name is a file name in the profiles folder, so it is a fixed
// charset (NFC): no separators, no leading dot, nothing Windows reserves
// (COM¹ included); 64 at most.
const PROFILE_NAME = /^[\p{L}\p{N}][\p{L}\p{M}\p{N} _.()'-]{0,63}$/u;
const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])$/i;
export const BAD_PROFILE_NAME = "Use letters, digits, spaces and _ - . ( ) ' for a profile name, up to 64, starting with a letter or digit.";

export function validProfileName(name: unknown): name is string {
  if (typeof name !== "string") return false;
  const n = name.normalize("NFC");
  return PROFILE_NAME.test(n) && !/[. ]$/.test(n) && !WINDOWS_RESERVED.test(n.split(".")[0].trim())
    && Buffer.byteLength(n) <= MAX_NAME_BYTES;
}

/** The name, NFC, when it is a valid profile name; throws BAD_PROFILE_NAME otherwise. */
export function checkProfileName(name: unknown): string {
  if (!validProfileName(name)) throw new Error(BAD_PROFILE_NAME);
  return name.normalize("NFC");
}

function cookiesJsonPath(profile: string): string {
  return join(profilesDir(), `${checkProfileName(profile)}.json`);
}

export function cookiesTxtPath(profile: string): string {
  return join(profilesDir(), `${checkProfileName(profile)}.txt`);
}

const sameName = (a: string, b: string): boolean =>
  a.normalize("NFC").toLowerCase() === b.normalize("NFC").toLowerCase();

/** Throws when a profile other than `except` already has this name, in any case:
 *  on a case-insensitive disk the two are one file. */
function refuseTaken(name: string, except?: string): void {
  const taken = profileFileNames().find((p) => sameName(p, name) && !(except !== undefined && sameName(p, except)));
  if (taken !== undefined) throw new Error(`A profile named ${taken} exists`);
}

function profileFileNames(): string[] {
  try {
    return [...new Set(readdirSync(profilesDir()).filter((f) => /\.(json|txt)$/.test(f)).map((f) => f.replace(/\.(json|txt)$/, "")))];
  } catch { return []; }
}

/** A valid name as close to `name` as the charset allows. */
// 64 code points (not UTF-16 units) within the byte budget, then no trailing dot, space or dash
const clipName = (s: string, max = 64): string => {
  const cps = [...s].slice(0, max);
  while (Buffer.byteLength(cps.join("")) > MAX_NAME_BYTES) cps.pop();
  return cps.join("").replace(/[. \-]+$/, "");
};

/** A valid name as close to `name` as the charset allows; "Profile" when
 *  nothing usable is left. Always passes validProfileName. */
export function sanitizeProfileName(name: string): string {
  let n = clipName(name.normalize("NFC")
    .replace(/&/g, " and ")
    .replace(/[:/\\|]+/g, " - ")
    .replace(/[^\p{L}\p{M}\p{N} _.()'-]+/gu, " ")
    .replace(/\s+/g, " ")
    .replace(/^[^\p{L}\p{N}]+/u, ""));
  // Windows reserves the part before the first dot: "COM1.txt" is COM1
  const [first, ...rest] = n.split(".");
  if (WINDOWS_RESERVED.test(first.trim())) n = clipName([`${first.trim()} profile`, ...rest].join("."));
  return validProfileName(n) ? n : "Profile";
}

/** migrateProfileNames, and the profile `current` names afterwards: its new
 *  name, or a valid one when it was invalid without a file. */
export function migrateProfiles(current: string): { moved: Map<string, string>; profile: string } {
  const moved = migrateProfileNames();
  const was = current || "Default";
  const profile = moved.get(was) ?? (validProfileName(was) ? was.normalize("NFC") : sanitizeProfileName(was));
  // never an unchecked name into settings
  return { moved, profile: validProfileName(profile) ? profile : "Default" };
}

/** Renames profile files whose names are no longer valid (or not NFC) to
 *  valid, distinct ones. Returns old name -> new name. Run once at start. */
export function migrateProfileNames(): Map<string, string> {
  const moved = new Map<string, string>();
  const names = profileFileNames();
  const keep = names.filter((n) => validProfileName(n) && n === n.normalize("NFC"));
  for (const old of names) {
    if (keep.includes(old)) continue;
    // a normalisation-insensitive disk (macOS) hands back NFD names and
    // finds the file under the NFC one: nothing to rename
    const nfc = old.normalize("NFC");
    if (validProfileName(nfc) && !keep.some((k) => sameName(k, nfc))
        && [".json", ".txt"].some((ext) => existsSync(join(profilesDir(), nfc + ext)))) {
      keep.push(nfc);
      continue;
    }
    const base = sanitizeProfileName(old);
    const free = (n: string): boolean => validProfileName(n) && !keep.some((k) => sameName(k, n));
    let next = base;
    for (let i = 2; !free(next); i++) {
      next = `${clipName(base, 60)} ${i}`;
      if (!free(next)) next = `Profile ${i}`;
    }
    for (const ext of [".json", ".txt"]) {
      const from = join(profilesDir(), old + ext);
      if (!existsSync(from)) continue;
      try { renameSync(from, join(profilesDir(), next + ext)); }
      catch (e: any) { console.error(`[guest-cookies] could not rename a profile file: ${e?.code ?? "error"}`); }
    }
    keep.push(next);
    moved.set(old, next);
    cachedCookies.delete(old);
  }
  return moved;
}

/** Profile names = the .json files in the profiles dir (Default if none). */
export function listProfiles(): string[] {
  try {
    const names = readdirSync(profilesDir())
      .filter((f) => f.endsWith(".json"))
      .map((f) => f.slice(0, -5))
      .filter(validProfileName)
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
  checkProfileName(profile);
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
  return parseNetscapeCookies(raw);
}

export function parseNetscapeCookies(raw: string): GuestCookie[] {
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

/** Splits CDP pipe traffic into messages: each is JSON ended by a NUL. */
export function cdpFrames(buf: string): { messages: string[]; rest: string } {
  const parts = buf.split("\0");
  return { messages: parts.slice(0, -1), rest: parts[parts.length - 1] };
}

function exited(child: ChildProcess, ms: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(false), ms);
    child.once("exit", () => { clearTimeout(t); resolve(true); });
  });
}

// Chrome's whole tree: the browser alone leaves its network service holding
// the Cookies file open, and the folder then cannot be removed.
async function endChrome(child: ChildProcess, send: (msg: object) => void): Promise<void> {
  try { send({ id: 2, method: "Browser.close" }); } catch { /* pipe gone */ }
  if (await exited(child, 5000)) return;
  if (process.platform === "win32" && child.pid !== undefined)
    spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  else child.kill("SIGKILL");
  await exited(child, 3000);
}

/**
 * Every cookie of a Chrome profile, read by Chrome itself: headless Chrome on a
 * temp copy of the profile, asked Storage.getCookies over --remote-debugging-pipe
 * (fd 3 in, fd 4 out). A pipe, not a port: no other process can ask it.
 */
export async function readChromeCookies(chromeExe: string, chromeDataDir: string, timeoutMs = 20000): Promise<any[]> {
  const tmpDir = makeTempDir("melo-chrome-");
  let chrome: ChildProcess | null = null;
  let send: (msg: object) => void = () => {};
  try {
    // Local State holds the key, Cookies the encrypted values
    mkdirSync(join(tmpDir, "Default", "Network"), { recursive: true });
    const localStateSrc = join(chromeDataDir, "Local State");
    if (existsSync(localStateSrc)) cpSync(localStateSrc, join(tmpDir, "Local State"));
    const cookiesSrc = existsSync(join(chromeDataDir, "Default", "Network", "Cookies"))
      ? join(chromeDataDir, "Default", "Network", "Cookies")
      : join(chromeDataDir, "Default", "Cookies");
    if (!existsSync(cookiesSrc)) throw new Error("Chrome Cookies file not found");
    cpSync(cookiesSrc, join(tmpDir, "Default", "Network", "Cookies"));
    const journalSrc = cookiesSrc + "-journal";
    if (existsSync(journalSrc)) cpSync(journalSrc, join(tmpDir, "Default", "Network", "Cookies-journal"));

    const proc = spawn(chromeExe, [
      `--user-data-dir=${tmpDir}`,
      "--remote-debugging-pipe",
      "--headless=new",
      "--disable-gpu",
      "--no-first-run",
      "--disable-features=Translate",
      "--disable-extensions",
      "--disable-sync",
      "about:blank",
    ], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
    chrome = proc;
    trackChild(proc);   // quitting melo mid-import ends it too
    const toChrome = proc.stdio[3] as Writable;
    const fromChrome = proc.stdio[4] as Readable;
    toChrome.on("error", () => { /* Chrome gone */ });
    send = (msg) => { toChrome.write(JSON.stringify(msg) + "\0"); };

    return await new Promise<any[]>((resolve, reject) => {
      let buf = "";
      const timer = setTimeout(() => reject(new Error("Chrome did not answer")), timeoutMs);
      const fail = (e: Error): void => { clearTimeout(timer); reject(e); };
      proc.once("error", fail);
      proc.once("exit", () => fail(new Error("Chrome exited before answering")));
      fromChrome.on("error", fail);
      fromChrome.on("data", (chunk: Buffer) => {
        const { messages, rest } = cdpFrames(buf + chunk.toString("utf-8"));
        buf = rest;
        for (const m of messages) {
          let msg: any;
          try { msg = JSON.parse(m); } catch { continue; }
          if (msg.id !== 1) continue;
          clearTimeout(timer);
          if (Array.isArray(msg.result?.cookies)) resolve(msg.result.cookies);
          else reject(new Error(msg.error?.message || "No cookies in response"));
        }
      });
      send({ id: 1, method: "Storage.getCookies" });
    });
  } finally {
    if (chrome) await endChrome(chrome, send);
    removeTempDir(tmpDir);
  }
}

/** Chrome's YouTube cookies on Windows, past App-Bound Encryption, into `profile`. */
async function importChromeViaCDP(profile: string): Promise<number> {
  const chromeExe = findChromeExe();
  if (!chromeExe) throw new Error("Chrome not found");
  const chromeDataDir = findChromeDataDir();
  if (!chromeDataDir) throw new Error("Chrome user data not found");

  const ytCookies = fromCdpCookies(await readChromeCookies(chromeExe, chromeDataDir));
  if (ytCookies.length > 0) {
    mergeGuestCookies(profile, ytCookies);
    console.log(`[guest-cookies:${profile}] Imported ${ytCookies.length} cookies from Chrome via CDP`);
  }
  return ytCookies.length;
}

/** Storage.getCookies' answer as guest cookies, YouTube's only. */
export function fromCdpCookies(raw: any[]): GuestCookie[] {
  return youtubeCookies(raw.filter((c: any) => typeof c?.domain === "string" && typeof c?.name === "string"))
    .map((c: any) => ({
      domain: c.domain.startsWith(".") ? c.domain : "." + c.domain,
      path: c.path || "/",
      secure: c.secure || false,
      expiry: c.expires > 0 ? Math.floor(c.expires) : Math.floor(Date.now() / 1000) + 86400 * 365,
      name: c.name,
      value: String(c.value ?? ""),
    }));
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

// yt-dlp's words when the keyring (KWallet, Secret Service) gave it no key:
// denied, timed out or missing. It goes on with an empty key and a jar
// without the encrypted cookies, which would read as signed out.
export const KEYRING_FAILED =
  /kwallet-query (failed|command not found)|failed to read from keyring|failed to read NetworkWallet|exception (while obtaining NetworkWallet|running kwallet-query)|secretstorage not available/i;

// The cookies a signed-in YouTube session carries; the encrypted ones a
// keyring denial loses.
const SIGN_IN_COOKIE = /^(SAPISID|APISID|SID|HSID|SSID|LOGIN_INFO|__Secure-[13]P(API)?SID)$/;
export function hasSignInCookie(cookies: { name: string }[]): boolean {
  return cookies.some((c) => SIGN_IN_COOKIE.test(c.name));
}

/** A browser store that could not be read: its keyring said no or did not answer. */
export class KeyringError extends Error {
  constructor(readonly stderr: string) { super("the browser's keyring gave no key"); }
}

// Longer than a keyring prompt is usually left open.
const DUMP_TIMEOUT_MS = 45000;

let fifoAllowed = true;
/** @internal test seam: false takes the no-FIFO path (Windows, root). */
export function useFifoForTest(on: boolean): void { fifoAllowed = on; }

/** Makes `path` a 0600 FIFO. False where there is none (Windows) or it failed. */
export function makeFifo(path: string): boolean {
  if (process.platform === "win32") return false;
  try { return spawnSync("mkfifo", ["-m", "600", path], { stdio: "ignore" }).status === 0; }
  catch { return false; }
}

/** Runs `run` while reading what it writes into the FIFO at `path`, so the
 *  text exists in memory only. The FIFO is made write-only first: yt-dlp loads
 *  a readable --cookies file before saving it, and would wait on melo. */
export async function readThroughFifo(path: string, run: () => Promise<unknown>): Promise<{ text: string; error: unknown }> {
  const rfd = openSync(path, fsc.O_RDONLY | fsc.O_NONBLOCK);
  // held while yt-dlp runs, so its close does not end the stream early
  const wfd = openSync(path, fsc.O_WRONLY | fsc.O_NONBLOCK);
  chmodSync(path, 0o200);
  const pipe = new Socket({ fd: rfd, readable: true, writable: false });
  const chunks: Buffer[] = [];
  const ended = new Promise<void>((resolve) => {
    pipe.on("data", (c: Buffer) => chunks.push(c));
    pipe.on("end", resolve);
    pipe.on("close", () => resolve());
    pipe.on("error", () => resolve());
  });
  let error: unknown = null;
  try { await run(); } catch (e) { error = e; }
  closeSync(wfd);
  await ended;
  pipe.destroy();
  return { text: Buffer.concat(chunks).toString("utf-8"), error };
}

// Reads a browser's cookie store (live browser mode and new profile from a
// browser) and keeps YouTube's cookies only. yt-dlp writes --cookies even when
// the URL fails; about:blank fails before any request, so nothing is fetched
// with the browser's identity. Only a missing or empty jar is a failure; then
// the exec error is thrown with its stderr. A keyring that gave no key throws
// KeyringError.
export async function dumpBrowserCookies(browser: string): Promise<GuestCookie[]> {
  const dir = makeTempDir("melo-cookies-");
  const file = join(dir, "cookies.txt");
  const args = ["--cookies-from-browser", browser, "--cookies", file, "--skip-download", "--flat-playlist", "about:blank"];
  let stderr = "";
  const run = async (): Promise<void> => {
    try { stderr = (await ytdlp(args, { timeout: DUMP_TIMEOUT_MS })).stderr; }
    catch (e: any) { stderr = String(e?.stderr ?? ""); throw e; }
  };
  try {
    let all: GuestCookie[];
    let exitError: any = null;
    // root may read a write-only FIFO, and yt-dlp would then wait on it
    if (fifoAllowed && process.getuid?.() !== 0 && makeFifo(file)) {
      const got = await readThroughFifo(file, run);
      exitError = got.error;
      all = parseNetscapeCookies(got.text);
    } else {
      // no FIFO: a 0600 file in the 0700 folder, removed once read. yt-dlp
      // loads a readable --cookies first and refuses one without this header.
      writeFileSync(file, "# Netscape HTTP Cookie File\n", { mode: 0o600 });
      try { await run(); } catch (e) { exitError = e; }
      all = existsSync(file) ? parseNetscapeCookieFile(file) : [];
    }
    const yt = youtubeCookies(all);
    // a Chromium read that ran out of time was waiting on a keyring prompt;
    // a keyring complaint with the sign-in cookies read anyway is not a denial
    if ((KEYRING_FAILED.test(stderr) || (exitError?.killed && !/^(firefox|safari)/i.test(browser)))
        && !hasSignInCookie(yt))
      throw new KeyringError(stderr);
    if (all.length === 0) throw exitError ?? new Error("yt-dlp wrote no cookies");
    return yt;
  } finally {
    removeTempDir(dir);
  }
}

/**
 * Import cookies from a browser via yt-dlp, filter to YouTube domains, and
 * merge into the guest cookie store. Returns number of cookies imported.
 */
export async function importBrowserCookies(browser: string, profile: string): Promise<number> {
  checkProfileName(profile);
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
  checkProfileName(profile);
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
  checkProfileName(profile);
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
  checkProfileName(profile);
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
  name = checkProfileName(name);
  refuseTaken(name);
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
  checkProfileName(name);
  console.log(`[guest-cookies] Deleting profile: ${name}`);
  cachedCookies.delete(name);
  try { unlinkSync(cookiesJsonPath(name)); } catch { /* ignore */ }
  try { unlinkSync(cookiesTxtPath(name)); } catch { /* ignore */ }
}

/**
 * Rename a cookie profile — renames files on disk and updates cache.
 */
export function renameProfile(oldName: string, newName: string): void {
  oldName = checkProfileName(oldName);
  newName = checkProfileName(newName);
  refuseTaken(newName, oldName);
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
