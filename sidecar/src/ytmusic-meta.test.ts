import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Fixtures are guest responses from music.youtube.com with no cookies, visitor
// ids or tracking. watch-atv: uSFXOBaqiR8 (art track), watch-omv: x84m3YyO2oU
// (official video, no counterpart as a guest), watch-ugc: bdzAg2CXQxA (an
// upload). watch-paired puts the OMV's real renderer and its real audio track
// (JhulBGMA7G4) in the wrapper YouTube Music uses to pair them.
vi.mock("./settings", async (orig) => ({
  ...(await orig<typeof import("./settings")>()),
  loadSettings: () => ({ ui: { thumbQuality: "medium" }, cookieSource: "guest", browser: "", cookieProfile: "t" }),
  localePref: () => ({ hl: "en", gl: "US" }),
}));
vi.mock("./guest-cookies", async (orig) => ({
  ...(await orig<typeof import("./guest-cookies")>()),
  getGuestCookies: async () => [],
  captureResponseCookies: () => {},
}));
const stored = new Map<string, any>();
vi.mock("./library", () => ({
  updateTrackMetadata: (id: string, m: any) => { stored.set(id, m); return true; },
  cacheAlbumArt: async () => "art.jpg",
}));

import { parseMusicSearch, parseMusicNext, parseMusicWatchInfo, bylineInfo } from "./innertube";
import { watchMetadata, lookupMetadata, lookupYoutubeMusic, __setWatchInfoForTest } from "./metadata";
import { enrichTrack, splitMusicExtras, videoIdOf } from "./tagging";

const fixture = (name: string) =>
  JSON.parse(readFileSync(join(__dirname, "..", "test-fixtures", "ytm", name + ".json"), "utf-8"));

const ALL_ON = { lastfmApiKey: "", tagYoutubeMusic: true, tagLastfm: true, tagMusicBrainz: true, tagDeezer: true };

describe("YouTube Music track info in results", () => {
  it("gives a Songs row its linked artists, album and square cover", () => {
    const t = parseMusicSearch(fixture("search-songs")).results.find((r) => r.id === "uSFXOBaqiR8")!;
    expect(t).toMatchObject({ channel: "Daft Punk", artists: ["Daft Punk"], album: "Veridis Quo", albumId: "MPREb_ACdoDdB5hLk" });
    expect(t.thumbnail).toMatch(/googleusercontent\.com\/.*=w360-h360/);
  });

  it("keeps an album row's kind and year, and gives it no count", () => {
    const pl = parseMusicSearch(fixture("search-top")).playlists;
    expect(pl.find((p) => p.title === "Random Access Memories")).toMatchObject({ kind: "Album", year: 2013, videoCount: 0 });
    expect(pl.find((p) => p.title === "Aerodynamic")).toMatchObject({ kind: "Single", year: 2001 });
    const user = pl.find((p) => p.title === "All Daft Punk Songs In Order")!;
    expect(user).toMatchObject({ kind: "Playlist", channel: "IffyAlex", videoCount: 0 });
    expect(user.year).toBeUndefined();
    expect(pl.find((p) => p.title === "Presenting Daft Punk")).toMatchObject({ videoCount: 35 });
  });

  it("names every linked artist, not an uploader's channel", () => {
    const runs = [
      { text: "A", navigationEndpoint: { browseEndpoint: { browseId: "UC1", browseEndpointContextSupportedConfigs:
        { browseEndpointContextMusicConfig: { pageType: "MUSIC_PAGE_TYPE_ARTIST" } } } } },
      { text: " & " },
      { text: "B", navigationEndpoint: { browseEndpoint: { browseId: "UC2" } } },
      { text: " • " },
      { text: "Album X", navigationEndpoint: { browseEndpoint: { browseId: "MPREb_1" } } },
      { text: " • " }, { text: "2019" },
    ];
    expect(bylineInfo(runs)).toEqual({ artists: ["A", "B"], album: "Album X", albumId: "MPREb_1", year: 2019 });
    const ugc = fixture("watch-ugc").contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer
      .watchNextTabbedResultsRenderer.tabs[0].tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer
      .contents[0].playlistPanelVideoRenderer.longBylineText.runs;
    expect(bylineInfo(ugc)).toEqual({});
  });

  it("gives radio tracks their album and year where the byline has them", () => {
    const r = parseMusicNext(fixture("watch-atv"), "");
    expect(r.autoplay).toMatchObject({ id: "uSFXOBaqiR8", album: "Veridis Quo", year: 2001, artists: ["Daft Punk"] });
    const omv = parseMusicNext(fixture("next"), "5NV6Rdv1a3I").autoplay!;
    expect(omv.album).toBeUndefined();
  });
});

