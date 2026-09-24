import { describe, it, expect } from "vitest";
import { isSafeIdForPath, assertSafeIdForPath } from "./trackid";

describe("track ids used as filenames", () => {
  it("accepts the shapes melo actually produces", () => {
    for (const id of ["dQw4w9WgXcQ", "local-3f2b9c10-1a2b-4c3d-8e9f-000000000000",
                      "soundcloud-123456789", "a", "A1_-.b"])
      expect(isSafeIdForPath(id)).toBe(true);
  });

  it("refuses traversal, absolutes and separators", () => {
    for (const id of ["../settings.v2", "..", ".", "a/../../b", "/etc/passwd",
                      "a/b", "a\\b", "", "  ", ".hidden", "a\0b"])
      expect(isSafeIdForPath(id)).toBe(false);
  });

  it("refuses Windows device names", () => {
    for (const id of ["con", "NUL", "com1", "LPT9.json"])
      expect(isSafeIdForPath(id)).toBe(false);
  });

  it("refuses non-strings", () => {
    for (const id of [null, undefined, 42, {}, ["a"]])
      expect(isSafeIdForPath(id as unknown)).toBe(false);
  });

  it("the assert form throws with the offending value named", () => {
    expect(() => assertSafeIdForPath("../settings.v2", "lyrics cache"))
      .toThrow(/refusing to use .*settings\.v2.* as a lyrics cache filename/);
    expect(assertSafeIdForPath("dQw4w9WgXcQ", "thumbnail")).toBe("dQw4w9WgXcQ");
  });
});
