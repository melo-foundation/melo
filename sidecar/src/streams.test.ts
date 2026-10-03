import { describe, it, expect } from "vitest";
import { needsStreamRelay, ytdlpReason } from "./streams";

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
