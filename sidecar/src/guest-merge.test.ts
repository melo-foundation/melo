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
