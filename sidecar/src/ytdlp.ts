// yt-dlp lifecycle: seed into a user-writable dir on first run, update at most
// once per day and when the user switches channel. YouTube breaks extraction
// regularly; updates must not require app releases. Every binary installed here
// matches a SHA2-256SUMS entry signed by yt-dlp's pinned release key.

import { execFile } from "child_process";
import { promisify } from "util";
import { createHash } from "crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "fs";
import { dirname } from "path";
import * as openpgp from "openpgp";
import { YTDLP_KEY_FINGERPRINT, YTDLP_PUBLIC_KEY } from "./ytdlp-key";
import { getEnv } from "./env";
import { loadSettings } from "./settings";
import { log, notify } from "./rpc";

const execFileAsync = promisify(execFile);

const UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000;

function touch(bin: string): void {
  const now = new Date();
  utimesSync(bin, now, now);
}

/** Ensure the binary exists at env.ytdlpPath; seed from seedPath if provided. */
export function ensureYtdlp(seedPath?: string): boolean {
  const dest = getEnv().ytdlpPath;
  if (existsSync(dest)) return true;
  if (seedPath && existsSync(seedPath)) {
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(seedPath, dest);
    chmodSync(dest, 0o755);
    log(`[ytdlp] seeded from ${seedPath}`);
    return true;
  }
  return false;
}

/** Release asset name for this platform (yt-dlp publishes per-OS binaries). */
export function ytdlpAssetName(platform: NodeJS.Platform = process.platform): string {
  if (platform === "win32") return "yt-dlp.exe";
  if (platform === "darwin") return "yt-dlp_macos";
  return "yt-dlp_linux";
}

function releaseRepo(channel: string): string {
  return channel === "nightly" ? "yt-dlp/yt-dlp-nightly-builds" : "yt-dlp/yt-dlp";
}

/** Release URL for a channel's file (the binary by default). Nightly lives in its own repo. */
export function ytdlpReleaseUrl(channel: string, file: string = ytdlpAssetName()): string {
  return `https://github.com/${releaseRepo(channel)}/releases/latest/download/${file}`;
}

interface Trust { armoredKey: string; fingerprint: string; checkElf: boolean }
let trust: Trust = { armoredKey: YTDLP_PUBLIC_KEY, fingerprint: YTDLP_KEY_FINGERPRINT, checkElf: true };

/** Tests only: swap the pinned key for a generated one and allow script binaries. */
export function setYtdlpTrustForTests(t: Trust): void {
  trust = t;
}

/** A verification failure, as opposed to a network one: retrying will not fix it. */
class Refused extends Error {}

async function fetchBytes(url: string, timeoutMs: number): Promise<Buffer> {
  const res = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

type Progress = (received: number, total: number) => void;

const PROGRESS_INTERVAL_MS = 250;

/** fetchBytes that reads the body as it arrives and reports it at most every
 *  PROGRESS_INTERVAL_MS, plus once at the end. total is 0 without Content-Length. */
async function fetchStreamed(url: string, timeoutMs: number, onProgress: Progress): Promise<Buffer> {
  const res = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  if (!res.body) return Buffer.from(await res.arrayBuffer());
  const total = Number(res.headers.get("content-length")) || 0;
  const chunks: Uint8Array[] = [];
  let received = 0;
  let last = 0;
  const reader = res.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.byteLength;
    const now = Date.now();
    if (now - last >= PROGRESS_INTERVAL_MS) { last = now; onProgress(received, total); }
  }
  onProgress(received, total);
  return Buffer.concat(chunks);
}

const sha256 = (buf: Buffer): string => createHash("sha256").update(buf).digest("hex");

/** The asset's sha256 from the channel's SHA2-256SUMS, trusted only after its
 *  detached signature verifies against the pinned key. */
async function verifiedHash(channel: string): Promise<string> {
  const [sums, sig] = await Promise.all([
    fetchBytes(ytdlpReleaseUrl(channel, "SHA2-256SUMS"), 30000),
    fetchBytes(ytdlpReleaseUrl(channel, "SHA2-256SUMS.sig"), 30000),
  ]);
  const key = await openpgp.readKey({ armoredKey: trust.armoredKey });
  if (key.getFingerprint().toLowerCase() !== trust.fingerprint.toLowerCase())
    throw new Refused(`signing key fingerprint ${key.getFingerprint()} is not the pinned ${trust.fingerprint}`);
  const signature = sig.subarray(0, 10).toString("latin1").startsWith("-----BEGIN")
    ? await openpgp.readSignature({ armoredSignature: sig.toString("utf8") })
    : await openpgp.readSignature({ binarySignature: new Uint8Array(sig) });
  try {
    const { signatures } = await openpgp.verify({
      message: await openpgp.createMessage({ binary: new Uint8Array(sums) }),
      signature,
      verificationKeys: key,
      expectSigned: true,
    });
    await signatures[0].verified;
  } catch (e) {
    throw new Refused(`SHA2-256SUMS signature does not verify: ${(e as Error).message}`);
  }
  const asset = ytdlpAssetName();
  for (const line of sums.toString("utf8").split("\n")) {
    const m = /^([0-9a-f]{64})\s+\*?(\S+)\s*$/i.exec(line);
    if (m && m[2] === asset) return m[1].toLowerCase();
  }
  throw new Refused(`SHA2-256SUMS has no entry for ${asset}`);
}

