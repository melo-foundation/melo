import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Fixtures are guest album pages from music.youtube.com (browse MPREb_Szd8UWfH1xz,
// an album, and MPREb_Txr054MMTCD, a single), trimmed, with no cookies, visitor ids or tracking.
const h = vi.hoisted(() => ({
  settings: { cookieSource: "guest", browser: "", cookieProfile: "test", homeSource: "ytmusic",
              ui: { thumbQuality: "medium" } } as Record<string, unknown>,
}));
vi.mock("./settings", async (orig) => ({
  ...(await orig<typeof import("./settings")>()),
  loadSettings: () => h.settings,
  localePref: () => ({ hl: "en", gl: "US" }),
}));
vi.mock("./guest-cookies", async (orig) => ({
  ...(await orig<typeof import("./guest-cookies")>()),
  getGuestCookies: async () => [],
  captureResponseCookies: () => {},
}));
vi.mock("./ytdlp", () => ({ ytdlp: vi.fn(async () => { throw new Error("no yt-dlp in tests"); }),
                            looksStale: () => false, ytdlpChannel: () => "stable" }));
vi.mock("./potoken", () => ({ poTokenSession: vi.fn(), mintPoToken: async () => null, warmPoTokenSession: () => {} }));
vi.mock("./stream-relay", () => ({ relayUrl: async (raw: string) => raw }));

import { parseMusicAlbum, parseMusicSearch, fetchMusicAlbum, knownMusicInfo, singlesInfo,
         clearAlbumCacheForTest } from "./innertube";
import { fetchAlbumTracks, fetchPlaylistTracks, moreList, setSessionBuilderForTest } from "./streams";

const fixture = (name: string) =>
  JSON.parse(readFileSync(join(__dirname, "..", "test-fixtures", "ytm", name + ".json"), "utf-8"));

const ok = (body: unknown) => ({ ok: true, status: 200, statusText: "OK", headers: new Headers(), json: async () => body });

// a one-page playlist as youtubei.js returns it: no continuation
function onePagePlaylist(ids: string[]) {
  return {
    info: { title: "Fallback" },
    has_continuation: false,
    items: ids.map((id) => ({ id, title: { text: "T " + id }, author: { name: "A" }, duration: { seconds: 60 },
                              thumbnails: [{ url: "https://i.ytimg.com/vi/" + id + "/hq.jpg" }] })),
    getContinuation: async () => { throw new Error("no continuation"); },
  };
}

describe("YouTube Music album page", () => {
  it("reads an album's header and every track, with no continuation", () => {
    const a = parseMusicAlbum(fixture("album"), "MPREb_Szd8UWfH1xz")!;
    expect(a).toMatchObject({ title: "BOLO: Book II", artist: "T-Rock", artists: ["T-Rock"], kind: "Album", year: 2026,
                              playlistId: expect.stringMatching(/^OLAK5uy_/), continuation: "" });
    expect(a.thumbnail).toMatch(/googleusercontent\.com\/.*=w360-h360/);
    expect(a.tracks.length).toBe(14);
    expect(a.tracks[0]).toMatchObject({ id: "je-Ex5XF5kI", title: "Blah", channel: "T-Rock", duration: 166,
                                        views: "13K plays", album: "BOLO: Book II", albumId: "MPREb_Szd8UWfH1xz",
                                        year: 2026, thumbnail: a.thumbnail });
    expect(a.tracks[13].duration).toBe(279);
    // the tagging cache learns the album from the page
    expect(knownMusicInfo("je-Ex5XF5kI")).toMatchObject({ album: "BOLO: Book II", year: 2026 });
  });

  it("reads a single: one track, its type and year", () => {
    const a = parseMusicAlbum(fixture("album-single"), "MPREb_Txr054MMTCD")!;
    expect(a).toMatchObject({ title: "Blah Blah Blah", artist: "Bilal Saeed", kind: "Single", year: 2016 });
    expect(a.tracks).toHaveLength(1);
    expect(a.tracks[0]).toMatchObject({ id: "aTOaMuNAbyg", title: "Blah Blah Blah", channel: "Bilal Saeed", duration: 181 });
  });

  it("is null for a page that is not an album", () => {
    expect(parseMusicAlbum(fixture("search-top"), "MPREb_x")).toBeNull();
    expect(parseMusicAlbum({}, "MPREb_x")).toBeNull();
  });

  it("gives a search row's album page as its browseId, and none to a playlist", () => {
    const r = parseMusicSearch(fixture("search-top"));
    const album = r.playlists.find((p) => p.title === "Random Access Memories")!;
    expect(album.browseId).toMatch(/^MPRE/);
    expect(album.playlistId).toMatch(/^OLAK5uy_/);
    for (const p of r.playlists.filter((p) => !p.playlistId.startsWith("OLAK"))) expect(p.browseId).toBeUndefined();
  });
});

describe("opening an album", () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    setSessionBuilderForTest(null);
    clearAlbumCacheForTest();
  });

  it("reads an album page once in five minutes", async () => {
    fetchMock.mockResolvedValue(ok(fixture("album-single")));
    await fetchMusicAlbum("MPREb_Txr054MMTCD", "guest", "", "test");
    await fetchMusicAlbum("MPREb_Txr054MMTCD", "guest", "", "test");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("browses the album page with WEB_REMIX, once", async () => {
    fetchMock.mockResolvedValue(ok(fixture("album")));
    const a = await fetchMusicAlbum("MPREb_Szd8UWfH1xz", "guest", "", "test");
    expect(a!.tracks).toHaveLength(14);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toMatch(/^https:\/\/music\.youtube\.com\/youtubei\/v1\/browse/);
    const body = JSON.parse(init.body);
    expect(body.browseId).toBe("MPREb_Szd8UWfH1xz");
    expect(body.context.client.clientName).toBe("WEB_REMIX");
  });

  it("returns the whole album with an empty cursor", async () => {
    fetchMock.mockResolvedValue(ok(fixture("album-single")));
    const r: any = await fetchAlbumTracks("MPREb_Txr054MMTCD", "OLAK5uy_x");
    expect(r).toMatchObject({ ok: true, title: "Blah Blah Blah", artist: "Bilal Saeed", kind: "Single", year: 2016, cursor: "" });
    expect(r.tracks).toHaveLength(1);
  });

  it("falls back to the playlist when the page fails, and that ends with no cursor", async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, statusText: "Server Error", headers: new Headers(), json: async () => ({}) });
    const getPlaylist = vi.fn(async () => onePagePlaylist(["aaaaaaaaaaa", "bbbbbbbbbbb"]));
    setSessionBuilderForTest(async () => ({ getPlaylist } as any));
    const r: any = await fetchAlbumTracks("MPREb_x", "OLAK5uy_fallback");
    expect(getPlaylist).toHaveBeenCalledWith("OLAK5uy_fallback");
    expect(r.ok).toBe(true);
    expect(r.tracks.map((t: any) => t.id)).toEqual(["aaaaaaaaaaa", "bbbbbbbbbbb"]);
    expect(r.cursor).toBe("");
  });

  it("falls back on an empty page too", async () => {
    fetchMock.mockResolvedValue(ok({ contents: {} }));
    setSessionBuilderForTest(async () => ({ getPlaylist: async () => onePagePlaylist(["ccccccccccc"]) } as any));
    const r: any = await fetchAlbumTracks("MPREb_x", "OLAK5uy_empty");
    expect(r.tracks).toHaveLength(1);
    expect(r.cursor).toBe("");
  });

  it("fails, without looping, when there is no page and no playlist", async () => {
    fetchMock.mockRejectedValue(new Error("offline"));
    const r: any = await fetchAlbumTracks("MPREb_x", "");
    expect(r.ok).toBe(false);
  });
});

