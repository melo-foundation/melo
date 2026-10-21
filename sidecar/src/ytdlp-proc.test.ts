import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { spawnSync } from "child_process";
import {
  chooseUnpackDir, findOrphans, makeTempDir, privateTmp, runYtdlp, shutdownYtdlp, splitConfigArgs, sweepStale,
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
  # like PyInstaller's launcher: unpacks, removes the folder on SIGTERM, not on SIGKILL
  unpack) d="$TMPDIR/_MEItest$$"; mkdir -p "$d"; trap 'rm -rf "$d"; exit 143' TERM
          sleep 60 & echo "$$ $! $d" > "$2"; wait ;;
  # like yt-dlp reading a browser: Python removes its database copy on SIGINT only
  copy) d="$TMPDIR/yt_dlptest$$"; mkdir -p "$d"; echo x > "$d/temporary.sqlite"
        trap 'rm -rf "$d"; echo INT > "$3"; exit 130' INT; trap 'echo TERM > "$3"; exit 143' TERM
        echo "$$ $d" > "$2"; while :; do sleep 0.05; done ;;
  stubborn) d="$TMPDIR/yt_dlptest$$"; mkdir -p "$d"; echo x > "$d/temporary.sqlite"; trap '' INT TERM
            echo "$$ $d" > "$2"; while :; do sleep 0.05; done ;;
  --config-locations) printf '%s\n' "$@"; echo ---; cat; exit 0 ;;
