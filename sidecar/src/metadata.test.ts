import { describe, it, expect } from "vitest";
import { searchableTitle, lookupMetadata, lookupOrder } from "./metadata";

describe("searchableTitle", () => {
  it("finds nothing in titles that are not words", () => {
    // both of these are real videos: one is block art, the other is a single
    // U+202A. Normalised they are empty, and an empty string is a substring of
    // every string — which is how a nonsense query matched the first result
    // the API happened to return.
    expect(searchableTitle("████████████   ████   ██████")).toBe("");
    expect(searchableTitle("‪")).toBe("");
    expect(searchableTitle("!!! ??? ---")).toBe("");
    expect(searchableTitle("")).toBe("");
  });

  it("keeps real titles, including CJK", () => {
    expect(searchableTitle("ONE TRACK MIND")).toBe("one track mind");
    expect(searchableTitle("ヒバナ")).not.toBe("");
  });
});

describe("lookupMetadata", () => {
  it("does not reach the network when there is nothing to search for", async () => {
    const fetchSpy = globalThis.fetch;
    let called = false;
    globalThis.fetch = (async () => { called = true; throw new Error("no network in test"); }) as any;
    try {
      await expect(lookupMetadata("", "‪")).resolves.toBeNull();
      await expect(lookupMetadata("", "████████")).resolves.toBeNull();
      expect(called).toBe(false);
    } finally {
      globalThis.fetch = fetchSpy;
    }
  });
});

describe("title-only fallback", () => {
  // With no artist to check against, the title has to carry the weight. The
  // real case: "いますぐ輪廻" by なきそ came back as an 8-bit cover, because the
  // query is a substring of the cover's title.
  function stubDeezerCover() {
    globalThis.fetch = (async (url: any) => {
      const u = String(url);
      if (u.includes("deezer.com/search")) {
        // both Deezer stages are hit; the cover is what each would find
        return new Response(JSON.stringify({ data: [{
          title: "いますぐ輪廻 / Retry Now (8-Bit Cover)",
          artist: { name: "Pixel League Music" },
          album: { title: "いますぐ輪廻 / Retry Now (8-Bit Cover)" },
        }]}), { status: 200 });
      }
      // every other stage finds nothing, so the chain reaches the fallback
      return new Response(JSON.stringify({ recordings: [], artists: [], data: [] }),
                          { status: 200 });
    }) as any;
  }

  it("refuses a rendition of the track it was asked about", async () => {
    const real = globalThis.fetch;
    stubDeezerCover();
    try {
      await expect(lookupMetadata("NAKISO", "いますぐ輪廻")).resolves.toBeNull();
    } finally {
      globalThis.fetch = real;
    }
  });

  it("still takes a result that is the same track", async () => {
    const real = globalThis.fetch;
    globalThis.fetch = (async (url: any) => {
      if (String(url).includes("deezer.com/search")) {
        return new Response(JSON.stringify({ data: [{
          title: "いますぐ輪廻",
          artist: { name: "なきそ" },
          album: { title: "いますぐ輪廻" },
        }]}), { status: 200 });
      }
      return new Response(JSON.stringify({ recordings: [], artists: [], data: [] }),
                          { status: 200 });
    }) as any;
    try {
      const r = await lookupMetadata("NAKISO", "いますぐ輪廻");
      expect(r?.cleanTitle).toBe("いますぐ輪廻");
      expect(r?.artist).toBe("なきそ");
    } finally {
      globalThis.fetch = real;
    }
  });
});

// Which services a lookup asks, and in what order. Each can be switched off;
// Last.fm also needs a key, and without one it is skipped.
// The order is the chain's: Last.fm, then MusicBrainz, then Deezer.
describe("lookupOrder", () => {
  const all = { lastfm: true, musicbrainz: true, deezer: true };

  it("asks every service, in the chain's order, when all are on and keyed", () => {
    expect(lookupOrder(all, "key")).toEqual(["lastfm", "musicbrainz", "deezer"]);
  });

  it("skips Last.fm without a key even when it is on", () => {
    expect(lookupOrder(all, undefined)).toEqual(["musicbrainz", "deezer"]);
  });

  it("leaves out what is switched off", () => {
    expect(lookupOrder({ ...all, musicbrainz: false }, "key")).toEqual(["lastfm", "deezer"]);
    expect(lookupOrder({ ...all, deezer: false }, undefined)).toEqual(["musicbrainz"]);
  });

  it("asks nothing when every service is off", () => {
    expect(lookupOrder({ lastfm: false, musicbrainz: false, deezer: false }, "key")).toEqual([]);
  });
});
