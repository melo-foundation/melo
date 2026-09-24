import { describe, expect, it } from "vitest";
import { parseYoutubeId } from "./library";

describe("parseYoutubeId", () => {
  it("takes a bare id", () => expect(parseYoutubeId("dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ"));
  it("takes the links people paste", () => {
    for (const s of [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM",
      "youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtu.be/dQw4w9WgXcQ?si=abc",
      "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://www.youtube.com/shorts/dQw4w9WgXcQ",
    ]) expect(parseYoutubeId(s), s).toBe("dQw4w9WgXcQ");
  });
  it("refuses what is not a video", () => {
    for (const s of ["", "hello", "https://example.com/watch?v=dQw4w9WgXcQ",
                     "https://www.youtube.com/playlist?list=PL123", "dQw4w9WgXc"])
      expect(parseYoutubeId(s), s).toBeNull();
  });
});
