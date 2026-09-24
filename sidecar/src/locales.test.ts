import { describe, it, expect } from "vitest";
import { isSupportedLocale, nearestSupported, LOCALES, REGIONS, isSupportedRegion } from "./locales";

describe("locale validation", () => {
  it("accepts what YouTube accepts", () => {
    for (const c of ["en", "ja", "de", "pt", "zh-CN", "es-419"]) {
      expect(isSupportedLocale(c), c).toBe(true);
    }
  });

  it("rejects codes YouTube returns an empty payload for", () => {
    // measured against /next: all of these come back with no usable renderers
    for (const c of ["zxx", "und", "mul", "cy", "mi", "haw", "", "nonsense"]) {
      expect(isSupportedLocale(c), c).toBe(false);
    }
  });

  it("falls back from a region to its base language", () => {
    expect(nearestSupported("ja-JP")).toBe("ja");
    expect(nearestSupported("de-AT")).toBe("de");
    expect(isSupportedLocale("en-AU")).toBe(true);
  });

  it("keeps region-specific codes distinct where YouTube has them", () => {
    expect(nearestSupported("pt-PT")).toBe("pt-PT");
    expect(nearestSupported("zh-TW")).toBe("zh-TW");
  });

  it("is case-insensitive", () => {
    expect(nearestSupported("JA")).toBe("ja");
    expect(nearestSupported("zh-cn")).toBe("zh-CN");
  });

  it("has no duplicate codes", () => {
    const seen = new Set(LOCALES.map((l) => l.code));
    expect(seen.size).toBe(LOCALES.length);
  });
});

describe("regions (gl)", () => {
  it("resolves the ISO table from Intl", () => {
    const r = REGIONS();
    expect(r.length).toBeGreaterThan(200);
    expect(r.some((x) => x.code === "JP" && x.name === "Japan")).toBe(true);
    expect(r.some((x) => x.code === "US")).toBe(true);
  });

  it("is sorted by name and free of code duplicates", () => {
    const r = REGIONS();
    const names = r.map((x) => x.name);
    expect([...names].sort((a, b) => a.localeCompare(b))).toEqual(names);
    expect(new Set(r.map((x) => x.code)).size).toBe(r.length);
  });

  it("rejects non-regions", () => {
    expect(isSupportedRegion("XX")).toBe(false);
    expect(isSupportedRegion("")).toBe(false);
    expect(isSupportedRegion("jp")).toBe(true);   // case-insensitive
  });
});
