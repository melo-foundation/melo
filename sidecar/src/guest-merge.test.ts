import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { setEnv } from "./env";
import { mergeGuestCookies } from "./guest-cookies";

// yt-dlp writes its whole jar back to the guest's cookie file: with
// --cookies-from-browser in a user's config that is every site's cookies.
describe("merging into a guest profile", () => {
  it("keeps YouTube's cookies only", () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-merge-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    const far = Math.floor(Date.now() / 1000) + 86400;
    const c = (domain: string, name: string) => ({ domain, path: "/", secure: true, expiry: far, name, value: "v" });
    mergeGuestCookies("merge", [c(".youtube.com", "YSC"), c("music.youtube.com", "M"),
                                c(".bank.example", "SESSION"), c(".google.com", "NID")]);
    const kept = JSON.parse(readFileSync(join(dir, "guest-cookies", "merge.json"), "utf-8")).map((k: any) => k.name);
    expect(kept.sort()).toEqual(["M", "YSC"]);
  });
});

describe("merging expired cookies", () => {
  it("drops them, so a browser's stale ST- cookies never reach a request", () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-merge-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    const now = Math.floor(Date.now() / 1000);
    const c = (name: string, expiry: number) => ({ domain: ".youtube.com", path: "/", secure: true, expiry, name, value: "v" });
    mergeGuestCookies("stale", [c("VISITOR_INFO1_LIVE", now + 86400), c("ST-abc", now - 60), c("ST-def", 0)]);
    const kept = JSON.parse(readFileSync(join(dir, "guest-cookies", "stale.json"), "utf-8")).map((k: any) => k.name);
    expect(kept).toEqual(["VISITOR_INFO1_LIVE"]);
  });
});

describe("a fresh guest fetch that lands after an import", () => {
  it("keeps the imported identity", async () => {
    const { getGuestCookies, writeNetscapeCookieFile } = await import("./guest-cookies");
    const { vi } = await import("vitest");
    const dir = mkdtempSync(join(tmpdir(), "melo-merge-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    const far = Math.floor(Date.now() / 1000) + 86400;
    for (const read of [(p: string) => getGuestCookies(p), (p: string) => writeNetscapeCookieFile(p)]) {
      const profile = `race${read.length}${Math.random().toString(36).slice(2, 6)}`;
      let land!: () => void;
      const gate = new Promise<void>((r) => { land = r; });
      vi.stubGlobal("fetch", async () => { await gate;
        return new Response("", { headers: [["Set-Cookie", "VISITOR_INFO1_LIVE=fresh; Domain=.youtube.com; Path=/; Max-Age=86400"]] }); });
      try {
        const pending = read(profile);
        await new Promise((r) => setTimeout(r, 10));
        mergeGuestCookies(profile, [{ domain: ".youtube.com", path: "/", secure: true, expiry: far, name: "VISITOR_INFO1_LIVE", value: "imported" }]);
        land(); await pending;
      } finally { vi.unstubAllGlobals(); }
      const stored = JSON.parse(readFileSync(join(dir, "guest-cookies", `${profile}.json`), "utf-8"));
      expect(stored.map((c: any) => c.value)).toEqual(["imported"]);
      expect((await getGuestCookies(profile)).map((c) => c.value)).toEqual(["imported"]);
    }
  });
});
