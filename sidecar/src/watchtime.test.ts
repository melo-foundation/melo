import { describe, it, expect, vi, afterEach } from "vitest";
import { reportPlayback, reportDelayplay, reportWatchtime, isVideoId } from "./watchtime";

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
