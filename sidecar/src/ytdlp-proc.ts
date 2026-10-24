// Every yt-dlp run, and every temporary folder one writes into, goes through
// here, so the sidecar can end them all when it exits.
//
// yt-dlp's release binary unpacks ~80 MB into TMPDIR on each start and runs as
// a parent and a child. Each run gets its own process group: killing the
// parent alone leaves the child running. Each run also gets its own TMPDIR,
// removed when it exits: yt-dlp copies the browser's cookie database there.
// It is stopped with SIGINT, then SIGTERM, then SIGKILL: only SIGINT lets
// Python remove that copy (measured: SIGTERM leaves yt_dlp*/temporary.sqlite).

import { spawn, type ChildProcess } from "child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, statfsSync, symlinkSync } from "fs";
import { homedir, tmpdir } from "os";
import { basename, dirname, join } from "path";

const unixGroups = process.platform !== "win32";

export interface DirRoom { dir: string; free: number }   // free < 0: not usable

const UNPACK_ROOM = 512 * 1024 ** 2;

/** The first folder while it has room for a few unpacks, else the roomiest. */
export function chooseUnpackDir(dirs: DirRoom[]): string {
  const usable = dirs.filter((d) => d.free >= 0);
  if (!usable.length) return dirs[0].dir;
  if (usable[0].free >= UNPACK_ROOM) return usable[0].dir;
  return usable.reduce((a, b) => (b.free > a.free ? b : a)).dir;
}

// A folder that is ours: not a link, owned by this user.
function isOwnFolder(dir: string): boolean {
  try {
    const st = lstatSync(dir);
    return st.isDirectory() && !(process.getuid && st.uid !== process.getuid());
  } catch { return false; }
}

// A 0700 folder that is ours, made if missing.
function ownFolder(dir: string): string | null {
  try { mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch { return null; }
  return isOwnFolder(dir) ? dir : null;
}

function freeBytes(dir: string | null): number {
  if (!dir) return -1;
  try { const s = statfsSync(dir); return s.bavail * s.bsize; } catch { return -1; }
}

/** melo's own temporary folders on Linux: ~/.cache/melo/tmp, and a private one under /tmp. */
export function ownTmpDirs(): string[] {
  const cache = process.env.XDG_CACHE_HOME || join(homedir(), ".cache");
  return [join(cache, "melo", "tmp"), join(tmpdir(), `melo-${process.getuid ? process.getuid() : 0}`)];
}

/** Where yt-dlp unpacks and melo's temporary folders go: melo's cache folder,
 *  or /tmp when the cache's disk is short (a live session's home is tiny). */
export function privateTmp(): string {
  if (process.platform !== "linux") return tmpdir();
  const dirs = ownTmpDirs().map((d) => { const o = ownFolder(d); return { dir: o ?? d, free: freeBytes(o) }; });
  return chooseUnpackDir(dirs);
}

const running = new Set<ChildProcess>();
const tempDirs = new Set<string>();

/** A process the exit handler ends with the yt-dlp runs (headless Chrome). */
export function trackChild(child: ChildProcess): void {
  running.add(child);
  child.once("exit", () => running.delete(child));
}

/** A 0700 folder under privateTmp(), removed by removeTempDir or at exit. Its
 *  name carries this sidecar's pid, so a sweep can tell a dead run's folder. */
export function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(privateTmp(), `${prefix}${process.pid}-`));
  tempDirs.add(dir);
  return dir;
}

// Windows: a file still open in a process that is exiting fails with EBUSY.
const RM_RETRIES = { maxRetries: 5, retryDelay: 200 } as const;

/** Removes a temporary folder; false (and a log line) when it could not. */
export function removeTempDir(dir: string): boolean {
  tempDirs.delete(dir);
  try { rmSync(dir, { recursive: true, force: true, ...RM_RETRIES }); return true; }
  catch (e: any) {
    console.error(`[ytdlp-proc] could not remove ${dir}: ${e?.code ?? "error"}`);
    return false;
  }
}

