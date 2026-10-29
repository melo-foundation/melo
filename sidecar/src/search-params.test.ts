import { describe, it, expect } from "vitest";
import { encodeSearchParams } from "./innertube.js";

const bytes = (p?: string) => (p ? [...Buffer.from(p, "base64")] : undefined);

describe("encodeSearchParams", () => {
  it("sorts by view count with 3, the only sort YouTube still honours", () => {
    expect(bytes(encodeSearchParams({ sort: "views" }))).toEqual([8, 3]);
  });
  it("sends nothing for the sorts YouTube treats as relevance", () => {
    expect(encodeSearchParams({ sort: "date" })).toBeUndefined();
    expect(encodeSearchParams({ sort: "rating" })).toBeUndefined();
  });
  it("sends no type for Channel or Movie, whose results melo cannot show", () => {
    expect(encodeSearchParams({ type: "channel" })).toBeUndefined();
    expect(encodeSearchParams({ type: "movie" })).toBeUndefined();
  });
  it("sends YouTube's own panel values for date, type and duration", () => {
    expect(bytes(encodeSearchParams({ type: "video", uploadDate: "week", duration: "long" })))
      .toEqual([18, 6, 8, 3, 16, 1, 24, 2]);
    expect(bytes(encodeSearchParams({ type: "playlist" }))).toEqual([18, 2, 16, 3]);
  });
  it("sends under 3 minutes as 4 and 3 to 20 minutes as 5", () => {
    expect(bytes(encodeSearchParams({ duration: "short" }))).toEqual([18, 2, 24, 4]);
    expect(bytes(encodeSearchParams({ duration: "medium" }))).toEqual([18, 2, 24, 5]);
  });
  it("sends nothing for Last hour, which YouTube's panel no longer offers", () => {
    expect(encodeSearchParams({ uploadDate: "hour" })).toBeUndefined();
  });
});
