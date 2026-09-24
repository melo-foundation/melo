import { describe, it, expect } from "vitest";
import { needsStreamRelay } from "./streams";

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
