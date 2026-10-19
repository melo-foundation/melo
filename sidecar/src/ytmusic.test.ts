import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Fixtures are guest responses from music.youtube.com (search "daft punk",
// next for 5NV6Rdv1a3I), trimmed, with no cookies, visitor ids or tracking.
vi.mock("./settings", async (orig) => ({
  ...(await orig<typeof import("./settings")>()),
  loadSettings: () => ({ ui: { thumbQuality: "medium" } }),
  localePref: () => ({ hl: "en", gl: "US" }),
}));
vi.mock("./guest-cookies", async (orig) => ({
  ...(await orig<typeof import("./guest-cookies")>()),
  getGuestCookies: async () => [],
  captureResponseCookies: () => {},
}));

import {
  parseMusicSearch, parseMusicSearchContinuation, parseMusicNext, parseMusicNextContinuation,
  musicSearchParams, searchFrom, searchContinuationFrom, nextFrom, nextContinuationFrom,
} from "./innertube";

const fixture = (name: string) =>
  JSON.parse(readFileSync(join(__dirname, "..", "test-fixtures", "ytm", name + ".json"), "utf-8"));

describe("YouTube Music search parsing", () => {
  it("reads the Songs shelf into tracks, with a continuation", () => {
    const r = parseMusicSearch(fixture("search-songs"));
    expect(r.results.length).toBe(6);
    expect(r.results[1]).toMatchObject({
      id: "uSFXOBaqiR8", title: "Veridis Quo (Edit)", channel: "Daft Punk", duration: 165, views: "110M plays",
    });
    expect(r.results[1].thumbnail).toMatch(/=w360-h360/);
    expect(r.playlists).toEqual([]);
    expect(r.continuation).toMatch(/^ytm:/);
  });

  it("reads the unfiltered page's albums and playlists, not its artists or podcasts", () => {
    const r = parseMusicSearch(fixture("search-top"));
    const album = r.playlists.find((p) => p.title === "Random Access Memories")!;
    expect(album).toMatchObject({ playlistId: expect.stringMatching(/^OLAK5uy_/), channel: "Daft Punk" });
    const curated = r.playlists.find((p) => p.title === "Presenting Daft Punk")!;
    expect(curated).toMatchObject({ playlistId: expect.stringMatching(/^RDCLAK/), channel: "YouTube Music", videoCount: 35 });
    expect(r.playlists.every((p) => !p.playlistId.startsWith("UC") && !p.playlistId.startsWith("MPSP"))).toBe(true);
    expect(r.playlists.find((p) => p.title === "All Daft Punk Songs In Order")?.playlistId).toMatch(/^PL/);
  });

  it("reads a continuation page", () => {
    const r = parseMusicSearchContinuation(fixture("search-songs-cont"));
    expect(r.results.length).toBe(4);
    expect(r.results[0]).toMatchObject({ id: "uy9zRMjYgDU", channel: "Daft Punk", duration: 368 });
    expect(r.continuation).toMatch(/^ytm:/);
  });
});

describe("YouTube Music next parsing", () => {
  it("drops the playing track and makes the one after it the autoplay", () => {
    const r = parseMusicNext(fixture("next"), "5NV6Rdv1a3I");
    expect(r.autoplay).toMatchObject({ id: "FGBhQbmPwH8", title: "One More Time", channel: "Daft Punk", duration: 322 });
    expect(r.suggestions.length).toBe(4);
    expect(r.suggestions.some((s) => s.id === "5NV6Rdv1a3I")).toBe(false);
    expect(r.suggestions[0]).toMatchObject({ id: "yyDUC1LUXSU", channel: "Robin Thicke", views: "996M views" });
    expect(r.continuation).toMatch(/^ytm:/);
    expect(r.info).toBeNull();
  });

  it("reads a continuation page", () => {
    const r = parseMusicNextContinuation(fixture("next-cont"));
    expect(r.suggestions.map((s) => s.id)).toEqual(["nb8CnIo_-_A", "-N4jf6rtyuw", "SDTZ7iX4vTQ", expect.any(String)]);
    expect(r.continuation).toMatch(/^ytm:/);
  });
});

describe("musicSearchParams", () => {
  it("maps the filters YouTube Music has and refuses the rest", () => {
    expect(musicSearchParams(undefined)).toBeTruthy();
    expect(musicSearchParams({ type: "video" })).not.toBe(musicSearchParams({}));
    expect(musicSearchParams({ type: "playlist" })).toBeTruthy();
    expect(musicSearchParams({ type: "channel" })).toBeUndefined();
    expect(musicSearchParams({ sort: "views" })).toBeUndefined();
    expect(musicSearchParams({ uploadDate: "week" })).toBeUndefined();
    expect(musicSearchParams({ duration: "long" })).toBeUndefined();
  });

  it("has its own Songs and Albums", () => {
    expect(musicSearchParams({ type: "song" })).toBe(musicSearchParams({}));
    const albums = musicSearchParams({ type: "album" });
    expect(albums).toBeTruthy();
    expect([musicSearchParams({}), musicSearchParams({ type: "video" }), musicSearchParams({ type: "playlist" })])
      .not.toContain(albums);
  });
});

// Answers by host and endpoint; records what was asked.
function stubFetch(answers: Record<string, any | ((body: any) => any)>) {
  const calls: { url: string; body: any }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: any) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    const u = new URL(url);
    const a = answers[u.host + u.pathname];
    const data = typeof a === "function" ? a(body) : a;
    if (data === undefined || data instanceof Error)
      return { ok: false, status: 500, statusText: "fail", headers: new Headers(), json: async () => ({}) };
    return { ok: true, status: 200, statusText: "OK", headers: new Headers(), json: async () => data };
  }));
  return calls;
}