describe("YouTube Music watch info", () => {
  it("reads an art track", () => {
    expect(parseMusicWatchInfo(fixture("watch-atv"), "uSFXOBaqiR8")).toMatchObject({
      type: "ATV", title: "Veridis Quo (Edit)", artist: "Daft Punk", album: "Veridis Quo", year: 2001,
      cover: expect.stringMatching(/googleusercontent/),
    });
  });

  it("reads an official video and its paired audio track", () => {
    const solo = parseMusicWatchInfo(fixture("watch-omv"), "x84m3YyO2oU")!;
    expect(solo).toMatchObject({ type: "OMV", artist: "Daft Punk" });
    expect(solo.album).toBeUndefined();
    expect(solo.counterpart).toBeUndefined();
    const paired = parseMusicWatchInfo(fixture("watch-paired"), "x84m3YyO2oU")!;
    expect(paired.counterpart).toMatchObject({ videoId: "JhulBGMA7G4", type: "ATV", album: "Discovery", year: 2001 });
  });

  it("is null for a video the queue does not list", () => {
    expect(parseMusicWatchInfo(fixture("watch-atv"), "zzzzzzzzzzz")).toBeNull();
  });

  it("tags an art track with its album, year and a large square cover", () => {
    expect(watchMetadata(parseMusicWatchInfo(fixture("watch-atv"), "uSFXOBaqiR8"))).toEqual({
      artist: "Daft Punk", cleanTitle: "Veridis Quo (Edit)", album: "Veridis Quo", year: 2001,
      albumArt: expect.stringMatching(/googleusercontent\.com\/.*=w1000-h1000/), source: "ytmusic",
    });
  });

  it("tags an official video from its audio track", () => {
    expect(watchMetadata(parseMusicWatchInfo(fixture("watch-paired"), "x84m3YyO2oU"))).toMatchObject({
      artist: "Daft Punk", cleanTitle: "Harder, Better, Faster, Stronger", album: "Discovery", year: 2001,
      albumArt: expect.stringMatching(/=w1000-h1000/), source: "ytmusic",
    });
  });

  it("has no tags for an upload, or an official video with no audio track", () => {
    expect(watchMetadata(parseMusicWatchInfo(fixture("watch-ugc"), "bdzAg2CXQxA"))).toBeNull();
    expect(watchMetadata(parseMusicWatchInfo(fixture("watch-omv"), "x84m3YyO2oU"))).toBeNull();
  });
});

describe("the lookup chain with YouTube Music", () => {
  const realFetch = globalThis.fetch;
  let asked: string[];
  let webCalls: string[];
  const watch = (name: string, id: string) => async (videoId: string) => {
    asked.push(videoId);
    return parseMusicWatchInfo(fixture(name), id);
  };
  beforeEach(() => {
    asked = []; webCalls = []; stored.clear();
    // MusicBrainz finds the track; nothing else does
    globalThis.fetch = (async (url: any) => {
      const u = String(url);
      webCalls.push(u);
      if (u.includes("musicbrainz.org/ws/2/recording")) {
        return new Response(JSON.stringify({ recordings: [{ score: 100, title: "Superheroes",
          "artist-credit": [{ name: "Daft Punk" }], releases: [{ title: "Discovery", date: "2001-03-12", id: "r1" }] }] }), { status: 200 });
      }
      return new Response(JSON.stringify({ recordings: [], artists: [], data: [] }), { status: 200 });
    }) as any;
  });
  afterEach(() => { globalThis.fetch = realFetch; });

  it("asks YouTube Music first, and stops there on a hit", async () => {
    __setWatchInfoForTest(watch("watch-paired", "x84m3YyO2oU"));
    const r = await lookupMetadata("Daft Punk", "Harder, Better, Faster, Stronger", undefined, undefined,
      { ytmusic: true, lastfm: true, musicbrainz: true, deezer: true }, "x84m3YyO2oU");
    expect(r).toMatchObject({ source: "ytmusic", album: "Discovery" });
    expect(asked).toEqual(["x84m3YyO2oU"]);
    expect(webCalls).toEqual([]);
  });

  it("goes on to MusicBrainz for an upload", async () => {
    __setWatchInfoForTest(watch("watch-ugc", "bdzAg2CXQxA"));
    const r = await lookupMetadata("Daft Punk", "Superheroes", undefined, undefined,
      { ytmusic: true, lastfm: true, musicbrainz: true, deezer: true }, "bdzAg2CXQxA");
    expect(asked).toEqual(["bdzAg2CXQxA"]);
    expect(r).toMatchObject({ source: "musicbrainz", album: "Discovery" });
  });

  it("never asks YouTube Music when it is off", async () => {
    __setWatchInfoForTest(watch("watch-atv", "uSFXOBaqiR8"));
    const r = await lookupMetadata("Daft Punk", "Superheroes", undefined, undefined,
      { ytmusic: false, lastfm: true, musicbrainz: true, deezer: true }, "uSFXOBaqiR8");
    expect(asked).toEqual([]);
    expect(r?.source).toBe("musicbrainz");
  });

  it("answers from a track it already listed, with no request", async () => {
    __setWatchInfoForTest(watch("watch-ugc", "bdzAg2CXQxA"));
    parseMusicSearch(fixture("search-songs"));   // lists NOMa56y_Was with its album
    const r = await lookupYoutubeMusic("NOMa56y_Was");
    expect(r).toMatchObject({ source: "ytmusic", album: "TRON: Legacy", artist: "Daft Punk" });
    expect(asked).toEqual([]);
  });
});

