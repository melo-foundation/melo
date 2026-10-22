import { describe, expect, it, beforeEach } from "vitest";
import { mkdtempSync, existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { setEnv } from "./env";
import { initLibrary, cacheLargeArt, backfillLargeArt } from "./library";

// Now Playing's large picture for a download, kept beside the card's thumbnail
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const answer = (byUrl: Record<string, { status: number; body?: Buffer }>) =>
  (async (url: string) => {
    const a = byUrl[url] ?? { status: 404 };
    return { ok: a.status === 200, status: a.status, arrayBuffer: async () => a.body ?? Buffer.alloc(0) };
  }) as unknown as typeof fetch;

describe("large art for downloads", () => {
  let dir = "";
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "melo-art-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    initLibrary(join(dir, "dl"));
  });

  it("keeps YouTube's 1280 picture as thumbs/<id>-large.jpg", async () => {
    const ok = await cacheLargeArt("F5V5fxKVLXo", answer({
      "https://i.ytimg.com/vi/F5V5fxKVLXo/maxresdefault.jpg": { status: 200, body: JPEG } }));
    expect(ok).toBe(true);
    expect(readFileSync(join(dir, "dl", "thumbs", "F5V5fxKVLXo-large.jpg"))).toEqual(JPEG);
  });

  it("takes the 720 one when there is no 1280, and nothing that is not a JPEG", async () => {
    expect(await cacheLargeArt("aaaaaaaaaaa", answer({
      "https://i.ytimg.com/vi/aaaaaaaaaaa/maxresdefault.jpg": { status: 200, body: Buffer.from("<html>") },
      "https://i.ytimg.com/vi/aaaaaaaaaaa/hq720.jpg": { status: 200, body: JPEG } }))).toBe(true);
    expect(await cacheLargeArt("bbbbbbbbbbb", answer({}))).toBe(false);
    expect(existsSync(join(dir, "dl", "thumbs", "bbbbbbbbbbb-large.jpg"))).toBe(false);
  });

  it("refuses an id that is not safe as a file name", async () => {
    expect(await cacheLargeArt("../../etc/x", answer({}))).toBe(false);
  });

  it("fills in downloads made before, once", async () => {
    writeFileSync(join(dir, "library.v2.json"), JSON.stringify({ tracks: [
      { id: "ccccccccccc", title: "a", downloaded: true, fileName: "ccccccccccc.opus" },
      { id: "ddddddddddd", title: "b", downloaded: false } ], playlists: [] }));
    mkdirSync(join(dir, "dl", "thumbs"), { recursive: true });
    writeFileSync(join(dir, "dl", "ccccccccccc.opus"), "x");   // before the library checks its downloads
    initLibrary(join(dir, "dl"));
    const all = answer({ "https://i.ytimg.com/vi/ccccccccccc/maxresdefault.jpg": { status: 200, body: JPEG },
                         "https://i.ytimg.com/vi/ddddddddddd/maxresdefault.jpg": { status: 200, body: JPEG } });
    expect(await backfillLargeArt(all)).toBe(1);   // the download, not the library-only track
    expect(await backfillLargeArt(all)).toBe(0);
  });
});
