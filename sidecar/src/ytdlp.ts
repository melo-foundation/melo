// yt-dlp lifecycle: seed into a user-writable dir on first run, self-update
// (nightly channel) at most once per day, plus on-failure update hooks.
// YouTube breaks extraction regularly; updates must not require app releases.

import { execFile } from "child_process";
import { promisify } from "util";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "fs";
import { dirname } from "path";
import { getEnv } from "./env";
import { loadSettings } from "./settings";
import { log } from "./rpc";

const execFileAsync = promisify(execFile);

const UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000;

/** A PyPI console_script / wheel install rather than the standalone binary.
 *  `--update-to` refuses these, so a pip yt-dlp never updates and eventually
 *  stops extracting; it is replaced with the release binary. */
export function isPipYtdlp(bin: string): boolean {
  if (!existsSync(bin)) return false;
  try {
    const head = readFileSync(bin, { encoding: "utf8" }).slice(0, 4096);
    if (head.includes("\0")) return false;   // a real binary, not a script
    return /from yt_dlp import/.test(head);
  } catch {
    return false;
  }
}

/** yt-dlp's own refusal, for the case where the check above missed it. */
function isPipUpdateError(e: unknown): boolean {
  const err = e as { message?: string; stderr?: string | Buffer };
  return /installed yt-dlp with pip or using the wheel/i.test(
    `${err?.message ?? ""}\n${err?.stderr ?? ""}`);
}

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

/** Release URL for a channel. Nightly lives in its own repo. */
export function ytdlpReleaseUrl(channel: string): string {
  const repo = channel === "nightly" ? "yt-dlp/yt-dlp-nightly-builds" : "yt-dlp/yt-dlp";
  return `https://github.com/${repo}/releases/latest/download/${ytdlpAssetName()}`;
}

/** Download yt-dlp from the official releases when no seed exists (packaged
 *  Windows installs ship without it). Fire-and-forget from initialize; streams
 *  requested before it lands fail, and work once it is there. */
export async function downloadYtdlp(opts?: { overwrite?: boolean }): Promise<boolean> {
  const dest = getEnv().ytdlpPath;
  if (existsSync(dest) && !opts?.overwrite) return true;
  const channel = ytdlpChannel();
  const url = ytdlpReleaseUrl(channel);
  try {
    log(opts?.overwrite
      ? `[ytdlp] replacing pip/wheel install with ${url}`
      : `[ytdlp] no binary — downloading ${url}`);
    const res = await fetch(url, { redirect: "follow" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    chmodSync(dest, 0o755);
    // Downloaded from the configured channel, so it is already current — let
    // the mtime throttle stand rather than forcing an update on next launch.
    log(`[ytdlp] downloaded to ${dest} (${(buf.length / 1048576).toFixed(1)} MB)`);
    return true;
  } catch (e) {
    log("[ytdlp] download failed:", String(e));
    return false;
  }
}

/** Configured update channel; stable unless the user opted into nightly. */
export function ytdlpChannel(): string {
  try {
    return loadSettings().ytdlpChannel === "nightly" ? "nightly" : "stable";
  } catch {
    return "stable";
  }
}

/** Daily self-update (mtime-throttled). Fire-and-forget from initialize. */
export async function maybeUpdateYtdlp(): Promise<void> {
  const bin = getEnv().ytdlpPath;
  if (!existsSync(bin)) return;
  // A pip install can never self-update; swap it for the release binary once,
  // then the normal throttled path takes over.
  if (isPipYtdlp(bin)) {
    if (await downloadYtdlp({ overwrite: true })) touch(bin);
    return;
  }
  try {
    const age = Date.now() - statSync(bin).mtimeMs;
    if (age < UPDATE_INTERVAL_MS) return;
    const channel = ytdlpChannel();
    log(`[ytdlp] running scheduled self-update (${channel})`);
    await execFileAsync(bin, ["--update-to", channel], { timeout: 120000 });
    touch(bin);   // refresh throttle even if already current
  } catch (e) {
    log("[ytdlp] self-update failed:", String(e));
    if (isPipUpdateError(e) && await downloadYtdlp({ overwrite: true })) touch(bin);
  }
}

/** On-failure escalation: called when extraction errors look like staleness. */
export async function updateNow(channel?: string): Promise<boolean> {
  const target = channel ?? ytdlpChannel();
  const bin = getEnv().ytdlpPath;
  if (isPipYtdlp(bin)) return downloadYtdlp({ overwrite: true });
  try {
    await execFileAsync(bin, ["--update-to", target], { timeout: 120000 });
    touch(bin);
    log(`[ytdlp] updated to ${target}`);
    return true;
  } catch (e) {
    log(`[ytdlp] update to ${target} failed:`, String(e));
    if (isPipUpdateError(e)) return downloadYtdlp({ overwrite: true });
    return false;
  }
}

export function looksStale(errorMessage: string): boolean {
  return /page needs to be reloaded|Requested format is not available|PO Token|sign in to confirm/i
    .test(errorMessage);
}