describe("tagging a library track", () => {
  const realFetch = globalThis.fetch;
  let asked: string[];
  beforeEach(() => {
    asked = []; stored.clear();
    __setWatchInfoForTest(async (id) => { asked.push(id); return null; });
    globalThis.fetch = (async () => { throw new Error("no network in test"); }) as any;
  });
  afterEach(() => { globalThis.fetch = realFetch; });

  const sent = {
    id: "Zz9yyyyyyyy", title: "Song", channel: "Artist A & Artist B", duration: 200,
    thumbnail: "https://lh3.googleusercontent.com/abc=w360-h360-l90-rj",
    album: "The Album", albumId: "MPREb_x", year: 2019, artists: ["Artist A", "Artist B"],
  };

  it("splits a sent track into the stored track and its YouTube Music extras", () => {
    const { track, extras } = splitMusicExtras(sent);
    expect(track).toEqual({ id: sent.id, title: "Song", channel: sent.channel, duration: 200, thumbnail: sent.thumbnail });
    expect(extras).toEqual({ album: "The Album", albumId: "MPREb_x", year: 2019, artists: ["Artist A", "Artist B"] });
  });

  it("uses the album a track arrives with, with no lookup", async () => {
    const { track, extras } = splitMusicExtras(sent);
    const ok = await enrichTrack({ ...track, downloaded: false, addedAt: 0 }, "api", ALL_ON, extras);
    expect(ok).toBe(true);
    expect(asked).toEqual([]);
    expect(stored.get(sent.id)).toEqual({
      artist: "Artist A & Artist B", cleanTitle: "Song", album: "The Album", year: 2019, source: "ytmusic",
      albumArt: "https://lh3.googleusercontent.com/abc=w1000-h1000-l90-rj", albumArtFile: "art.jpg",
    });
  });

  it("looks the video up when YouTube Music is on and nothing came with it", async () => {
    await enrichTrack({ id: "Qq1zzzzzzzz", title: "Song", channel: "Chan", duration: 1, thumbnail: "",
                        downloaded: false, addedAt: 0 }, "api", ALL_ON);
    expect(asked).toEqual(["Qq1zzzzzzzz"]);
  });

  it("never overwrites tags edited by hand", async () => {
    const { track, extras } = splitMusicExtras(sent);
    const ok = await enrichTrack({ ...track, downloaded: false, addedAt: 0,
                                   metadata: { artist: "Mine", source: "manual" } }, "api", ALL_ON, extras);
    expect(ok).toBe(false);
    expect(stored.size).toBe(0);
    expect(asked).toEqual([]);
  });

  it("does not use the carried album when YouTube Music is off", async () => {
    const { track, extras } = splitMusicExtras(sent);
    await enrichTrack({ ...track, downloaded: false, addedAt: 0 }, "api",
                      { ...ALL_ON, tagYoutubeMusic: false, tagMusicBrainz: false, tagDeezer: false }, extras);
    expect(stored.get(sent.id)?.source).not.toBe("ytmusic");
    expect(asked).toEqual([]);
  });

  it("knows which tracks are YouTube videos", () => {
    expect(videoIdOf({ id: "uSFXOBaqiR8" })).toBe("uSFXOBaqiR8");
    expect(videoIdOf({ id: "local:abc", youtubeId: "uSFXOBaqiR8" })).toBe("uSFXOBaqiR8");
    expect(videoIdOf({ id: "local:abc" })).toBeUndefined();
    expect(videoIdOf({ id: "abcdefghijk", source: "someplugin" })).toBeUndefined();
  });
});
