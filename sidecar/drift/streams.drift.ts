import { beforeAll, describe, expect, it } from "vitest";
import { isBotWall, STABLE_VIDEO } from "./setup";
import { ensureYtdlp, downloadYtdlp } from "../src/ytdlp";
import { fetchStreamUrl, fetchPlaylistTracks } from "../src/streams";

describe("streams drift (yt-dlp)", () => {
  beforeAll(async () => {
    if (!ensureYtdlp()) {
      const ok = await downloadYtdlp();
      if (!ok) throw new Error("could not download yt-dlp");
    }
  });

  // Seeded mixes are read from the mix panel: watch_next_feed is the related-
  // videos rail (shelves, Shorts carousels), so a mix read from it fills with
  // non-tracks. Live, because the failure is YouTube changing the route.
  it("opens a seeded mix from the mix panel, not the recommendations rail", async () => {
    const r: any = await fetchPlaylistTracks("RD" + STABLE_VIDEO);
    if (!r.ok && isBotWall(r.error || "")) {
      console.warn("[drift] mix open hit a bot wall — not parser drift:", r.error);
      return;
    }
    expect(r.ok).toBe(true);
    expect(r.tracks.length).toBeGreaterThan(5);

    // The panel starts with the seed itself; the sidebar never does. That is
    // the cheapest signal telling the two routes apart without asserting
    // anything about which songs YouTube picks today.
    expect(r.tracks[0]?.id).toBe(STABLE_VIDEO);

    // Every row is a playable video with a duration. The sidebar's shelves and
    // Shorts rails have neither, so this fails if the route regresses.
    const untitled = r.tracks.filter((t: any) => !t.title || !String(t.id).match(/^[\w-]{11}$/));
    expect(untitled, `rows that are not videos: ${JSON.stringify(untitled.slice(0, 3))}`)
      .toHaveLength(0);
  });

  it("resolves a stream URL", async () => {
    const r: any = await fetchStreamUrl(STABLE_VIDEO);
    if (!r.ok && isBotWall(r.error || "")) {
      console.warn("[drift] stream resolve hit a bot wall — not parser drift:", r.error);
      return;
    }
    expect(r.ok).toBe(true);
    expect(String(r.url)).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/s\//);
    expect(r.title).toBeTruthy();
  });
});