describe("singles in search", () => {
  const single = parseMusicAlbum(fixture("album-single"), "MPREb_Txr054MMTCD")!;
  const album = parseMusicAlbum(fixture("album"), "MPREb_Szd8UWfH1xz")!;

  it("gives a one-track single its song and length", async () => {
    const r = await singlesInfo(["MPREb_Txr054MMTCD"], async () => single);
    expect(r).toHaveLength(1);
    expect(r[0].duration).toBe(181);
    expect(r[0].track).toMatchObject({ id: "aTOaMuNAbyg", duration: 181, album: "Blah Blah Blah" });
  });

  it("gives a longer single its summed length and no song", async () => {
    const r = await singlesInfo(["MPREb_Szd8UWfH1xz"], async () => album);
    expect(r[0].track).toBeUndefined();
    expect(r[0].duration).toBe(album.tracks.reduce((n, t) => n + t.duration, 0));
  });

  it("leaves out a page that fails or is not an album page", async () => {
    const fetchAlbum = vi.fn(async (id: string) => { if (id === "MPREb_bad") throw new Error("offline"); return single; });
    const r = await singlesInfo(["MPREb_bad", "VLPLx", "MPREb_ok"], fetchAlbum);
    expect(fetchAlbum).toHaveBeenCalledTimes(2);
    expect(r.map((s) => s.browseId)).toEqual(["MPREb_ok"]);
  });
});

describe("a one-page playlist", () => {
  afterEach(() => setSessionBuilderForTest(null));

  it("has no cursor, so the view never asks for an empty page", async () => {
    setSessionBuilderForTest(async () => ({ getPlaylist: async () => onePagePlaylist(["ddddddddddd"]) } as any));
    const r: any = await fetchPlaylistTracks("OLAK5uy_single");
    expect(r.tracks).toHaveLength(1);
    expect(r.cursor).toBe("");
  });

  it("keeps a cursor while the playlist has more, and drops it at the end", async () => {
    const last = onePagePlaylist(["fffffffffff"]);
    const first = { ...onePagePlaylist(["eeeeeeeeeee"]), has_continuation: true, getContinuation: async () => last };
    setSessionBuilderForTest(async () => ({ getPlaylist: async () => first } as any));
    const r: any = await fetchPlaylistTracks("PLtwopages");
    expect(r.cursor).not.toBe("");
    const more: any = await moreList(r.cursor);
    expect(more.tracks.map((t: any) => t.id)).toEqual(["fffffffffff"]);
    expect(more.cursor).toBe("");
  });
});
