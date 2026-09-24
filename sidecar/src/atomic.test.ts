import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, statSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { writeFileAtomic, backupOnce, backupPath } from "./atomic";

// The failure this exists to prevent: a truncated file read as an empty
// library, then made permanent by the next save.
describe("atomic writes", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "melo-atomic-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("leaves no partial file, and no temp file behind", () => {
    const p = join(dir, "library.v2.json");
    writeFileAtomic(p, '{"tracks":[1,2,3]}');
    expect(JSON.parse(readFileSync(p, "utf-8")).tracks).toEqual([1, 2, 3]);
    expect(require("fs").readdirSync(dir).filter((f: string) => f.includes(".tmp"))).toEqual([]);
  });

  it("the old content survives a failed write", () => {
    const p = join(dir, "library.v2.json");
    writeFileAtomic(p, '{"tracks":["keep"]}');
    // a directory where the temp file wants to be: rename cannot succeed
    expect(() => writeFileAtomic(join(dir, "nope", "x", "y.json"), "{}")).not.toThrow();
    expect(JSON.parse(readFileSync(p, "utf-8")).tracks).toEqual(["keep"]);
  });

  it("writes 0600 by default", () => {
    const p = join(dir, "settings.v2.json");
    writeFileAtomic(p, "{}");
    expect(statSync(p).mode & 0o777).toBe(0o600);
  });

  it("keeps one generation back", () => {
    const p = join(dir, "library.v2.json");
    writeFileSync(p, '{"tracks":["original"]}');
    expect(backupPath(p)).toBeNull();
    backupOnce(p);
    expect(backupPath(p)).toBe(p + ".bak");
    writeFileAtomic(p, '{"tracks":["new"]}');
    expect(JSON.parse(readFileSync(p + ".bak", "utf-8")).tracks).toEqual(["original"]);
  });

  it("backupOnce on a file that does not exist is a no-op", () => {
    const p = join(dir, "absent.json");
    backupOnce(p);
    expect(existsSync(p + ".bak")).toBe(false);
  });
});
