import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// Resolver tests run offline: yt-dlp, the PO token, cookies, the relay and
// fetch are all stand-ins.
const h = vi.hoisted(() => ({
  settings: {} as Record<string, unknown>,
  ytdlp: vi.fn(),
  poTokenSession: vi.fn(),
  mergeGuestCookies: vi.fn(),
  channel: "stable",
}));
vi.mock("./ytdlp", () => ({
  ytdlp: h.ytdlp, looksStale: () => false, ytdlpChannel: () => h.channel,
}));
vi.mock("./settings", async (orig) => ({
  ...(await orig<typeof import("./settings")>()),
  loadSettings: () => h.settings,
  localePref: () => ({ hl: "en", gl: "US" }),
}));
vi.mock("./potoken", () => ({
  poTokenSession: h.poTokenSession, mintPoToken: async () => null, warmPoTokenSession: () => {},
}));
vi.mock("./guest-cookies", async (orig) => ({
  ...(await orig<typeof import("./guest-cookies")>()),
  writeNetscapeCookieFile: async () => "/nonexistent/melo-test-cookies.txt",
  parseNetscapeCookieFile: () => [{ name: "VISITOR_INFO1_LIVE", value: "x", domain: ".youtube.com" }],
  mergeGuestCookies: h.mergeGuestCookies,
  cookiesTxtPath: () => "/nonexistent/melo-test-cookies.txt",
}));
vi.mock("./library", async (orig) => ({
  ...(await orig<typeof import("./library")>()),
  getDownloadedUrl: () => null,
}));
vi.mock("./stream-relay", () => ({ relayUrl: async (raw: string) => raw }));
import { fetchStreamUrl, setSessionBuilderForTest, fetchVideoStreamUrl, needsStreamRelay, ytdlpReason, streamIdentity, resolveIdentities, isBotWall } from "./streams";
import type { SettingsV2 } from "./settings";
import { invalidateStreamCache, invalidateVideoCache, primeVideoCacheForTest, primeStreamCacheForTest, videoCacheHas, streamCacheHas } from "./streams";
import { WALL_MESSAGES, forgetWalls, setBrowserSignedInForTest, videoFormatSelector } from "./streams";

describe("needsStreamRelay", () => {
  it("is true for googlevideo CDN hosts", () => {
    expect(needsStreamRelay(
      "https://rr2---sn-uxanug5-hxaes.googlevideo.com/videoplayback?expire=1&id=x",
    )).toBe(true);
    expect(needsStreamRelay("https://googlevideo.com/videoplayback")).toBe(true);
  });

  it("is false for the localhost relay, file URLs, and other https", () => {
    expect(needsStreamRelay("http://127.0.0.1:12345/s/abc")).toBe(false);
    expect(needsStreamRelay("http://localhost:12345/s/abc")).toBe(false);
    expect(needsStreamRelay("file:///home/me/Music/track.webm")).toBe(false);
    expect(needsStreamRelay("https://www.youtube.com/watch?v=RIItBfZ6S3Q")).toBe(false);
    expect(needsStreamRelay("https://example.com/audio.mp3")).toBe(false);
    expect(needsStreamRelay("")).toBe(false);
  });
});

describe("streamIdentity", () => {
  const base = { cookieSource: "guest", browser: "firefox", cookieProfile: "Jazz" } as SettingsV2;
  it("is the browser when playback cookies are the browser's", () => {
    expect(streamIdentity({ ...base, streamCookieSource: "browser" })).toEqual(["browser", "firefox", "Jazz"]);
  });
  it("is the main identity otherwise", () => {
    expect(streamIdentity({ ...base, streamCookieSource: "same" })).toEqual(["guest", "firefox", "Jazz"]);
  });
});

