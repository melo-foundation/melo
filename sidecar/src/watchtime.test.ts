import { describe, it, expect, vi, afterEach } from "vitest";
import { reportPlayback, reportDelayplay, reportWatchtime, isVideoId, trackingUrls } from "./watchtime";

const player = vi.hoisted(() => ({ tracking: vi.fn() }));
vi.mock("./streams", () => ({ playerTracking: player.tracking }));
vi.mock("./innertube", () => ({ buildHeaders: async () => ({ "Content-Type": "application/json" }) }));

afterEach(() => vi.restoreAllMocks());

// A plugin track's id is not a YouTube video; it must never reach the watch
// page or a tracking URL, where it lands unencoded.
describe("watch-time reports", () => {
  it("accept only an 11-character video id", () => {
    expect(isVideoId("dQw4w9WgXcQ")).toBe(true);
    for (const bad of ["smp:1", "dQw4w9WgXcQ&list=x", "../dQw4w9WgX", "", "dQw4w9WgXcQQ", 42])
      expect(isVideoId(bad), String(bad)).toBe(false);
  });

  it("send nothing for an id that is not a video id", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("no network in tests"));
    expect(await reportPlayback("x&feature=evil", 100, "guest", "", "default")).toBe("");
    await reportDelayplay("x&feature=evil", "cpn", 100, "guest", "", "default");
    await reportWatchtime("x&feature=evil", "cpn", 0, 10, 100, "guest", "", "default");
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

// A guest watch page walls most music ("Sign in to confirm you're not a bot")
// and carries no playbackTracking; the player endpoint gives it.
describe("tracking URLs", () => {
  const walled = '<script>ytcfg.set({"visitorData":"Cgt2aXNpdG9y"});var ytInitialPlayerResponse = {"playabilityStatus":{"status":"LOGIN_REQUIRED"}};var x=1;</script>';
  const base = "https://s.youtube.com/api/stats/";

  it("come from the player endpoint when the watch page has none", async () => {
    player.tracking.mockResolvedValue({
      tracking: {
        videostatsPlaybackUrl: { baseUrl: `${base}playback?docid=ctFmqTzIAAM&ei=a` },
        videostatsWatchtimeUrl: { baseUrl: `${base}watchtime?docid=ctFmqTzIAAM&ei=a` },
        videostatsDelayplayUrl: { baseUrl: `${base}delayplay?docid=ctFmqTzIAAM&ei=a` },
        ptrackingUrl: { baseUrl: "https://www.youtube.com/ptracking?video_id=ctFmqTzIAAM" },
      },
      lengthSeconds: "200", channelId: "UC1", clientName: "WEB_REMIX", clientVersion: "1.2",
    });
    const urls: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (u) => {
      urls.push(String(u));
      return new Response(String(u).includes("/watch?") ? walled : "");
    });
    const cpn = await reportPlayback("ctFmqTzIAAM", 200, "none", "", "default");
    expect(Object.values(trackingUrls(cpn)).every(Boolean)).toBe(true);
    // asked as the visitor the watch page named
    expect(player.tracking.mock.calls[0].slice(0, 2)).toEqual(["ctFmqTzIAAM", "Cgt2aXNpdG9y"]);
    const ping = urls.find((u) => u.startsWith(`${base}playback`));
    expect(ping).toBeDefined();
    expect(new URL(ping!).searchParams.get("c")).toBe("WEB_REMIX");
    expect(new URL(ping!).searchParams.get("cpn")).toBe(cpn);
  });

  it("skip the player endpoint when the watch page has them", async () => {
    player.tracking.mockReset();
    const page = '<script>var ytInitialPlayerResponse = {"playbackTracking":{"videostatsPlaybackUrl":' +
      `{"baseUrl":"${base}playback?docid=dQw4w9WgXcQ"}}};var x=1;</script>`;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (u) => new Response(String(u).includes("/watch?") ? page : ""));
    const cpn = await reportPlayback("dQw4w9WgXcQ", 200, "none", "", "default");
    expect(trackingUrls(cpn).playback).toContain("docid=dQw4w9WgXcQ");
    expect(player.tracking).not.toHaveBeenCalled();
  });
});