const LOADER = "ld-linux-x86-64.so.2";
// glibc's own libraries and the zlib yt-dlp_linux's bootloader links: all it
// takes from a host (scripts/anylinux/ytdlp-needs.sh)
const LIBC_FILES = [LOADER, "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libutil.so.1",
  "libresolv.so.2", "libanl.so.1", "libnss_dns.so.2", "libnss_files.so.2", "libmvec.so.1", "libz.so.1"];

/** The anylinux AppImage's library folder (sharun's), when it carries a glibc loader. */
export function bundledLibDir(env: NodeJS.ProcessEnv = process.env,
                              platform: NodeJS.Platform = process.platform): string | null {
  if (platform !== "linux" || !env.SHARUN_DIR) return null;
  const lib = join(env.SHARUN_DIR, "shared", "lib");
  return existsSync(join(lib, LOADER)) ? lib : null;
}

const MUSL_LOADER = "/lib/ld-musl-x86_64.so.1";
const GLIBC_LOADER = `/lib64/${LOADER}`;

function readOrNull(path: string): Buffer | null {
  try { return readFileSync(path); } catch { return null; }
}

/** The host's libc is musl: its loader is there and no glibc loader is. Read from
 *  the files, since node in the anylinux AppImage runs on its own glibc. gcompat's
 *  ld-linux is a musl program; a glibc loader carries GLIBC_PRIVATE. */
export function hostIsMusl(exists: (path: string) => boolean = existsSync,
                           read: (path: string) => Buffer | null = readOrNull): boolean {
  if (!exists(MUSL_LOADER)) return false;
  const glibc = read(GLIBC_LOADER);
  return !glibc || !glibc.includes("GLIBC_PRIVATE");
}

const LIBC_PATHS = ["/lib/x86_64-linux-gnu/libc.so.6", "/lib64/libc.so.6", "/usr/lib/libc.so.6",
  "/usr/lib64/libc.so.6", "/lib/libc.so.6"];

/** The host glibc's [major, minor], from its banner ("release version 2.11.1"). */
export function hostGlibc(read: (path: string) => Buffer | null = readOrNull,
                          paths: string[] = LIBC_PATHS): [number, number] | null {
  for (const p of paths) {
    const m = /release version (\d+)\.(\d+)/.exec(read(p)?.toString("latin1") ?? "");
    if (m) return [Number(m[1]), Number(m[2])];
  }
  return null;
}

/** yt-dlp_linux asks for GLIBC_2.17 (scripts/anylinux/ytdlp-glibc.sh). A libc that
 *  cannot be read runs it as the host's. */
export function hostNeedsLibc(musl: () => boolean = hostIsMusl,
                              glibc: () => [number, number] | null = hostGlibc): boolean {
  if (musl()) return true;
  const v = glibc();
  return v !== null && (v[0] < 2 || (v[0] === 2 && v[1] < 17));
}

export interface BundledLibc { loader: string; libDir: string; bin: string }
let libc: BundledLibc | null | undefined;

/** In the anylinux AppImage, where the host cannot run yt-dlp_linux (musl before 1.2
 *  crashes yt-dlp_musllinux), it runs on the bundled glibc. A folder of links to glibc
 *  and zlib alone, so neither the host's libraries nor the rest of the bundle stand
 *  in for what PyInstaller unpacks. */
export function bundledLibc(): BundledLibc | null {
  if (libc !== undefined) return libc;
  libc = null;
  const lib = bundledLibDir();
  if (!lib || !hostNeedsLibc()) return null;
  try {
    const dir = makeTempDir("melo-libc-");
    for (const f of LIBC_FILES) if (existsSync(join(lib, f))) symlinkSync(join(lib, f), join(dir, f));
    libc = { loader: join(dir, LOADER), libDir: dir, bin: join(dirname(dirname(lib)), "bin") };
    console.error("[ytdlp-proc] yt-dlp runs on the bundled glibc");
  } catch (e: any) {
    console.error(`[ytdlp-proc] no folder for the bundled glibc: ${e?.code ?? e}`);
  }
  return libc;
}

/** LD_LIBRARY_PATH, not --library-path: PyInstaller starts its child through the
 *  loader again, without the loader's arguments. PATH holds the bundle's programs
 *  alone: a host program yt-dlp starts (Python's platform runs uname) would load this
 *  glibc under its own loader and crash. */