describe("resolveIdentities", () => {
  const base = { cookieSource: "guest", browser: "firefox", cookieProfile: "Jazz" } as SettingsV2;
  it("tries the main identity, then the browser, when set to Browser", () => {
    expect(resolveIdentities({ ...base, streamCookieSource: "browser" }))
      .toEqual([["guest", "firefox", "Jazz"], ["browser", "firefox", "Jazz"]]);
  });
  it("is the main identity alone when set to Same", () => {
    expect(resolveIdentities({ ...base, streamCookieSource: "same" })).toEqual([["guest", "firefox", "Jazz"]]);
  });
  it("is none, then the browser, when the main identity is none", () => {
    expect(resolveIdentities({ ...base, cookieSource: "none", streamCookieSource: "browser" }))
      .toEqual([["none", "firefox", "Jazz"], ["browser", "firefox", "Jazz"]]);
  });
  it("is the browser alone when the main identity is already the browser", () => {
    expect(resolveIdentities({ ...base, cookieSource: "browser", streamCookieSource: "browser" }))
      .toEqual([["browser", "firefox", "Jazz"]]);
  });
});

describe("isBotWall", () => {
  it("matches YouTube's bot wall", () => {
    expect(isBotWall("Sign in to confirm you’re not a bot. Use --cookies-from-browser ...")).toBe(true);
  });
  it("ignores other failures", () => {
    expect(isBotWall("This video is not available")).toBe(false);
  });
});

describe("ytdlpReason", () => {
  it("skips a blank first line and warnings", () => {
    expect(ytdlpReason("\nWARNING: [youtube] x: nsig extraction failed\nERROR: [youtube] rYAe_MfPTDY: This video is not available\n"))
      .toBe("This video is not available");
  });
  it("keeps a message that is not an ERROR line", () => {
    expect(ytdlpReason("Error: spawn yt-dlp ENOENT")).toBe("Error: spawn yt-dlp ENOENT");
  });
  it("is empty for empty output", () => {
    expect(ytdlpReason("\n\n")).toBe("");
  });
  it("says the disk is full when yt-dlp could not unpack itself", () => {
    expect(ytdlpReason("[PYI-4672:ERROR] Failed to extract Cryptodome/Cipher/_ARC4.abi3.so: decompression resulted in return code -1!\n"))
      .toMatch(/^yt-dlp could not unpack into .+: the disk is full$/);
  });
});

describe("video cache", () => {
  it("is keyed per video and cap, and a video 403 leaves the audio entry alone", () => {
    primeStreamCacheForTest("vid1", "https://rr1.googlevideo.com/a?expire=9999999999&clen=10");
    primeVideoCacheForTest("vid1", 720, "https://rr1.googlevideo.com/v?expire=9999999999&clen=10");
    primeVideoCacheForTest("vid1", 1080, "https://rr1.googlevideo.com/w?expire=9999999999&clen=10");
    expect(videoCacheHas("vid1", 720)).toBe(true);
    expect(videoCacheHas("vid1", 1080)).toBe(true);
    invalidateVideoCache("vid1");
    expect(videoCacheHas("vid1", 720)).toBe(false);
    expect(videoCacheHas("vid1", 1080)).toBe(false);
    expect(streamCacheHas("vid1")).toBe(true);
    invalidateStreamCache("vid1");
    expect(streamCacheHas("vid1")).toBe(false);
  });
});

describe("fetchVideoStreamUrl", () => {
  it("names the video it resolved", async () => {
    primeVideoCacheForTest("vid2", 720, "https://example.com/v?expire=9999999999&clen=10");
    const r = await fetchVideoStreamUrl("vid2", 720, ["vp9"]);
    expect(r.ok).toBe(true);
    expect((r as { videoId?: string }).videoId).toBe("vid2");
    invalidateVideoCache("vid2");
  });
});

// The ytdlp stand-in answers per identity (which cookie flag it got) and per
// client (player_client, "default" when none is named).
type Answer = { url: string } | { err: string };
function ytdlpAnswers(table: (identity: string, client: string) => Answer) {
  h.ytdlp.mockImplementation(async (args: string[]) => {
    const identity = args.includes("--cookies-from-browser") ? "browser"
      : args.includes("--cookies") ? "guest" : "none";
    const ex = args.find((a) => a.startsWith("youtube:player_client="));
    const client = ex ? /player_client=([^;]+)/.exec(ex)![1] : "default";
    const a = table(identity, client);
    if ("err" in a) throw Object.assign(new Error("yt-dlp failed"), { stderr: `ERROR: [youtube] x: ${a.err}` });
    return { stdout: JSON.stringify({ url: a.url, title: "t", channel: "c", duration: 1, thumbnail: "" }) };
  });
}
const WALL = "Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.";
const GOOD = "https://rr1.googlevideo.com/videoplayback?expire=9999999999&clen=10&good";
const WALLED = "https://rr1.googlevideo.com/videoplayback?expire=9999999999&clen=10&walled";

