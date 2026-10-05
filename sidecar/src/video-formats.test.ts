import { describe, it, expect } from "vitest";
import { codecOf, isStillAtHeight, isStillFormat, parseCodecs, pickVideoFormat, videoCacheKey } from "./video-formats";

// YouTube's formats for dQw4w9WgXcQ (YTMUSIC client), trimmed.
const rick = [
  { itag: 18,  has_video: true, has_audio: true,  width: 640,  height: 360,  fps: 25, bitrate: 444000,  mime_type: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"' },
  { itag: 313, has_video: true, has_audio: false, width: 3840, height: 2160, fps: 25, bitrate: 18077000, mime_type: 'video/webm; codecs="vp9"' },
  { itag: 137, has_video: true, has_audio: false, width: 1920, height: 1080, fps: 25, bitrate: 4334000, mime_type: 'video/mp4; codecs="avc1.640028"' },
  { itag: 248, has_video: true, has_audio: false, width: 1920, height: 1080, fps: 25, bitrate: 1549000, mime_type: 'video/webm; codecs="vp9"' },
  { itag: 399, has_video: true, has_audio: false, width: 1920, height: 1080, fps: 25, bitrate: 1595000, mime_type: 'video/mp4; codecs="av01.0.08M.08"' },
  { itag: 136, has_video: true, has_audio: false, width: 1280, height: 720,  fps: 25, bitrate: 1058000, mime_type: 'video/mp4; codecs="avc1.4D401F"' },
  { itag: 247, has_video: true, has_audio: false, width: 1280, height: 720,  fps: 25, bitrate: 868000,  mime_type: 'video/webm; codecs="vp9"' },
  { itag: 243, has_video: true, has_audio: false, width: 640,  height: 360,  fps: 25, bitrate: 288000,  mime_type: 'video/webm; codecs="vp9"' },
  { itag: 251, has_video: false, has_audio: true, bitrate: 130000, mime_type: 'audio/webm; codecs="opus"' },
];

describe("codecOf", () => {
  it("names the three codecs melo decodes", () => {
    expect(codecOf('video/mp4; codecs="av01.0.08M.08"')).toBe("av1");
    expect(codecOf('video/webm; codecs="vp9"')).toBe("vp9");
    expect(codecOf('video/webm; codecs="vp09.00.40.08"')).toBe("vp9");
    expect(codecOf('video/mp4; codecs="avc1.640028"')).toBe("h264");
  });
  it("is null for anything else", () => {
    expect(codecOf('video/mp4; codecs="hev1.1.6.L93.B0"')).toBeNull();
    expect(codecOf("")).toBeNull();
  });
});

describe("pickVideoFormat", () => {
  it("takes the first codec in the preference that has a candidate", () => {
    expect(pickVideoFormat(rick, 1080, ["av1", "vp9", "h264"])?.itag).toBe(399);
    expect(pickVideoFormat(rick, 1080, ["vp9", "h264"])?.itag).toBe(248);
    expect(pickVideoFormat(rick, 1080, ["h264"])?.itag).toBe(137);
  });
  it("stays at or under the cap and prefers the greatest height", () => {
    expect(pickVideoFormat(rick, 720, ["vp9"])?.itag).toBe(247);
    expect(pickVideoFormat(rick, 480, ["vp9"])?.itag).toBe(243);
    expect(pickVideoFormat(rick, 2160, ["vp9"])?.itag).toBe(313);
  });
  it("never picks a muxed or audio format", () => {
    expect(pickVideoFormat(rick, 360, ["h264"])).toBeNull();   // 18 is muxed, no h264 360p video-only here
  });
  it("is null when nothing fits the cap or the codecs", () => {
    expect(pickVideoFormat(rick, 240, ["vp9", "av1", "h264"])).toBeNull();
    expect(pickVideoFormat(rick, 1080, [])).toBeNull();
  });
  it("breaks a height tie by bitrate", () => {
    const two = [
      { itag: 1, has_video: true, has_audio: false, width: 1280, height: 720, bitrate: 700000, mime_type: 'video/webm; codecs="vp9"' },
      { itag: 2, has_video: true, has_audio: false, width: 1280, height: 720, bitrate: 900000, mime_type: 'video/webm; codecs="vp9"' },
    ];
    expect(pickVideoFormat(two, 720, ["vp9"])?.itag).toBe(2);
  });
});

describe("isStillFormat", () => {
  it("calls the still picture a still and the real video a video", () => {
    // a still (zh7ihYKaqYs) and a real video (dQw4w9WgXcQ), 1080p VP9
    expect(isStillFormat({ width: 1920, height: 1080, bitrate: 143000 })).toBe(true);
    expect(isStillFormat({ width: 1920, height: 1080, bitrate: 1549000 })).toBe(false);
    expect(isStillFormat({ width: 1280, height: 720, bitrate: 89000 })).toBe(true);
    expect(isStillFormat({ width: 1280, height: 720, bitrate: 868000 })).toBe(false);
  });
  it("is false when the numbers are missing", () => {
    expect(isStillFormat({})).toBe(false);
    expect(isStillFormat({ width: 1280, height: 720 })).toBe(false);
  });
});

describe("isStillAtHeight", () => {
  const f = (itag: number, bitrate: number, codec: string) => ({
    itag, has_video: true, has_audio: false, width: 1280, height: 720, fps: 25, bitrate,
    mime_type: `video/webm; codecs="${codec}"`,
  });
  it("is a still only if every codec at the height is under the threshold", () => {
    expect(isStillAtHeight([f(398, 150000, "av01.0.05M.08"), f(247, 900000, "vp9")], 720)).toBe(false);
    expect(isStillAtHeight([f(398, 150000, "av01.0.05M.08"), f(247, 170000, "vp9")], 720)).toBe(true);
  });
  it("ignores other heights and muxed formats", () => {
    const muxed = { ...f(22, 2000000, "avc1.64001F, mp4a.40.2"), has_audio: true };
    const tall = { ...f(248, 1549000, "vp9"), width: 1920, height: 1080 };
    expect(isStillAtHeight([f(398, 150000, "av01.0.05M.08"), muxed, tall], 720)).toBe(true);
  });
  it("is false with nothing at the height", () => {
    expect(isStillAtHeight([], 720)).toBe(false);
  });
});

describe("parseCodecs", () => {
  it("keeps known codecs in the given order and drops the rest", () => {
    expect(parseCodecs(["vp9", "hevc", "av1"])).toEqual(["vp9", "av1"]);
  });
  it("falls back to the full list for anything that is not a list", () => {
    expect(parseCodecs(undefined)).toEqual(["av1", "vp9", "h264"]);
    expect(parseCodecs([])).toEqual(["av1", "vp9", "h264"]);
    expect(parseCodecs("vp9")).toEqual(["av1", "vp9", "h264"]);
  });
});

describe("videoCacheKey", () => {
  it("is per video and per cap", () => {
    expect(videoCacheKey("abc", 720)).not.toBe(videoCacheKey("abc", 1080));
    expect(videoCacheKey("abc", 720)).toBe(videoCacheKey("abc", 720));
  });
});