export function launchCommand(bin: string, argv: string[], env: NodeJS.ProcessEnv, via: BundledLibc | null):
    { file: string; args: string[]; env: NodeJS.ProcessEnv } {
  if (!via) return { file: bin, args: argv, env };
  return { file: via.loader, args: [bin, ...argv], env: { ...env, LD_LIBRARY_PATH: via.libDir, PATH: via.bin } };
}

const INT_GRACE_MS = 3000;
const KILL_GRACE_MS = 2000;

// SIGINT to the group, SIGTERM to what ignored it, then SIGKILL. Without a
// grace (the exit handler, which removes the run's folder itself): SIGTERM.
function stopTree(child: ChildProcess, grace = true): void {
  const pid = child.pid;
  if (pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  if (!unixGroups) {
    spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" });
    return;
  }
  try { process.kill(-pid, grace ? "SIGINT" : "SIGTERM"); } catch { return; }
  if (!grace) return;
  // Closed: the run and every child holding its pipes have exited, and the
  // group id may be another process's; no further signal. Exited alone is not
  // enough: the unpacked child can outlive its launcher.
  let closed = false;
  child.once("close", () => { closed = true; });
  const gone = (): boolean => closed;
  setTimeout(() => {
    if (gone()) return;
    try { process.kill(-pid, "SIGTERM"); } catch { return; }
    setTimeout(() => {
      if (gone()) return;
      try { process.kill(-pid, "SIGKILL"); } catch { /* gone */ }
    }, KILL_GRACE_MS).unref();
  }, INT_GRACE_MS).unref();
}

export interface RunOptions { timeout?: number; maxBuffer?: number }
export interface RunResult { stdout: string; stderr: string }

// The best stereo opus, then AAC: Premium's 774/141 where the account has them,
// else 251/140. Plain bestaudio picks TV itag 258, 6-channel AAC at ~3x the bytes.
export const AUDIO_FORMAT =
  "bestaudio[acodec=opus][audio_channels<=2]/bestaudio[ext=m4a][audio_channels<=2]/bestaudio[audio_channels<=2]/bestaudio/best";

// A full disk shows up as PyInstaller failing to unpack a module.
export const UNPACK_FAILED = /Failed to extract|No space left on device|Disk quota exceeded/;
export const unpackFailedMessage = (): string => `yt-dlp could not unpack into ${privateTmp()}: the disk is full`;

/** argv shows to every local user (/proc/<pid>/cmdline), and extractor args
 *  can hold a PO token and visitor_data: those go in on stdin as a config file. */
export function splitConfigArgs(args: string[]): { argv: string[]; config: string } {
  const argv: string[] = [], lines: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const v = args[i + 1];
    if (args[i] === "--extractor-args" && v !== undefined && !/['\\\n\r]/.test(v)) { lines.push(`--extractor-args '${v}'`); i++; }
    else argv.push(args[i]);
  }
  return lines.length ? { argv: ["--config-locations", "-", ...argv], config: lines.join("\n") + "\n" } : { argv, config: "" };
}

/** Runs yt-dlp like execFile: resolves with its output on exit 0, rejects with
 *  an Error carrying code, signal, killed, stdout and stderr otherwise. */
export function runYtdlp(bin: string, args: string[], opts: RunOptions = {}): Promise<RunResult> {
  const maxBuffer = opts.maxBuffer ?? 1024 * 1024;
  const { argv, config } = splitConfigArgs(args);
  // nothing is unpacking now, so any unpack folder left is a leftover
  if (running.size === 0) sweepStale();
  let tmp: string;
  try { tmp = makeTempDir("melo-run-"); } catch (e) { return Promise.reject(e); }
  return new Promise((resolve, reject) => {
    let child: ChildProcess;
    try {
      const run = launchCommand(bin, argv, { ...process.env, TMPDIR: tmp, TMP: tmp, TEMP: tmp }, bundledLibc());
      child = spawn(run.file, run.args, {
        detached: unixGroups,
        stdio: [config ? "pipe" : "ignore", "pipe", "pipe"],
        env: run.env,
      });
    } catch (e) { removeTempDir(tmp); reject(e); return; }
    if (config) { child.stdin!.on("error", () => { /* exited first */ }); child.stdin!.end(config); }
    running.add(child);
    // what the run left (an unpack, a cookie database copy) goes with it
    const finished = (): void => {
      running.delete(child);
      removeTempDir(tmp);
      if (running.size === 0) sweepStale();
    };
    let stdout = "", stderr = "", killed = false, overflow = false;
    const stop = (): void => { killed = true; stopTree(child); };
    const timer = opts.timeout ? setTimeout(stop, opts.timeout) : null;
    const take = (which: "out" | "err") => (chunk: Buffer): void => {
      if (which === "out") stdout += chunk; else stderr += chunk;
      if (stdout.length + stderr.length > maxBuffer && !overflow) { overflow = true; stop(); }
    };
    child.stdout!.on("data", take("out"));
    child.stderr!.on("data", take("err"));
    child.on("error", (e) => { if (timer) clearTimeout(timer); finished(); reject(e); });
    child.on("close", (code, signal) => {
      if (timer) clearTimeout(timer);
      finished();
      if (code === 0 && !killed) { resolve({ stdout, stderr }); return; }
      const why = overflow ? "output exceeded maxBuffer"
        : killed ? `timed out after ${opts.timeout} ms`
        : UNPACK_FAILED.test(stderr) ? unpackFailedMessage().replace(/^yt-dlp /, "")
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
const TEMP_PREFIXES = ["melo-cookies-", "melo-subs-", "melo-chrome-", "melo-run-", "melo-libc-"];

function olderThan(path: string, ms: number, now: number): boolean {
  try { return now - statSync(path).mtimeMs > ms; } catch { return false; }
}

function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (e: any) { return e?.code === "EPERM"; }
}

// A melo folder is stale once the sidecar named in it is gone; one without a
// pid (older builds) once it is old.
function staleMeloDir(path: string, rest: string, now: number): boolean {
  const pid = /^(\d+)-/.exec(rest)?.[1];
  if (pid === undefined) return olderThan(path, STALE_TEMP_MS, now);
  const n = Number(pid);
  return n === process.pid || !pidAlive(n);
}

/** Removes what earlier runs left: melo's temporary folders in `own` and
 *  `shared`, and yt-dlp's unpack folders and cookie database copies (yt_dlp*)
 *  in `own` only, since other programs use a shared temp folder too. Folders
 *  this sidecar still uses are kept. Returns how many it removed. */
export function sweepStale(
  own: string | string[] | null = process.platform === "linux" ? ownTmpDirs() : null,
  shared: string[] = [tmpdir()],
  now = Date.now(),
): number {
  let removed = 0;
  // a folder named like melo's but not ours (a link, another user's) is never swept
  const owned = (own === null ? [] : Array.isArray(own) ? own : [own]).filter(isOwnFolder);
  const bases = [...owned, ...shared.filter((d) => !owned.includes(d))];
  for (const base of bases) {
    let names: string[] = [];
    try { names = readdirSync(base); } catch { continue; }
    for (const name of names) {
      const path = join(base, name);
      if (tempDirs.has(path)) continue;
      const prefix = TEMP_PREFIXES.find((p) => name.startsWith(p));
      const stale = prefix !== undefined ? staleMeloDir(path, name.slice(prefix.length), now)
        : (name.startsWith("_MEI") || name.startsWith("yt_dlp")) && owned.includes(base)
          ? olderThan(path, STALE_UNPACK_MS, now)
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
    // through the bundled loader, the binary is the loader's first argument
    const argv = read(join(procRoot, name, "cmdline")).split("\0");
    if (argv[0] !== bin && !(basename(argv[0]) === LOADER && argv[1] === bin)) continue;
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
  const send = (sig: NodeJS.Signals): void => { for (const pid of pids) { try { process.kill(pid, sig); } catch { /* gone */ } } };
  for (const pid of pids) {
    try { process.kill(pid, "SIGINT"); n++; } catch { /* gone */ }
  }
  setTimeout(() => { send("SIGTERM"); setTimeout(() => send("SIGKILL"), KILL_GRACE_MS).unref(); }, INT_GRACE_MS).unref();
  return n;
}
