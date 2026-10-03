// Every yt-dlp run, and every temporary folder one writes into, goes through
// here, so the sidecar can end them all when it exits.
//
// yt-dlp's release binary unpacks ~80 MB into TMPDIR on each start and runs as
// a parent and a child. Each run gets its own process group: killing the
// parent alone leaves the child running. It is stopped with SIGTERM, which lets
// it remove what it unpacked; SIGKILL leaves the 80 MB behind.

import { spawn, type ChildProcess } from "child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "fs";
import { homedir, tmpdir } from "os";
import { join } from "path";

const unixGroups = process.platform !== "win32";

/** Where yt-dlp unpacks and where melo's temporary folders go. */
export function privateTmp(): string {
  if (process.platform !== "linux") return tmpdir();
  const cache = process.env.XDG_CACHE_HOME || join(homedir(), ".cache");
  const dir = join(cache, "melo", "tmp");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

const running = new Set<ChildProcess>();
const tempDirs = new Set<string>();

/** A 0700 folder under privateTmp(), removed by removeTempDir or at exit. */
export function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(privateTmp(), prefix));
  tempDirs.add(dir);
  return dir;
}

export function removeTempDir(dir: string): void {
  tempDirs.delete(dir);
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* gone */ }
}

const KILL_GRACE_MS = 2000;

// SIGTERM to the group, then SIGKILL to whatever ignored it.
function stopTree(child: ChildProcess, grace = true): void {
  const pid = child.pid;
  if (pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  if (!unixGroups) {
    spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" });
    return;
  }
  try { process.kill(-pid, "SIGTERM"); } catch { return; }
  if (!grace) return;
  setTimeout(() => { try { process.kill(-pid, "SIGKILL"); } catch { /* gone */ } }, KILL_GRACE_MS).unref();
}

export interface RunOptions { timeout?: number; maxBuffer?: number }
export interface RunResult { stdout: string; stderr: string }

// A full disk shows up as PyInstaller failing to unpack a module.
const UNPACK_FAILED = /Failed to extract|No space left on device|Disk quota exceeded/;

/** Runs yt-dlp like execFile: resolves with its output on exit 0, rejects with
 *  an Error carrying code, signal, killed, stdout and stderr otherwise. */
export function runYtdlp(bin: string, args: string[], opts: RunOptions = {}): Promise<RunResult> {
  const maxBuffer = opts.maxBuffer ?? 1024 * 1024;
  const tmp = privateTmp();
  // nothing is unpacking now, so any unpack folder left is a leftover
  if (running.size === 0 && process.platform === "linux") sweepStale(tmp, []);
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      detached: unixGroups,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, TMPDIR: tmp, TMP: tmp, TEMP: tmp },
    });
    running.add(child);
    let stdout = "", stderr = "", killed = false, overflow = false;
    const stop = (): void => { killed = true; stopTree(child); };
    const timer = opts.timeout ? setTimeout(stop, opts.timeout) : null;
    const take = (which: "out" | "err") => (chunk: Buffer): void => {
      if (which === "out") stdout += chunk; else stderr += chunk;
      if (stdout.length + stderr.length > maxBuffer && !overflow) { overflow = true; stop(); }
    };
    child.stdout!.on("data", take("out"));
    child.stderr!.on("data", take("err"));
    child.on("error", (e) => { if (timer) clearTimeout(timer); running.delete(child); reject(e); });
    child.on("close", (code, signal) => {
      if (timer) clearTimeout(timer);
      running.delete(child);
      if (code === 0 && !killed) { resolve({ stdout, stderr }); return; }
      const why = overflow ? "output exceeded maxBuffer"
        : killed ? `timed out after ${opts.timeout} ms`
        : UNPACK_FAILED.test(stderr) ? `could not unpack into ${tmp}: the disk is full`
        : `exited with ${code ?? signal}`;
      const err: any = new Error(`yt-dlp ${why}\n${stderr.trim()}`);
      Object.assign(err, { code, signal, killed, stdout, stderr });
      reject(err);
    });
  });
}