// Windows runs executables by extension, so the staging copy keeps .exe.
function partPath(dest: string): string {
  return process.platform === "win32" ? dest.replace(/\.exe$/i, "") + ".part.exe" : dest + ".part";
}

const ELF_MAGIC = Buffer.from([0x7f, 0x45, 0x4c, 0x46]);

/** Download to a staging file beside dest, check it, then rename it over dest,
 *  so dest only ever holds a verified binary. */
async function installVerified(channel: string, expected: string, onProgress?: Progress): Promise<void> {
  const dest = getEnv().ytdlpPath;
  const part = partPath(dest);
  const url = ytdlpReleaseUrl(channel);
  log(`[ytdlp] downloading ${url}`);
  const buf = await fetchStreamed(url, 300000, onProgress ?? (() => {}));
  const got = sha256(buf);
  if (got !== expected) throw new Refused(`sha256 of ${url} is ${got}, SHA2-256SUMS lists ${expected}`);
  if (process.platform === "linux" && trust.checkElf && !buf.subarray(0, 4).equals(ELF_MAGIC))
    throw new Refused(`${url} is not an ELF binary`);
  mkdirSync(dirname(dest), { recursive: true });
  try {
    writeFileSync(part, buf);
    chmodSync(part, 0o755);
    try {
      await execFileAsync(part, ["--version"], { timeout: 20000 });
    } catch (e) {
      throw new Refused(`the downloaded binary failed --version: ${String(e).split("\n")[0]}`);
    }
    renameSync(part, dest);
  } finally {
    rmSync(part, { force: true });
  }
  log(`[ytdlp] installed ${channel} build to ${dest} (${(buf.length / 1048576).toFixed(1)} MB)`);
}

type Outcome = "ok" | "refused" | "failed";

/** Bring dest to the channel's verified release: nothing to do when the
 *  installed binary already hashes to the signed entry. */
async function syncOnce(channel: string): Promise<Outcome> {
  const dest = getEnv().ytdlpPath;
  const firstRun = !existsSync(dest);
  if (firstRun) notify("ytdlp/status", { state: "downloading" });
  let outcome: Outcome;
  try {
    const expected = await verifiedHash(channel);
    if (!firstRun && sha256(readFileSync(dest)) === expected) {
      log(`[ytdlp] ${channel} build is current`);
    } else {
      // Progress is reported only for the first-run download, the one the UI shows.
      await installVerified(channel, expected, firstRun
        ? (received, total) => notify("ytdlp/status", { state: "downloading", received, total })
        : undefined);
    }
    outcome = "ok";
  } catch (e) {
    outcome = e instanceof Refused ? "refused" : "failed";
    log(outcome === "refused"
      ? `[ytdlp] update refused: ${(e as Error).message}`
      : `[ytdlp] download failed: ${String(e)}`);
  }
  // A refusal will not clear up within the day, so it holds the throttle too;
  // a network failure does not, and the next launch retries.
  if (outcome !== "failed" && existsSync(dest)) touch(dest);
  if (firstRun) notify("ytdlp/status", { state: outcome === "ok" ? "" : "failed" });
  return outcome;
}

let pending: { channel: string; run: Promise<Outcome> } | null = null;

/** Concurrent calls for one channel share a run; a different channel waits
 *  for the current run, since both stage to the same .part file. */
function sync(channel: string): Promise<Outcome> {
  if (pending?.channel === channel) return pending.run;
  const before = (pending?.run ?? Promise.resolve()).catch(() => undefined);
  const job = { channel, run: before.then(() => syncOnce(channel)) };
  job.run = job.run.finally(() => { if (pending === job) pending = null; });
  pending = job;
  return job.run;
}

/** The yt-dlp path once the binary exists. On a first run the download started
 *  by initialize may still be going; every caller waits on that one download. */
export async function ytdlpReady(): Promise<string> {
  const bin = getEnv().ytdlpPath;
  if (existsSync(bin)) return bin;
  const outcome = await sync(ytdlpChannel());
  if (outcome === "refused") throw new Error("yt-dlp could not be verified; not installed");
  if (outcome === "failed") throw new Error("yt-dlp could not be downloaded; check the connection and try again");
  return bin;
}

/** First-run install from the official releases when no seed exists. */
export async function downloadYtdlp(): Promise<boolean> {
  if (existsSync(getEnv().ytdlpPath)) return true;
  return (await sync(ytdlpChannel())) === "ok";
}

/** Configured update channel; stable unless the user opted into nightly. */
export function ytdlpChannel(): string {
  try {
    return loadSettings().ytdlpChannel === "nightly" ? "nightly" : "stable";
  } catch {
    return "stable";
  }
}

/** Daily update (mtime-throttled). Fire-and-forget from initialize. */
export async function maybeUpdateYtdlp(): Promise<void> {
  const bin = getEnv().ytdlpPath;
  if (!existsSync(bin)) return;
  if (Date.now() - statSync(bin).mtimeMs < UPDATE_INTERVAL_MS) return;
  log(`[ytdlp] scheduled update check (${ytdlpChannel()})`);
  await sync(ytdlpChannel());
}

/** Immediate update, used when the user switches channel. */
export async function updateNow(channel?: string): Promise<boolean> {
  return (await sync(channel ?? ytdlpChannel())) === "ok";
}

export function looksStale(errorMessage: string): boolean {
  return /page needs to be reloaded|Requested format is not available|PO Token|sign in to confirm/i
    .test(errorMessage);
}
