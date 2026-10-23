import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { setEnv } from "./env";
import {
  BAD_PROFILE_NAME, KeyringError, checkProfileName, cdpFrames, createProfile, deleteProfile, dumpBrowserCookies,
  fromCdpCookies, listProfiles, migrateProfiles, readChromeCookies, renameProfile, sanitizeProfileName,
  useFifoForTest, validProfileName,
} from "./guest-cookies";
import { privateTmp } from "./ytdlp-proc";

const unix = process.platform !== "win32";

describe("profile names", () => {
  it("takes plain names, and combining marks after the first character", () => {
    for (const n of ["Default", "Work", "work 2", "Zoë", "a_b-c", "Main (old)", "v1.2", "O'Neil",
                     "Zoe\u0301", "a\u20dd", "नमस्ते"])
      expect(validProfileName(n)).toBe(true);
    expect(checkProfileName("Zoe\u0301")).toBe("Zo\u00e9");
  });

  it("refuses paths, dots, control characters and overlong names", () => {
    for (const n of ["", ".", "..", "../plugin-data/x/y", "a/b", "a\\b", ".hidden", "a\0b", "a\nb",
                     "x".repeat(65), "trailing.", "trailing ", " lead", "CON", "nul.txt", "com1", "COM¹", "lpt².json",
                     "\u0301a", 5, null])
      expect(validProfileName(n)).toBe(false);
    expect(validProfileName("x".repeat(64))).toBe(true);
  });

  it("every profile call refuses a bad name before touching a file", async () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-names-test-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    try {
      expect(() => checkProfileName("../x")).toThrow(BAD_PROFILE_NAME);
      await expect(createProfile("../plugin-data/p/x")).rejects.toThrow(BAD_PROFILE_NAME);
      expect(() => deleteProfile("../settings.v2")).toThrow(BAD_PROFILE_NAME);
      expect(() => renameProfile("Default", "../../escape")).toThrow(BAD_PROFILE_NAME);
      expect(readdirSync(dir)).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("profiles from before names were checked", () => {
  const dir = mkdtempSync(join(tmpdir(), "cookie-safety-migrate-"));
  const profiles = join(dir, "guest-cookies");
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  const mk = (name: string): void => {
    writeFileSync(join(profiles, `${name}.json`), "[]");
    writeFileSync(join(profiles, `${name}.txt`), "# Netscape HTTP Cookie File\n");
  };

  it("map to the nearest valid name", () => {
    expect(sanitizeProfileName("Mood: Chill")).toBe("Mood - Chill");
    expect(sanitizeProfileName("Work & Play")).toBe("Work and Play");
    expect(sanitizeProfileName("Me!")).toBe("Me");
    expect(sanitizeProfileName("🎵 Chill")).toBe("Chill");
    expect(sanitizeProfileName("🎵")).toBe("Profile");
    expect(sanitizeProfileName("Zoe\u0301")).toBe("Zo\u00e9");
    expect(sanitizeProfileName("COM¹")).toBe("COM¹ profile");
    for (const n of ["Mood: Chill", "Work & Play", "Me!", "🎵 Chill", "../x", "COM¹", "x".repeat(90)])
      expect(validProfileName(sanitizeProfileName(n))).toBe(true);
  });

  it("a reserved name gets its suffix before the first dot, and is always valid", () => {
    expect(sanitizeProfileName("COM1.txt!")).toBe("COM1 profile.txt");
    expect(sanitizeProfileName("aux.mp3")).toBe("aux profile.mp3");
    expect(sanitizeProfileName("con")).toBe("con profile");
    const long = "LPT1." + "x".repeat(70);
    expect(validProfileName(sanitizeProfileName(long))).toBe(true);
    expect([...sanitizeProfileName(long)].length).toBeLessThanOrEqual(64);
    for (const n of ["COM1.txt!", "aux.mp3", "con", long, "nul.", "PRN .x", "...", "́"])
      expect(validProfileName(sanitizeProfileName(n))).toBe(true);
  });

  it("a long name of astral letters is cut by code points, not halves of one, within a file name's bytes", () => {
    const out = sanitizeProfileName("𝒜".repeat(80));
    expect(out).toBe("𝒜".repeat(50));   // 4 bytes each, 200 at most
    expect(validProfileName(out)).toBe(true);
    expect(validProfileName("𝒜".repeat(64))).toBe(false);
    expect(sanitizeProfileName("é".repeat(70))).toBe("é".repeat(64));
  });

  it("reserved and long names migrate once; a second start renames nothing", () => {
    const d = mkdtempSync(join(tmpdir(), "cookie-safety-migrate2-"));
    try {
      const g = join(d, "guest-cookies");
      mkdirSync(g, { recursive: true });
      const long = "COM1." + "y".repeat(59);
      for (const n of ["COM1.txt!", "aux.mp3", "con", long, "𝒜".repeat(62) + "!"])
        writeFileSync(join(g, `${n}.json`), "[]");
      setEnv({ dataDir: d, musicDir: d, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
      const first = migrateProfiles("COM1.txt!");
      expect(first.moved.size).toBe(5);
      expect(first.profile).toBe("COM1 profile.txt");
      expect(readdirSync(g).every((f) => validProfileName(f.replace(/\.json$/, "")))).toBe(true);
      const second = migrateProfiles(first.profile);
      expect(second.moved.size).toBe(0);
      expect(second.profile).toBe(first.profile);
      // a setting naming no file still never comes back unchecked
      expect(validProfileName(migrateProfiles("aux.mp3").profile)).toBe(true);
    } finally {
      rmSync(d, { recursive: true, force: true });
    }
  });

  it("are renamed once at start, distinct from each other and from valid ones, and the setting follows", () => {
    mkdirSync(profiles, { recursive: true });
    for (const n of ["Default", "Me", "Mood: Chill", "Work & Play", "Me!", "🎵 Chill", "Zoe\u0301"]) mk(n);
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    const { moved, profile } = migrateProfiles("Mood: Chill");
    expect(Object.fromEntries(moved)).toEqual({
      "Mood: Chill": "Mood - Chill", "Work & Play": "Work and Play", "Me!": "Me 2", "🎵 Chill": "Chill",
      "Zoe\u0301": "Zo\u00e9",
    });
    expect(profile).toBe("Mood - Chill");
    expect(listProfiles()).toEqual(["Chill", "Default", "Me", "Me 2", "Mood - Chill", "Work and Play", "Zo\u00e9"]);
    expect(readdirSync(profiles).every((f) => validProfileName(f.replace(/\.(json|txt)$/, "")))).toBe(true);
    // a second start renames nothing; a setting naming no file is made valid
    expect(migrateProfiles("Me!").moved.size).toBe(0);
    expect(migrateProfiles("Me!").profile).toBe("Me");
    expect(migrateProfiles("Default").profile).toBe("Default");
  });

  it("a new or renamed profile cannot take a name that exists in another case", async () => {
    await expect(createProfile("default")).rejects.toThrow(/A profile named Default exists/);
    expect(() => renameProfile("Chill", "ME")).toThrow(/A profile named Me exists/);
    renameProfile("Chill", "CHILL");   // its own name in another case
    expect(listProfiles()).toContain("CHILL");
  });
});

// Stands in for yt-dlp: says what --cookies is, then writes a jar with YouTube's,
// Google's and other sites' cookies, more than a pipe buffer holds.
describe.skipIf(!unix)("reading a browser's cookies", () => {
  const root = mkdtempSync(join(tmpdir(), "melo-dump-test-"));
  const fake = join(root, "yt-dlp");
  const log = join(root, "log");
  const oldCache = process.env.XDG_CACHE_HOME;

  beforeAll(() => {
    process.env.XDG_CACHE_HOME = join(root, "cache");
    process.env.MELO_FAKE_LOG = log;
    writeFileSync(fake, `#!/bin/bash
b="$2"; f="$4"
if [ -p "$f" ]; then echo fifo >> "$MELO_FAKE_LOG"; else echo file >> "$MELO_FAKE_LOG"; fi
# as yt-dlp: a readable --cookies is loaded first, and one without the header is refused
if [ -r "$f" ]; then
  echo readable >> "$MELO_FAKE_LOG"
  head -n 1 "$f" | grep -qE '^# (Netscape )?HTTP Cookie File' || {
    echo "ERROR: '$f' does not look like a Netscape format cookies file" >&2; exit 1; }
fi
case "$b" in denied*) echo "ERROR: kwallet-query failed with return code 1. Please consult the kwallet-query man page for details" >&2 ;; esac
{ echo "# Netscape HTTP Cookie File"
  [ "$b" = denied ] || printf '.youtube.com\\tTRUE\\t/\\tTRUE\\t2000000000\\tSAPISID\\tyt1\\n'
  printf 'music.youtube.com\\tFALSE\\t/\\tTRUE\\t2000000000\\tPREF\\tyt2\\n'
  printf '.google.com\\tTRUE\\t/\\tTRUE\\t2000000000\\tSID\\tg1\\n'
  printf '.bank.example\\tTRUE\\t/\\tTRUE\\t0\\tsession\\tb1\\n'
  printf '.notyoutube.com\\tTRUE\\t/\\tTRUE\\t0\\tx\\tn1\\n'
  for i in $(seq 1 3000); do printf '.example.org\\tTRUE\\t/\\tFALSE\\t0\\tn%d\\tvalue%d\\n' $i $i; done
} > "$f"
echo "ERROR: [generic] 'about:blank' is not a valid URL" >&2
exit 1
`);
    chmodSync(fake, 0o755);
    setEnv({ dataDir: root, musicDir: root, ytdlpPath: fake, osPrefersDark: false, appVersion: "t" } as any);
  });
  afterAll(() => {
    if (oldCache === undefined) delete process.env.XDG_CACHE_HOME;
    else process.env.XDG_CACHE_HOME = oldCache;
    delete process.env.MELO_FAKE_LOG;
    rmSync(root, { recursive: true, force: true });
  });

  const leftovers = (): string[] => readdirSync(privateTmp()).filter((n) => n.startsWith("melo-"));

  it("keeps YouTube's cookies only, read through a FIFO yt-dlp cannot load from", async () => {
    rmSync(log, { force: true });
    const got = await dumpBrowserCookies("firefox");
    expect(got.map((c) => `${c.domain} ${c.name}`)).toEqual([".youtube.com SAPISID", "music.youtube.com PREF"]);
    expect(readFileSync(log, "utf-8").trim().split("\n")).toEqual(["fifo"]);
    expect(leftovers()).toEqual([]);
  });

  it("without a FIFO, a 0600 file yt-dlp can load and then overwrite", async () => {
    rmSync(log, { force: true });
    useFifoForTest(false);
    try {
      const got = await dumpBrowserCookies("firefox");
      expect(got.map((c) => `${c.domain} ${c.name}`)).toEqual([".youtube.com SAPISID", "music.youtube.com PREF"]);
      expect(readFileSync(log, "utf-8").trim().split("\n")).toEqual(["file", "readable"]);
      expect(leftovers()).toEqual([]);
    } finally { useFifoForTest(true); }
  });

  it("a keyring that gave no key is its own failure, not an empty jar", async () => {
    await expect(dumpBrowserCookies("denied")).rejects.toBeInstanceOf(KeyringError);
    expect(leftovers()).toEqual([]);
  });

  it("a keyring complaint with the sign-in cookies read anyway is not a denial", async () => {
    const got = await dumpBrowserCookies("denied-but-signed-in");
    expect(got.map((c) => c.name)).toContain("SAPISID");
  });

  it("a Chromium read that times out is taken as a keyring prompt left open", async () => {
    // the dump's own timeout is 45 s; a short one stands in through the error it gives
    const { readThroughFifo, makeFifo } = await import("./guest-cookies");
    const dir = mkdtempSync(join(root, "fifo-"));
    const f = join(dir, "c.txt");
    expect(makeFifo(f)).toBe(true);
    const r = await readThroughFifo(f, async () => { throw Object.assign(new Error("timed out"), { killed: true }); });
    expect(r.text).toBe("");
    expect((r.error as any).killed).toBe(true);
  });
});

describe("Chrome over CDP", () => {
  it("splits pipe traffic at NULs and keeps a partial message", () => {
    expect(cdpFrames('{"id":1}\0{"id":2}\0{"id"')).toEqual({ messages: ['{"id":1}', '{"id":2}'], rest: '{"id"' });
  });

  it("keeps youtube.com cookies only: no Google service, no look-alike", () => {
    const raw = ["youtube.com", ".youtube.com", "www.youtube.com", "accounts.google.com", ".google.com",
                 "mail.google.com", "youtube.community", "notyoutube.com", "youtube.com.evil.test"]
      .map((domain) => ({ domain, name: "n", value: "v", path: "/", expires: 0 }));
    expect(fromCdpCookies(raw).map((c) => c.domain)).toEqual([".youtube.com", ".youtube.com", ".www.youtube.com"]);
  });

  // Stands in for Chrome: speaks CDP on fds 3 and 4, and on Browser.close
  // writes into its profile folder before it exits, as its network service does.
  describe.skipIf(!unix)("the import", () => {
    const root = mkdtempSync(join(tmpdir(), "cookie-safety-chrome-"));
    const fake = join(root, "chrome");
    const argsOut = join(root, "args");
    const data = join(root, "User Data");
    const oldCache = process.env.XDG_CACHE_HOME;
    beforeAll(() => {
      process.env.XDG_CACHE_HOME = join(root, "cache");
      mkdirSync(join(data, "Default", "Network"), { recursive: true });
      writeFileSync(join(data, "Default", "Network", "Cookies"), "db");
      writeFileSync(join(data, "Local State"), "{}");
      writeFileSync(fake, `#!/usr/bin/env node
const fs = require("fs"), net = require("net");
const args = process.argv.slice(2);
const udd = args.find((a) => a.startsWith("--user-data-dir=")).slice(16);
fs.writeFileSync(${JSON.stringify(argsOut)}, args.join("\\n") + "\\ncopied=" + fs.existsSync(udd + "/Default/Network/Cookies"));
const out = new net.Socket({ fd: 4, readable: false, writable: true });
let buf = "";
new net.Socket({ fd: 3, readable: true, writable: false }).on("data", (d) => {
  buf += d;
  const parts = buf.split("\\0"); buf = parts.pop();
  for (const m of parts) {
    const msg = JSON.parse(m);
    if (msg.method === "Storage.getCookies")
      out.write(JSON.stringify({ id: msg.id, result: { cookies: [
        { domain: ".youtube.com", name: "SAPISID", value: "v", path: "/", expires: 0 },
        { domain: "accounts.google.com", name: "LSID", value: "g", path: "/", expires: 0 } ] } }) + "\\0");
    if (msg.method === "Browser.close") setTimeout(() => {
      fs.mkdirSync(udd + "/Default", { recursive: true });
      fs.writeFileSync(udd + "/Default/late", "x");
      process.exit(0);
    }, 300);
  }
});
`);
      chmodSync(fake, 0o755);
    });
    afterAll(() => {
      if (oldCache === undefined) delete process.env.XDG_CACHE_HOME;
      else process.env.XDG_CACHE_HOME = oldCache;
      rmSync(root, { recursive: true, force: true });
    });

    it("asks over a pipe, not a port, waits for Chrome to exit, then removes its copy", async () => {
      const cookies = await readChromeCookies(fake, data, 5000);
      expect(cookies.map((c) => c.name)).toEqual(["SAPISID", "LSID"]);
      const args = readFileSync(argsOut, "utf-8").split("\n");
      expect(args).toContain("--remote-debugging-pipe");
      expect(args.some((a) => a.startsWith("--remote-debugging-port"))).toBe(false);
      expect(args).toContain("copied=true");
      expect(readdirSync(privateTmp()).filter((n) => n.startsWith("melo-chrome-"))).toEqual([]);
    });
  });
});
