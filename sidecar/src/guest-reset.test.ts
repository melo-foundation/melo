import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { setEnv } from "./env";
import { saveSettings } from "./settings";
import * as innertube from "./innertube";
import * as gc from "./guest-cookies";

// A reset must not keep sending the old session's visitor id: YouTube would
// keep recommending from the old history.
describe("guest session reset", () => {
  const dir = mkdtempSync(join(tmpdir(), "melo-reset-"));
  const far = Math.floor(Date.now() / 1000) + 86400;
  const sent: { url: string; vi: string; vd: string }[] = [];
  let fresh = false;
  const realFetch = globalThis.fetch;

  beforeAll(() => {
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: "/bin/false", osPrefersDark: false, appVersion: "t" } as any);
    mkdirSync(join(dir, "guest-cookies"), { recursive: true });
    writeFileSync(join(dir, "guest-cookies", "A.json"), JSON.stringify([
      { domain: ".youtube.com", path: "/", secure: true, expiry: far, name: "VISITOR_INFO1_LIVE", value: "VI_A" }]));
    saveSettings({ cookieSource: "guest", cookieProfile: "A" } as any);
    (globalThis as any).fetch = async (url: string, init: any = {}) => {
      const h = init.headers || {};
      const vi = /VISITOR_INFO1_LIVE=([^;]+)/.exec(h["Cookie"] || "")?.[1] || "-";
      let vd = "-";
      try { vd = JSON.parse(init.body).context.client.visitorData ?? "-"; } catch { /* no body */ }
      sent.push({ url, vi, vd });
      if (url === "https://www.youtube.com" && fresh)
        return new Response("x", { headers: [["set-cookie", "VISITOR_INFO1_LIVE=VI_A2; Domain=.youtube.com; Path=/"]] });
      if (url === "https://www.youtube.com")
        return new Response(`<script>var ytInitialData = {"a":1};</script> "visitorData":"vd_of_${vi}"`);
      if (url.includes("music.youtube.com"))
        return new Response(JSON.stringify({ responseContext: { visitorData: "music_vd_of_" + vi } }));
      return new Response(JSON.stringify({}));
    };
  });
  afterAll(() => { globalThis.fetch = realFetch; rmSync(dir, { recursive: true, force: true }); });

  const last = (part: string) => [...sent].reverse().find((s) => s.url.includes(part))!;

  it("home feed drops the old visitor id", async () => {
    await innertube.fetchRecommendedChips("guest", "", "A");
    fresh = true; await gc.resetGuestSession("A"); fresh = false;
    innertube.clearCookieCache();   // what cookies/resetGuest does after the reset
    await innertube.fetchRecommendedContinuation("tok", "guest", "", "A");
    const r = last("/browse");
    expect(r.vi).toBe("VI_A2");
    expect(r.vd).not.toBe("vd_of_VI_A");
  });

  it("YouTube Music home drops the old visitor id", async () => {
    await innertube.fetchMusicHome("guest", "", "A");
    innertube.clearCookieCache();
    await innertube.fetchMusicHomeContinuation("tok", "guest", "", "A");
    expect(last("music.youtube.com").vd).not.toMatch(/^music_vd_of_/);
  });
});