const WEB_SEARCH = { contents: { twoColumnSearchResultsRenderer: { primaryContents: { sectionListRenderer: { contents: [
  { itemSectionRenderer: { contents: [{ videoRenderer: { videoId: "webVideo001", title: { runs: [{ text: "Web" }] },
    ownerText: { runs: [{ text: "Chan" }] }, lengthText: { simpleText: "3:00" } } }] } },
] } } } } };
const WEB_NEXT = { contents: { twoColumnWatchNextResults: {
  results: { results: { contents: [{ videoPrimaryInfoRenderer: { dateText: { simpleText: "May 2013" } } }] } },
  secondaryResults: { secondaryResults: { results: [
    { compactVideoRenderer: { videoId: "webNext0001", title: { simpleText: "W" }, lengthText: { simpleText: "1:00" } } },
  ] } },
} } };

const MUSIC_SEARCH = "music.youtube.com/youtubei/v1/search";
const MUSIC_NEXT = "music.youtube.com/youtubei/v1/next";
const WEB_SEARCH_EP = "www.youtube.com/youtubei/v1/search";
const WEB_NEXT_EP = "www.youtube.com/youtubei/v1/next";

describe("the source switch", () => {
  let err: ReturnType<typeof vi.spyOn>;
  beforeEach(() => { err = vi.spyOn(console, "error").mockImplementation(() => {}); });
  afterEach(() => { vi.unstubAllGlobals(); err.mockRestore(); });

  it("YouTube asks youtube.com only", async () => {
    const calls = stubFetch({ [WEB_SEARCH_EP]: WEB_SEARCH, [WEB_NEXT_EP]: WEB_NEXT });
    expect((await searchFrom("youtube", "q", "none", "", "")).results[0].id).toBe("webVideo001");
    expect((await nextFrom("youtube", "seedVideo01", "none", "", "")).suggestions[0].id).toBe("webNext0001");
    expect(calls.every((c) => c.url.startsWith("https://www.youtube.com/"))).toBe(true);
  });

  it("YouTube Music searches songs and takes albums and playlists from the unfiltered page", async () => {
    const calls = stubFetch({ [MUSIC_SEARCH]: (b: any) => fixture(b.params ? "search-songs" : "search-top") });
    const r = await searchFrom("ytmusic", "daft punk", "none", "", "");
    expect(r.results[0].id).toBe("w3XzgjlKFjc");
    expect(r.playlists.length).toBeGreaterThan(0);
    expect(calls.every((c) => c.url.startsWith("https://music.youtube.com/"))).toBe(true);
    expect(calls[0].body.context.client.clientName).toBe("WEB_REMIX");
    expect(err).not.toHaveBeenCalled();
  });

  it("YouTube Music Songs is the songs list alone, in one request", async () => {
    const calls = stubFetch({ [MUSIC_SEARCH]: (b: any) => fixture(b.params ? "search-songs" : "search-top") });
    const r = await searchFrom("ytmusic", "daft punk", "none", "", "", { type: "song" });
    expect(r.results[0].id).toBe("w3XzgjlKFjc");
    expect(r.playlists).toEqual([]);
    expect(calls).toHaveLength(1);
  });

  it("a YouTube Music continuation goes back to YouTube Music, without its prefix", async () => {
    const calls = stubFetch({ [MUSIC_SEARCH]: fixture("search-songs-cont") });
    const r = await searchContinuationFrom("ytm:TOKEN", "none", "", "");
    expect(r.results.length).toBe(4);
    expect(calls[0].body.continuation).toBe("TOKEN");
  });

  it("a filter YouTube Music lacks searches YouTube", async () => {
    const calls = stubFetch({ [WEB_SEARCH_EP]: WEB_SEARCH });
    await searchFrom("ytmusic", "q", "none", "", "", { sort: "date" });
    expect(calls.map((c) => new URL(c.url).host)).toEqual(["www.youtube.com"]);
  });

  it("a failed YouTube Music search falls back to YouTube and logs one line", async () => {
    stubFetch({ [MUSIC_SEARCH]: new Error("down"), [WEB_SEARCH_EP]: WEB_SEARCH });
    const r = await searchFrom("ytmusic", "q", "none", "", "");
    expect(r.results[0].id).toBe("webVideo001");
    expect(err).toHaveBeenCalledTimes(1);
    expect(String(err.mock.calls[0][0])).toMatch(/^\[ytm\] search: .*using YouTube$/);
  });

  it("an empty YouTube Music search falls back to YouTube", async () => {
    stubFetch({ [MUSIC_SEARCH]: {}, [WEB_SEARCH_EP]: WEB_SEARCH });
    expect((await searchFrom("ytmusic", "q", "none", "", "")).results[0].id).toBe("webVideo001");
    expect(err).toHaveBeenCalledTimes(1);
  });

  it("YouTube Music suggestions come from its radio, with YouTube's track info", async () => {
    const calls = stubFetch({ [MUSIC_NEXT]: fixture("next"), [WEB_NEXT_EP]: WEB_NEXT });
    const r = await nextFrom("ytmusic", "5NV6Rdv1a3I", "none", "", "");
    expect(r.autoplay?.id).toBe("FGBhQbmPwH8");
    expect(r.info?.published).toBe("May 2013");
    const music = calls.find((c) => c.url.startsWith("https://music.youtube.com/"))!;
    expect(music.body).toMatchObject({ videoId: "5NV6Rdv1a3I", playlistId: "RDAMVM5NV6Rdv1a3I" });
    expect(music.body.context.client.clientName).toBe("WEB_REMIX");
  });

  it("failed YouTube Music suggestions fall back to YouTube's", async () => {
    stubFetch({ [MUSIC_NEXT]: new Error("down"), [WEB_NEXT_EP]: WEB_NEXT });
    const r = await nextFrom("ytmusic", "seedVideo01", "none", "", "");
    expect(r.suggestions[0].id).toBe("webNext0001");
    expect(err).toHaveBeenCalledTimes(1);
  });

  it("empty YouTube Music suggestions fall back to YouTube's", async () => {
    stubFetch({ [MUSIC_NEXT]: {}, [WEB_NEXT_EP]: WEB_NEXT });
    expect((await nextFrom("ytmusic", "seedVideo01", "none", "", "")).suggestions[0].id).toBe("webNext0001");
  });

  it("next continuations follow their token's service", async () => {
    const calls = stubFetch({ [MUSIC_NEXT]: fixture("next-cont"), [WEB_NEXT_EP]: { onResponseReceivedEndpoints: [] } });
    expect((await nextContinuationFrom("ytm:T1", "none", "", "")).suggestions.length).toBe(4);
    await nextContinuationFrom("T2", "none", "", "");
    expect(calls.map((c) => [new URL(c.url).host, c.body.continuation]))
      .toEqual([["music.youtube.com", "T1"], ["www.youtube.com", "T2"]]);
  });
});
