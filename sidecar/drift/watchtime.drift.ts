import { describe, expect, it } from "vitest";
import { CK } from "./setup";
import { reportPlayback, trackingUrls } from "../src/watchtime";

// Ordinary music videos: a guest watch page walls them ("not a bot") while a
// very popular video like STABLE_VIDEO comes back whole.
const MUSIC_VIDEOS = ["ctFmqTzIAAM", "IIHohhNNs-4", "b_2SKc25JU0", "eK9LKRaknB4", "dB8QCac8FSM"];

describe("watch-time drift (guest)", () => {
  for (const v of MUSIC_VIDEOS) {
    it(`a guest play of ${v} gets every tracking URL`, async () => {
      const cpn = await reportPlayback(v, 200, ...CK);
      const urls = trackingUrls(cpn);
      const missing = Object.entries(urls).filter(([, u]) => !u).map(([k]) => k);
      expect(missing, `no ${missing.join(", ")} tracking URL for ${v}`).toEqual([]);
    });
  }
});