describe("fetchStreamUrl identities", () => {
  const guestThenBrowser = { cookieSource: "guest", browser: "firefox", cookieProfile: "Default",
                             streamCookieSource: "browser" };
  beforeEach(async () => {
    await new Promise((r) => setImmediate(r));   // the last test's cookie writeback
    h.ytdlp.mockReset();
    h.mergeGuestCookies.mockReset();
    h.poTokenSession.mockResolvedValue(null);   // innertube declines at once
    h.settings = { ...guestThenBrowser };
    vi.stubGlobal("fetch", vi.fn(async (url: string) => ({
      status: String(url).includes("walled") ? 403 : 206,
      body: { cancel: () => {} },
      text: async () => "",
    })));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    setSessionBuilderForTest(null);
    setBrowserSignedInForTest(null);
    forgetWalls();
  });

  it("says guest playback only when the guest was refused", async () => {
    h.settings = { ...guestThenBrowser, streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    const e = await fetchStreamUrl("idW1").catch((x) => x);
    expect(e).toMatchObject({ code: -32040, message: WALL_MESSAGES.guest, data: { identity: "guest" } });
  });

  it("does not say guest when no cookies were sent", async () => {
    h.settings = { ...guestThenBrowser, cookieSource: "none", streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    const e = await fetchStreamUrl("idW2").catch((x) => x);
    expect(e).toMatchObject({ code: -32040, message: WALL_MESSAGES.none, data: { identity: "none" } });
    expect(e.message).not.toMatch(/guest/);
  });

  it("reports -32041 when the browser's cookies met the wall too", async () => {
    setBrowserSignedInForTest(async () => true);
    ytdlpAnswers(() => ({ err: WALL }));
    const e = await fetchStreamUrl("idW3").catch((x) => x);
    expect(e).toMatchObject({ code: -32041, message: WALL_MESSAGES.browser,
                              data: { identity: "browser", signedIn: true } });
    expect(e.message).not.toMatch(/guest/);
  });

  it("offers no switch to nightly when yt-dlp is on nightly already", async () => {
    setBrowserSignedInForTest(async () => true);
    h.channel = "nightly";
    try {
      ytdlpAnswers(() => ({ err: WALL }));
      const e = await fetchStreamUrl("idW3n").catch((x) => x);
      expect(e).toMatchObject({ code: -32041, message: WALL_MESSAGES.browserNightly });
      expect(e.message).not.toMatch(/nightly/);
    } finally { h.channel = "stable"; }
  });

  it("says the browser is signed out when its store has no YouTube login", async () => {
    setBrowserSignedInForTest(async () => false);
    ytdlpAnswers(() => ({ err: WALL }));
    await expect(fetchStreamUrl("idW4")).rejects.toMatchObject({
      code: -32041, message: WALL_MESSAGES.browserSignedOut, data: { signedIn: false } });
  });

  it("keeps the browser-only wall at -32041", async () => {
    h.settings = { ...guestThenBrowser, cookieSource: "browser" };
    setBrowserSignedInForTest(async () => null);
    ytdlpAnswers(() => ({ err: WALL }));
    await expect(fetchStreamUrl("idW5")).rejects.toMatchObject({ code: -32041, message: WALL_MESSAGES.browser });
  });

  it("answers a recent wall at once, and asks again when fresh", async () => {
    h.settings = { ...guestThenBrowser, streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    await expect(fetchStreamUrl("idW6")).rejects.toMatchObject({ code: -32040 });
    expect(h.ytdlp).toHaveBeenCalledTimes(3);
    await expect(fetchStreamUrl("idW6")).rejects.toMatchObject({ code: -32040 });
    expect(h.ytdlp).toHaveBeenCalledTimes(3);   // remembered
    ytdlpAnswers(() => ({ url: GOOD }));
    expect((await fetchStreamUrl("idW6", { fresh: true })).ok).toBe(true);
    expect(h.ytdlp).toHaveBeenCalledTimes(4);
  });

  it("asks again after the cookies change or the walls are forgotten", async () => {
    h.settings = { ...guestThenBrowser, streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    await expect(fetchStreamUrl("idW7")).rejects.toMatchObject({ code: -32040 });
    h.settings = { ...guestThenBrowser };   // Use browser account
    ytdlpAnswers((id) => id === "browser" ? { url: GOOD } : { err: WALL });
    expect((await fetchStreamUrl("idW7")).ok).toBe(true);

    h.settings = { ...guestThenBrowser, streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    await expect(fetchStreamUrl("idW8")).rejects.toMatchObject({ code: -32040 });
    forgetWalls();
    const before = h.ytdlp.mock.calls.length;
    await expect(fetchStreamUrl("idW8")).rejects.toMatchObject({ code: -32040 });
    expect(h.ytdlp.mock.calls.length).toBe(before + 3);
  });

  it("shares one resolve between a prefetch and the play that follows it", async () => {
    h.settings = { ...guestThenBrowser, streamCookieSource: "same" };
    ytdlpAnswers(() => ({ err: WALL }));
    const [a, b] = await Promise.all([fetchStreamUrl("idW9").catch((x) => x), fetchStreamUrl("idW9").catch((x) => x)]);
    expect(a.code).toBe(-32040);
    expect(b.code).toBe(-32040);
    expect(h.ytdlp).toHaveBeenCalledTimes(3);
  });

  it("gives the browser's own reason when it got past the wall to no format", async () => {
    ytdlpAnswers((id) => id === "guest" ? { err: WALL }
      : { err: "Requested format is not available. Use --list-formats for a list of available formats" });
    expect(await fetchStreamUrl("idW10")).toEqual({ ok: false,
      error: "Requested format is not available. Use --list-formats for a list of available formats" });
  });

  it("moves to the browser after a wall under the guest", async () => {
    ytdlpAnswers((id) => id === "guest" ? { err: WALL } : { url: GOOD });
    expect((await fetchStreamUrl("idA")).ok).toBe(true);
  });

  it("moves on after a walled URL", async () => {
    ytdlpAnswers((id, client) => id === "guest"
      ? (client === "default" ? { url: WALLED } : { err: "Video unavailable" })
      : { url: GOOD });
    expect((await fetchStreamUrl("idB")).ok).toBe(true);
  });

  it("never asks the browser when the guest resolves", async () => {
    ytdlpAnswers((id) => id === "guest" ? { url: GOOD } : { err: "should not be asked" });
    expect((await fetchStreamUrl("idK")).ok).toBe(true);
    expect(h.ytdlp).toHaveBeenCalledTimes(1);
  });

  it("reports the browser's wall when the browser's cookies cannot be read", async () => {
    ytdlpAnswers((id) => id === "guest"
      ? { err: WALL }
      : { err: "could not find firefox cookies database in /home/x/.mozilla/firefox" });
    await expect(fetchStreamUrl("idI")).rejects.toMatchObject({
      code: -32041, message: WALL_MESSAGES.browserUnread, data: { identity: "browser" } });
  });

  it("reports the browser's wall when the browser finds the video unavailable", async () => {
    ytdlpAnswers((id) => id === "guest" ? { err: WALL } : { err: "Video unavailable" });
    await expect(fetchStreamUrl("idC")).rejects.toMatchObject({ code: -32041, message: WALL_MESSAGES.browser });
  });

  it("stops at an unavailable video without asking the browser", async () => {
    ytdlpAnswers(() => ({ err: "Video unavailable" }));
    const r = await fetchStreamUrl("idD");
    expect(r).toEqual({ ok: false, error: "Video unavailable" });
    expect(h.ytdlp).toHaveBeenCalledTimes(3);   // one identity, three clients
  });

  it("writes no guest cookies back after a browser run, and does after a guest run", async () => {
    ytdlpAnswers((id) => id === "guest" ? { err: WALL } : { url: GOOD });
    expect((await fetchStreamUrl("idE")).ok).toBe(true);
    await new Promise((r) => setImmediate(r));
    expect(h.mergeGuestCookies).not.toHaveBeenCalled();

    ytdlpAnswers(() => ({ url: GOOD }));
    expect((await fetchStreamUrl("idF")).ok).toBe(true);
    await vi.waitFor(() => expect(h.mergeGuestCookies).toHaveBeenCalledTimes(1));
  });

  it("asks MWEB when YTMUSIC throws", async () => {
    h.poTokenSession.mockResolvedValue({ visitorData: "vd", mint: async () => "tok" });
    const asked: string[] = [];
    const audio = { itag: 251, has_audio: true, has_video: false,
                    decipher: async () => GOOD };
    setSessionBuilderForTest(async () => ({
      session: { player: {} },
      getBasicInfo: async (_id: string, o: { client: string }) => {
        asked.push(o.client);
        if (o.client === "YTMUSIC") throw new Error("YTMUSIC exploded");
        return { playability_status: { status: "OK" }, streaming_data: { adaptive_formats: [audio] },
                 basic_info: { title: "t", author: "a", duration: 1 } };
      },
    }) as never);
    const r = await fetchStreamUrl("idG");
    expect(r.ok).toBe(true);
    expect(asked).toEqual(["YTMUSIC", "MWEB"]);
    expect(h.ytdlp).not.toHaveBeenCalled();
  });

  it("asks MWEB after YTMUSIC reports UNPLAYABLE", async () => {
    h.poTokenSession.mockResolvedValue({ visitorData: "vd", mint: async () => "tok" });
    const asked: string[] = [];
    const audio = { itag: 251, has_audio: true, has_video: false, decipher: async () => GOOD };
    setSessionBuilderForTest(async () => ({
      session: { player: {} },
      getBasicInfo: async (_id: string, o: { client: string }) => {
        asked.push(o.client);
        return o.client === "MWEB"
          ? { playability_status: { status: "OK" }, streaming_data: { adaptive_formats: [audio] },
              basic_info: { title: "t", author: "a", duration: 1 } }
          : { playability_status: { status: "UNPLAYABLE", reason: "Video unavailable" } };
      },
    }) as never);
    expect((await fetchStreamUrl("idH")).ok).toBe(true);
    expect(asked).toEqual(["YTMUSIC", "MWEB"]);
  });
});

describe("videoFormatSelector", () => {
  it("asks for video-only first, then a muxed stream over https, then any muxed stream", () => {
    const f = videoFormatSelector(720, ["vp9", "h264"]).split("/");
    expect(f).toEqual([
      "bv[height<=720][vcodec~='^vp0?9']", "bv[height<=720][vcodec~='^avc1']",
      "b[height<=720][vcodec~='^vp0?9'][protocol^=http]", "b[height<=720][vcodec~='^avc1'][protocol^=http]",
      "b[height<=720][vcodec~='^vp0?9']", "b[height<=720][vcodec~='^avc1']",
    ]);
  });
});

// A format list per identity and client, and a selector evaluated against it the
// way yt-dlp does: the first alternative with a match wins.
type Fmt = { vcodec: string; acodec: string; height: number; protocol: string; url: string };
function pick(selector: string, formats: Fmt[]): Fmt | null {
  for (const alt of selector.split("/")) {
    const m = /^(bv|b)((?:\[[^\]]+\])*)$/.exec(alt);
    if (!m) continue;
    const conds = [...m[2].matchAll(/\[([^\]]+)\]/g)].map((x) => x[1]);
    const ok = formats.filter((f) => (m[1] === "bv" ? f.acodec === "none" : f.acodec !== "none") && f.vcodec !== "none"
      && conds.every((c) => {
        let k: RegExpExecArray | null;
        if ((k = /^height<=(\d+)$/.exec(c))) return f.height <= Number(k[1]);
        if ((k = /^vcodec~='(.+)'$/.exec(c))) return new RegExp(k[1]).test(f.vcodec);
        if ((k = /^protocol\^=(\w+)$/.exec(c))) return f.protocol.startsWith(k[1]);
        return false;
      }));
    if (ok.length) return ok.sort((a, b) => b.height - a.height)[0];
  }
  return null;
}
const DASH_720: Fmt = { vcodec: "vp09.00.31.08", acodec: "none", height: 720, protocol: "https",
                        url: "https://rr1.googlevideo.com/videoplayback?expire=9999999999&clen=10&dash" };
const HLS_720: Fmt = { vcodec: "avc1.4D401F", acodec: "mp4a.40.2", height: 720, protocol: "m3u8_native",
                       url: "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/9999999999/x" };

describe("fetchVideoStreamUrl identities", () => {
  const guestThenBrowser = { cookieSource: "guest", browser: "firefox", cookieProfile: "Default",
                             streamCookieSource: "browser" };
  function formatsBy(table: (identity: string, client: string) => Fmt[] | { err: string }) {
    h.ytdlp.mockImplementation(async (args: string[]) => {
      const identity = args.includes("--cookies-from-browser") ? "browser"
        : args.includes("--cookies") ? "guest" : "none";
      const ex = args.find((a) => a.startsWith("youtube:player_client="));
      const client = ex ? /player_client=([^;]+)/.exec(ex)![1] : "default";
      const t = table(identity, client);
      const fail = (m: string) => Object.assign(new Error("yt-dlp failed"), { stderr: `ERROR: [youtube] x: ${m}` });
      if ("err" in t) throw fail(t.err);
      const f = pick(args[args.indexOf("-f") + 1], t);
      if (!f) throw fail("Requested format is not available. Use --list-formats for a list of available formats");
      return { stdout: JSON.stringify({ url: f.url, height: f.height, width: f.height * 16 / 9, tbr: 2500 }) };
    });
  }
  beforeEach(() => {
    h.ytdlp.mockReset();
    h.poTokenSession.mockResolvedValue(null);
    h.settings = { ...guestThenBrowser };
    vi.stubGlobal("fetch", vi.fn(async () => ({ status: 206, body: { cancel: () => {} }, text: async () => "" })));
  });
  afterEach(() => { vi.unstubAllGlobals(); setBrowserSignedInForTest(null); });

  // The user's log: guest walled; under the browser the default client found no
  // video-only format, web_music met the wall, web_embedded said unavailable.
  const userCase = (muxed: Fmt[]) => (id: string, client: string) =>
    id === "guest" ? { err: WALL }
    : client === "default" ? muxed
    : client === "web_music" ? { err: WALL } : { err: "This video is unavailable" };

  it("plays the muxed stream the signed-in default client offers", async () => {
    formatsBy(userCase([HLS_720]));
    const r = await fetchVideoStreamUrl("vidU1", 720, ["vp9", "h264"]);
    expect(r).toMatchObject({ ok: true, videoId: "vidU1", url: HLS_720.url });
  });

  it("still prefers a video-only stream when there is one", async () => {
    formatsBy(userCase([HLS_720, DASH_720]));
    const r = await fetchVideoStreamUrl("vidU2", 720, ["vp9", "h264"]);
    expect(r).toMatchObject({ ok: true, url: DASH_720.url });
  });

  it("gives the browser's format reason, not the guest's wall, when nothing matches", async () => {
    formatsBy(userCase([]));
    const r = await fetchVideoStreamUrl("vidU3", 720, ["av1"]);
    expect(r).toEqual({ ok: false, error: expect.stringMatching(/^Requested format is not available/) });
  });

  it("names the browser when every client under it met the wall", async () => {
    setBrowserSignedInForTest(async () => true);
    formatsBy(() => ({ err: WALL }));
    await expect(fetchVideoStreamUrl("vidU4", 720, ["vp9"])).rejects.toMatchObject({
      code: -32041, message: WALL_MESSAGES.browser });
  });
});