esac`);
    chmodSync(fake, 0o755);
  });
  afterAll(() => {
    process.env.XDG_CACHE_HOME = oldCache;
    rmSync(root, { recursive: true, force: true });
  });

  it("unpacks into a folder of its own in melo's, not /tmp, removed when it exits", async () => {
    const { stdout } = await runYtdlp(fake, ["tmpdir"]);
    expect(stdout.trim().startsWith(join(root, "cache", "melo", "tmp", `melo-run-${process.pid}-`))).toBe(true);
    expect(existsSync(stdout.trim())).toBe(false);
    expect(privateTmp()).toBe(join(root, "cache", "melo", "tmp"));
  });

  it("a timeout stops yt-dlp with SIGINT, which removes its cookie database copy", async () => {
    mkdirSync(pids, { recursive: true });
    const f = join(pids, "copy"), sig = join(pids, "copy-signal");
    await expect(runYtdlp(fake, ["copy", f, sig], { timeout: 500 })).rejects.toMatchObject({ killed: true });
    const [pid, dir] = readFileSync(f, "utf-8").trim().split(" ");
    expect(await until(() => !alive(Number(pid)))).toBe(true);
    expect(readFileSync(sig, "utf-8").trim()).toBe("INT");
    expect(existsSync(dir)).toBe(false);
  });

  it("a run that ignores SIGINT and SIGTERM is killed, and its copy goes with its folder", async () => {
    mkdirSync(pids, { recursive: true });
    const f = join(pids, "stubborn");
    const t0 = Date.now();
    await expect(runYtdlp(fake, ["stubborn", f], { timeout: 300 })).rejects.toMatchObject({ killed: true });
    const [pid, dir] = readFileSync(f, "utf-8").trim().split(" ");
    expect(alive(Number(pid))).toBe(false);
    expect(Date.now() - t0).toBeGreaterThan(3000);   // SIGINT's grace, then SIGTERM's
    expect(existsSync(dir)).toBe(false);
  }, 15000);

  it("extractor args go in on stdin, not on the command line", async () => {
    const { stdout } = await runYtdlp(fake, ["args", "--extractor-args", "youtube:po_token=web.gvs+SECRET;visitor_data=VD", "-j"]);
    const [argv, stdin] = stdout.split("---\n");
    expect(argv).not.toContain("SECRET");
    expect(argv).not.toContain("VD");
    expect(argv.trim().split("\n")).toEqual(["--config-locations", "-", "args", "-j"]);
    expect(stdin.trim()).toBe("--extractor-args 'youtube:po_token=web.gvs+SECRET;visitor_data=VD'");
  });

  it("a timeout ends the child as well as the parent", async () => {
    const f = join(pids, "timeout");
    mkdirSync(pids, { recursive: true });
    const run = runYtdlp(fake, ["hang", f], { timeout: 500 });
    await expect(run).rejects.toMatchObject({ killed: true });
    const [parent, child] = readFileSync(f, "utf-8").trim().split(" ").map(Number);
    expect(await until(() => !alive(parent) && !alive(child), 8000)).toBe(true);
  }, 15000);

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

  it("a timeout lets yt-dlp remove what it unpacked", async () => {
    mkdirSync(pids, { recursive: true });
    const f = join(pids, "unpack");
    await expect(runYtdlp(fake, ["unpack", f], { timeout: 500 })).rejects.toMatchObject({ killed: true });
    const [parent, child, dir] = readFileSync(f, "utf-8").trim().split(" ");
    expect(await until(() => !alive(Number(parent)) && !alive(Number(child)))).toBe(true);
    expect(existsSync(dir)).toBe(false);
  });

  it("clears old unpack folders before a run when none is going", async () => {
    const stale = join(privateTmp(), "_MEIstale");
    mkdirSync(stale, { recursive: true });
    const t = new Date(Date.now() - 10 * 60e3); utimesSync(stale, t, t);
    await runYtdlp(fake, ["tmpdir"]);
    expect(existsSync(stale)).toBe(false);
  });

  it("says the disk is full when yt-dlp cannot unpack", async () => {
    await expect(runYtdlp(fake, ["full"])).rejects.toThrow(/the disk is full/);
  });
});

describe("where yt-dlp unpacks", () => {
  const GB = 1024 ** 3;
  it("melo's cache folder while it has room", () => {
    expect(chooseUnpackDir([{ dir: "cache", free: 2 * GB }, { dir: "tmp", free: 8 * GB }])).toBe("cache");
  });
  it("the folder with more room once the cache is short", () => {
    expect(chooseUnpackDir([{ dir: "cache", free: 0.1 * GB }, { dir: "tmp", free: 2 * GB }])).toBe("tmp");
    expect(chooseUnpackDir([{ dir: "cache", free: 0.3 * GB }, { dir: "tmp", free: 0.1 * GB }])).toBe("cache");
  });
  it("skips a folder it cannot use", () => {
    expect(chooseUnpackDir([{ dir: "cache", free: -1 }, { dir: "tmp", free: 0.2 * GB }])).toBe("tmp");
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

  it("removes yt-dlp's cookie database copies in melo's folders only", () => {
    const own = join(root, "own2"), shared = join(root, "shared2");
    for (const d of [own, shared]) mkdirSync(d, { recursive: true });
    const copy = (base: string, name: string, hoursAgo: number): string => {
      const p = join(base, name); mkdirSync(p); writeFileSync(join(p, "temporary.sqlite"), "x"); old(p, hoursAgo); return p;
    };
    const left = copy(own, "yt_dlpabc123", 1);
    const reading = copy(own, "yt_dlpdef456", 0);     // a read still going
    const others = copy(shared, "yt_dlpghi789", 1);
    expect(sweepStale(own, [shared])).toBe(1);
    expect(existsSync(left)).toBe(false);
    expect([reading, others].every(existsSync)).toBe(true);
  });

  it("removes a melo folder once the sidecar named in it is gone, whatever its age", () => {
    const own = join(root, "own3");
    mkdirSync(own, { recursive: true });
    const dead = spawnSync("true").pid!;
    const mk = (name: string): string => { const p = join(own, name); mkdirSync(p); return p; };
    const deadRun = mk(`melo-run-${dead}-aaaaaa`);
    const deadChrome = mk(`melo-chrome-${dead}-bbbbbb`);
    const liveRun = mk(`melo-run-${process.ppid}-cccccc`);   // another melo's run
    const mine = makeTempDir("melo-run-");                    // this sidecar's, in use
    expect(sweepStale([own, privateTmp()], [])).toBeGreaterThanOrEqual(2);
    expect([deadRun, deadChrome].some(existsSync)).toBe(false);
    expect([liveRun, mine].every(existsSync)).toBe(true);
    rmSync(mine, { recursive: true, force: true });
  });

  it("never sweeps a melo folder that is a link to someone else's", () => {
    const target = join(root, "elsewhere"), link = join(root, "own-link");
    mkdirSync(target, { recursive: true });
    const unpack = join(target, "_MEIold"); mkdirSync(unpack); old(unpack, 5);
    symlinkSync(target, link);
    expect(sweepStale([link], [])).toBe(0);
    expect(existsSync(unpack)).toBe(true);
  });

  it("splits only extractor args out of argv", () => {
    expect(splitConfigArgs(["-j", "url"])).toEqual({ argv: ["-j", "url"], config: "" });
    // a quote would end the config's quoting: it stays where it was
    expect(splitConfigArgs(["--extractor-args", "a'b"]).argv).toEqual(["--extractor-args", "a'b"]);
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
