import { describe, it, expect } from "vitest";
import { parseLrc, parseJson3 } from "./lyrics";

describe("parseLrc", () => {
  it("reads stamps and keeps them in order", () => {
    const l = parseLrc("[00:12.50]first\n[01:03.00]second\n");
    expect(l).toEqual([{ t: 12.5, text: "first" }, { t: 63, text: "second" }]);
  });

  it("expands a line carrying several stamps", () => {
    // a repeated hook is stored once with every time it occurs
    expect(parseLrc("[00:10.00][00:40.00]hook")).toEqual([
      { t: 10, text: "hook" }, { t: 40, text: "hook" },
    ]);
  });

  it("ignores metadata headers and blank text", () => {
    expect(parseLrc("[ar:Someone]\n[00:05.00]\n")).toEqual([{ t: 5, text: "" }]);
    expect(parseLrc("no stamps here")).toEqual([]);
  });
});

describe("parseJson3", () => {
  it("joins the segments of each cue", () => {
    expect(parseJson3({ events: [
      { tStartMs: 1500, segs: [{ utf8: "hello " }, { utf8: "there" }] },
      { tStartMs: 4000, segs: [{ utf8: "\n" }] },
      { tStartMs: 6000, segs: [{ utf8: "next" }] },
    ]})).toEqual([{ t: 1.5, text: "hello there" }, { t: 6, text: "next" }]);
  });

  it("survives a payload with no events", () => {
    expect(parseJson3({})).toEqual([]);
    expect(parseJson3(null)).toEqual([]);
  });
});
