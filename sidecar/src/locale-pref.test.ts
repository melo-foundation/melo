import { describe, it, expect, beforeAll } from "vitest";
import { mkdtempSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { setEnv } from "./env";
import { localePref, saveSettings, systemRegion, systemLocale } from "./settings";
import { REGIONS, nearestSupported } from "./locales";

// YouTube answers 400 "Request contains an invalid argument" to a regional hl in any
// other case than its own: "en-GB" works, "en-gb" fails.
describe("localePref", () => {
  beforeAll(() => {
    const dir = mkdtempSync(join(tmpdir(), "melo-locale-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: join(dir, "yt-dlp"), osPrefersDark: true, appVersion: "test" });
  });

  it("sends a regional language in YouTube's own case", () => {
    saveSettings({ language: "en-GB", region: "GB" });
    expect(localePref()).toEqual({ hl: "en-GB", gl: "GB" });
    saveSettings({ language: "zh-cn", region: "tw" });
    expect(localePref()).toEqual({ hl: "zh-CN", gl: "TW" });
  });

  it("sends a plain language as YouTube lists it", () => {
    saveSettings({ language: "de", region: "" });
    expect(localePref().hl).toBe("de");
  });
});

describe("systemRegion", () => {
  it("reads the region past a script or variant", () => {
    expect(systemRegion("en-GB")).toBe("GB");
    expect(systemRegion("zh-Hans-CN")).toBe("CN");
    expect(systemRegion("sr-RS-latin")).toBe("RS");
    expect(systemRegion("en-US-x-lvariant-euro")).toBe("US");
    expect(systemRegion("de")).toBe("");
  });
});

// Outside YouTube's 111 locations, YouTube search answers "Something went wrong" and
// YouTube Music 400; both answer normally without gl.
describe("a region YouTube does not offer", () => {
  it("sends no region", () => {
    saveSettings({ language: "en", region: "ZM" });
    expect(localePref().gl).toBeUndefined();
    saveSettings({ language: "en", region: "cn" });
    expect(localePref().gl).toBeUndefined();
  });

  it("is not offered in the picker", () => {
    const codes = REGIONS().map((r) => r.code);
    expect(codes).toContain("GB");
    expect(codes).not.toContain("ZM");
    expect(codes).not.toContain("CN");
  });
});

describe("the system language", () => {
  // an exported but empty LC_ALL or LC_MESSAGES makes ICU answer "und"; POSIX skips it
  it("reads past an empty locale variable", () => {
    expect(systemLocale("und", { LC_ALL: "", LANG: "de_DE.UTF-8" })).toBe("de_DE");
    expect(systemLocale("und", { LC_MESSAGES: "", LANG: "fr_CA.UTF-8" })).toBe("fr_CA");
    expect(systemLocale("und", {})).toBe("en-US");
    expect(systemLocale("ja-JP", { LANG: "de_DE.UTF-8" })).toBe("ja-JP");
  });

  // YouTube keeps the old codes for Hebrew, Norwegian and Filipino
  it("maps the codes YouTube spells differently", () => {
    expect(nearestSupported("he-IL")).toBe("iw");
    expect(nearestSupported("nb")).toBe("no");
    expect(nearestSupported("nn-NO")).toBe("no");
    expect(nearestSupported("tl")).toBe("fil");
    expect(nearestSupported("de-DE")).toBe("de");
  });
});