/** Ends every running yt-dlp and removes every temporary folder. Synchronous,
 *  for the exit handler: process.exit() skips the finally blocks of pending
 *  work, and nothing can wait here, so runs only get SIGTERM; one that ignores
 *  it is ended by reapOrphans at the next start. */
export function shutdownYtdlp(): void {
  for (const child of running) stopTree(child, false);
  running.clear();
  for (const dir of tempDirs) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* gone */ }
  }
  tempDirs.clear();
}

process.on("exit", shutdownYtdlp);

const STALE_TEMP_MS = 10 * 60 * 1000;
const STALE_UNPACK_MS = 2 * 60 * 1000;
const TEMP_PREFIXES = ["melo-cookies-", "melo-subs-"];

function olderThan(path: string, ms: number, now: number): boolean {
  try { return now - statSync(path).mtimeMs > ms; } catch { return false; }
}

/** Removes what earlier runs left: melo's temporary folders (a cookie dump
 *  holds the browser's whole cookie jar in plain text) in `own` and `shared`,
 *  and yt-dlp's unpack folders in `own` only, since other programs unpack into
 *  a shared temp folder too. Returns how many it removed. */
export function sweepStale(
  own: string | null = process.platform === "linux" ? privateTmp() : null,
  shared: string[] = [tmpdir()],
  now = Date.now(),
): number {
  let removed = 0;
  const bases = [...(own ? [own] : []), ...shared.filter((d) => d !== own)];
  for (const base of bases) {
    let names: string[] = [];
    try { names = readdirSync(base); } catch { continue; }
    for (const name of names) {
      const path = join(base, name);
      const stale = TEMP_PREFIXES.some((p) => name.startsWith(p)) ? olderThan(path, STALE_TEMP_MS, now)
        : name.startsWith("_MEI") && base === own ? olderThan(path, STALE_UNPACK_MS, now)
        : false;
      if (!stale) continue;
      try { rmSync(path, { recursive: true, force: true }); removed++; } catch { /* not ours */ }
    }
  }
  return removed;
}

/** Linux: the pids of yt-dlp processes run from `bin` whose sidecar is gone
 *  (reparented to init or a systemd user manager). */
export function findOrphans(bin: string, procRoot = "/proc"): number[] {
  if (!existsSync(procRoot)) return [];
  const read = (p: string): string => { try { return readFileSync(p, "utf-8"); } catch { return ""; } };
  const runs = new Map<number, number>();   // pid -> ppid, for yt-dlp runs of `bin`
  for (const name of readdirSync(procRoot)) {
    if (!/^\d+$/.test(name)) continue;
    if (read(join(procRoot, name, "cmdline")).split("\0")[0] !== bin) continue;
    // the ppid is the 2nd field after the parenthesised command name
    const stat = read(join(procRoot, name, "stat"));
    runs.set(Number(name), Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]));
  }
  // an orphan, and the child it unpacked and started
  const orphans = [...runs].filter(([, ppid]) =>
    ppid === 1 || read(join(procRoot, String(ppid), "comm")).trim() === "systemd").map(([pid]) => pid);
  const children = [...runs].filter(([, ppid]) => orphans.includes(ppid)).map(([pid]) => pid);
  return [...orphans, ...children];
}

/** Ends yt-dlp processes an earlier sidecar left behind (it was killed before
 *  its exit handler ran). Returns how many. */
export function reapOrphans(bin: string): number {
  if (process.platform !== "linux") return 0;
  const pids = findOrphans(bin);
  let n = 0;
  for (const pid of pids) {
    try { process.kill(pid, "SIGTERM"); n++; } catch { /* gone */ }
  }
  setTimeout(() => { for (const pid of pids) { try { process.kill(pid, "SIGKILL"); } catch { /* gone */ } } }, KILL_GRACE_MS).unref();
  return n;
}
