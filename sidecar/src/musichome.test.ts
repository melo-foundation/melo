import { describe, it, expect } from "vitest";
import { parseMusicHome, parseMusicHomeContinuation } from "./innertube";

// Shapes taken from live FEmusic_home responses; the values are invented.
const run = (text: string, nav?: any) => (nav ? { text, navigationEndpoint: nav } : { text });
const thumb = (url: string) => ({ musicThumbnailRenderer: { thumbnail: { thumbnails: [{ url }] } } });
const shelf = (title: string, contents: any[]) => ({
  musicCarouselShelfRenderer: { header: { musicCarouselShelfBasicHeaderRenderer: { title: { runs: [run(title)] } } }, contents },
});
const song = (videoId: string, title: string, artist: string) => ({
  musicResponsiveListItemRenderer: {
    thumbnail: thumb("https://i/" + videoId),
    flexColumns: [
      { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [run(title, { watchEndpoint: { videoId } })] } } },
      { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [run(artist, { browseEndpoint: { browseId: "UCa" } }), run(" • "), run("Some album")] } } },
    ],
  },
});
const twoRow = (title: string, subtitle: string, browseId: string, overlayPlaylist?: string) => ({
  musicTwoRowItemRenderer: {
    title: { runs: [run(title)] },
    subtitle: { runs: [run(subtitle)] },
    navigationEndpoint: { browseEndpoint: { browseId } },
    thumbnailRenderer: thumb("https://i/" + title),
    ...(overlayPlaylist ? { thumbnailOverlay: { musicItemThumbnailOverlayRenderer: { content: { musicPlayButtonRenderer: {
      playNavigationEndpoint: { watchPlaylistEndpoint: { playlistId: overlayPlaylist } } } } } } } : {}),
  },
});
const home = {
  responseContext: { visitorData: "VD1" },
  contents: { singleColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { content: { sectionListRenderer: {
    header: { chipCloudRenderer: { chips: [
      { chipCloudChipRenderer: { text: { runs: [run("Relax")] }, isSelected: false,
        navigationEndpoint: { browseEndpoint: { browseId: "FEmusic_home", params: "P_RELAX" } } } },
    ] } },
    contents: [
      shelf("Quick picks", [song("vid1", "Song A", "Artist A")]),
      shelf("New releases", [twoRow("Album X", "Album • Artist X", "MPREb_1", "OLAK5uy_1"),
                             twoRow("Mix Y", "Playlist • YouTube Music", "VLRDCLAK5uy_2", "RDCLAK5uy_2")]),
      shelf("Artists", [twoRow("Artist Z", "Artist", "UCz", "RDEMz"), twoRow("Artist Q", "Artist", "UCq")]),
    ],
    continuations: [{ nextContinuationData: { continuation: "C1" } }],
  } } } }] } },
};

describe("parseMusicHome", () => {
  const r = parseMusicHome(home);

  it("keeps the mood chips with what opens each", () => {
    expect(r.chips).toEqual([{ text: "Relax", params: "P_RELAX", isSelected: false }]);
  });

  it("keeps the continuation and the visitor it belongs to", () => {
    expect(r.continuation).toBe("C1");
    expect(r.visitorData).toBe("VD1");
  });

  it("keeps songs, which it used to drop, with their artist", () => {
    const qp = r.sections.find((s) => s.title === "Quick picks")!;
    expect(qp.items).toEqual([{ kind: "song", videoId: "vid1", playlistId: "", title: "Song A",
                                description: "Artist A", channel: "Artist A", thumbnail: "https://i/vid1" }]);
  });

  it("opens an album through its album playlist", () => {
    const album = r.sections.find((s) => s.title === "New releases")!.items[0];
    expect(album.kind).toBe("album");
    expect(album.playlistId).toBe("OLAK5uy_1");
  });

  it("still keeps playlists, without the VL prefix", () => {
    const pl = r.sections.find((s) => s.title === "New releases")!.items[1];
    expect(pl.kind).toBe("playlist");
    expect(pl.playlistId).toBe("RDCLAK5uy_2");
  });

  it("keeps an artist only when it has a radio to play", () => {
    const artists = r.sections.find((s) => s.title === "Artists")!.items;
    expect(artists.map((a) => [a.kind, a.playlistId])).toEqual([["artist", "RDEMz"]]);
  });
});

describe("parseMusicHomeContinuation", () => {
  it("reads the next shelves and the token after them", () => {
    const page = { continuationContents: { sectionListContinuation: {
      contents: [shelf("Pump it up", [twoRow("Mix", "Playlist", "VLPL1", "PL1")])],
      continuations: [{ nextContinuationData: { continuation: "C2" } }],
    } } };
    const r = parseMusicHomeContinuation(page);
    expect(r.sections.map((s) => s.title)).toEqual(["Pump it up"]);
    expect(r.continuation).toBe("C2");
  });

  it("ends when there is no further token", () => {
    const r = parseMusicHomeContinuation({ continuationContents: { sectionListContinuation: { contents: [] } } });
    expect(r.continuation).toBe("");
  });
});
