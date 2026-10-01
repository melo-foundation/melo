import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  findOrphans, makeTempDir, privateTmp, runYtdlp, shutdownYtdlp, sweepStale,
} from "./ytdlp-proc";

const linux = process.platform === "linux";
const alive = (pid: number): boolean => { try { process.kill(pid, 0); return true; } catch { return false; } };
const until = async (ok: () => boolean, ms = 3000): Promise<boolean> => {
  for (const end = Date.now() + ms; Date.now() < end; await new Promise((r) => setTimeout(r, 25))) if (ok()) return true;
  return ok();
};

// Stands in for yt-dlp's release binary: a parent that starts a child and
// waits on it, as PyInstaller's single-file build does.
describe.skipIf(!linux)("running yt-dlp", () => {
  const root = mkdtempSync(join(tmpdir(), "melo-proc-test-"));
  const fake = join(root, "yt-dlp");
  const pids = join(root, "pids");
  const oldCache = process.env.XDG_CACHE_HOME;

  beforeAll(() => {
    process.env.XDG_CACHE_HOME = join(root, "cache");
    writeFileSync(fake, `#!/bin/bash
case "$1" in
  tmpdir) echo "$TMPDIR"; exit 0 ;;
  full) echo "[PYI-1:ERROR] Failed to extract x.so: decompression resulted in return code -1!" >&2; exit 1 ;;
  hang) sleep 60 & echo "$$ $!" > "$2"; wait ;;
esac`);
    chmodSync(fake, 0o755);
  });
  afterAll(() => {
    process.env.XDG_CACHE_HOME = oldCache;
    rmSync(root, { recursive: true, force: true });
  });

  it("unpacks into melo's own folder, not /tmp", async () => {
    const { stdout } = await runYtdlp(fake, ["tmpdir"]);
    expect(stdout.trim()).toBe(join(root, "cache", "melo", "tmp"));
    expect(privateTmp()).toBe(join(root, "cache", "melo", "tmp"));
  });

  it("a timeout ends the child as well as the parent", async () => {
    const f = join(pids, "timeout");
    mkdirSync(pids, { recursive: true });
    const run = runYtdlp(fake, ["hang", f], { timeout: 500 });
    await expect(run).rejects.toMatchObject({ killed: true });
    const [parent, child] = readFileSync(f, "utf-8").trim().split(" ").map(Number);
    expect(await until(() => !alive(parent) && !alive(child))).toBe(true);
  });

  it("the sidecar exiting ends runs in flight and removes temporary folders", async () => {
    const f = join(pids, "exit");
    const run = runYtdlp(fake, ["hang", f]).catch(() => undefined);
    await until(() => existsSync(f));
    const dir = makeTempDir("melo-cookies-");
    writeFileSync(join(dir, "cookies.txt"), "secret");
    shutdownYtdlp();
    const [parent, child] = readFileSync(f, "utf-8").trim().split(" ").map(Number);
    expect(await until(() => !alive(parent) && !alive(child))).toBe(true);
    expect(existsSync(dir)).toBe(false);
    await run;
  });

  it("says the disk is full when yt-dlp cannot unpack", async () => {
    await expect(runYtdlp(fake, ["full"])).rejects.toThrow(/the disk is full/);
  });
});

describe("leftovers", () => {
  const root = mkdtempSync(join(tmpdir(), "melo-sweep-test-"));
  afterAll(() => rmSync(root, { recursive: true, force: true }));
  const old = (path: string, hoursAgo: number): void => {
    const t = new Date(Date.now() - hoursAgo * 3600e3);
    utimesSync(path, t, t);
  };

  it("removes old cookie dumps and unpack folders, keeps fresh ones and other programs'", () => {
    const own = join(root, "own"), shared = join(root, "shared");
    for (const d of [own, shared]) mkdirSync(d, { recursive: true });
    const mk = (base: string, name: string, hoursAgo: number): string => {
      const p = join(base, name); mkdirSync(p); old(p, hoursAgo); return p;
    };
    const oldDump = mk(shared, "melo-cookies-aaa", 5);
    const newDump = mk(shared, "melo-cookies-bbb", 0);
    const oldUnpack = mk(own, "_MEI123", 5);
    const othersUnpack = mk(shared, "_MEI456", 5);
    const oldSubs = mk(own, "melo-subs-ccc", 5);
    expect(sweepStale(own, [shared])).toBe(3);
    expect([oldDump, oldUnpack, oldSubs].some(existsSync)).toBe(false);
    expect([newDump, othersUnpack].every(existsSync)).toBe(true);
  });

  it("finds yt-dlp runs whose sidecar is gone, with their children", () => {
    const proc = join(root, "proc");
    const bin = "/home/u/.local/share/melo/bin/yt-dlp";
    const p = (pid: number, argv0: string, ppid: number, comm: string): void => {
      mkdirSync(join(proc, String(pid)), { recursive: true });
      writeFileSync(join(proc, String(pid), "cmdline"), `${argv0}\0--flat-playlist\0`);
      writeFileSync(join(proc, String(pid), "stat"), `${pid} (${comm}) S ${ppid} ${pid} ${pid} 0`);
      writeFileSync(join(proc, String(pid), "comm"), `${comm}\n`);
    };
    p(2228, "/usr/lib/systemd/systemd", 1, "systemd");
    p(500, "node", 400, "node");                 // a live sidecar
    p(10, bin, 2228, "yt-dlp");                  // orphan
    p(11, bin, 10, "yt-dlp");                    //   its child
    p(20, bin, 500, "yt-dlp");                   // a live run
    p(21, bin, 20, "yt-dlp");                    //   its child
    p(30, "/usr/bin/yt-dlp", 2228, "yt-dlp");    // someone else's yt-dlp
    expect(findOrphans(bin, proc).sort()).toEqual([10, 11]);
  });
});
