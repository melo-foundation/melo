import { describe, expect, it } from "vitest";
import { existsSync, readFileSync } from "fs";
import { CK, DRIFT_DATA_DIR, STABLE_VIDEO } from "./setup";
import {
  fetchMusicHome,
  fetchNext,
  fetchSearch,
  fetchSearchContinuation,
} from "../src/innertube";
import { join } from "path";

describe("innertube drift", () => {
  it("search parses results and continuation chains", async () => {
    const s = await fetchSearch("hatsune miku", ...CK);
    expect(s.results.length).toBeGreaterThanOrEqual(10);
    for (const r of s.results.slice(0, 10)) {
      expect(r.id).toBeTruthy();
      expect(r.title).toBeTruthy();
    }
    expect(s.continuation).toBeTruthy();

    const more = await fetchSearchContinuation(s.continuation!, ...CK);
    expect(more.results.length).toBeGreaterThanOrEqual(5);
    expect(more.results[0].id).toBeTruthy();
  });

  it("guest jar captures visitor cookies", async () => {
    // the search above ran on the guest profile; capture must have landed
    const jar = join(DRIFT_DATA_DIR, "guest-cookies", "drift.json");
    expect(existsSync(jar)).toBe(true);
    expect(readFileSync(jar, "utf8")).toContain("VISITOR_INFO1_LIVE");
  });

  it("music home parses sections", async () => {
    const home = await fetchMusicHome(...CK);
    expect(home.sections.length).toBeGreaterThanOrEqual(1);
    // A shelf's entries are `items` (HomeSection).
    const withContent = home.sections.filter((s) => (s.items?.length ?? 0) > 0);
    expect(withContent.length).toBeGreaterThanOrEqual(1);
    const first = withContent[0].items[0];
    expect(first.playlistId || first.videoId).toBeTruthy();
  });

  it("up-next parses autoplay + suggestions", async () => {
    const nx = await fetchNext(STABLE_VIDEO, ...CK);
    expect(nx.autoplay?.id).toBeTruthy();
    expect(nx.suggestions.length).toBeGreaterThanOrEqual(5);
    expect(nx.suggestions[0].title).toBeTruthy();
  });
});
