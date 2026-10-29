import { describe, it, expect } from "vitest";
import { mkdtempSync, mkdirSync, utimesSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { DatabaseSync } from "node:sqlite";
import { readFirefoxYoutubeCookies, newestFirefoxCookieDb } from "./firefox-cookies";

const now = Math.floor(Date.now() / 1000);

// moz_cookies as Firefox 142+ writes it (schema 16: expiry in milliseconds)
function makeDb(path: string, rows: [string, string, string, string, number][], version = 16): void {
  const db = new DatabaseSync(path);
  db.exec(`CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '',
    name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER); PRAGMA user_version = ${version};`);
  const ins = db.prepare("INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, isSecure) VALUES (?, ?, ?, ?, '/', ?, 1)");
  for (const [oa, name, value, host, expiry] of rows) ins.run(oa, name, value, host, version >= 16 ? expiry * 1000 : expiry);
  db.close();
}

describe("reading Firefox's YouTube cookies", () => {
  it("keeps youtube.com's own identity, not a container's or an embed's copy", () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-ff-"));
    const db = join(dir, "cookies.sqlite");
    makeDb(db, [
      ["", "VISITOR_INFO1_LIVE", "mine", ".youtube.com", now + 86400],
      ["^userContextId=2", "VISITOR_INFO1_LIVE", "container", ".youtube.com", now + 86400],
      ["^partitionKey=%28https%2Cexample.org%29", "VISITOR_INFO1_LIVE", "embed", ".youtube.com", now + 86400],
      ["", "ST-abc", "x".repeat(3000), ".youtube.com", now - 60],
      ["", "NID", "google", ".google.com", now + 86400],
      ["", "YSC", "music", "music.youtube.com", now + 86400],
    ]);
    const got = readFirefoxYoutubeCookies(db, now);
    expect(got.map((c) => `${c.name}=${c.value}`).sort()).toEqual(["VISITOR_INFO1_LIVE=mine", "YSC=music"]);
    expect(got[0].expiry).toBeLessThan(now * 10);   // seconds, not milliseconds
  });
  it("reads a schema older than 16, whose expiry is in seconds", () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-ff-"));
    const db = join(dir, "cookies.sqlite");
    makeDb(db, [["", "PREF", "f6=1", ".youtube.com", now + 86400]], 15);
    expect(readFirefoxYoutubeCookies(db, now).map((c) => c.name)).toEqual(["PREF"]);
  });
  it("picks the most recently written profile, as yt-dlp does", () => {
    const root = mkdtempSync(join(tmpdir(), "melo-ff-"));
    for (const [p, age] of [["old.default", 9000], ["new.default-release", 10]] as const) {
      mkdirSync(join(root, p));
      makeDb(join(root, p, "cookies.sqlite"), []);
      utimesSync(join(root, p, "cookies.sqlite"), now - age, now - age);
    }
    expect(newestFirefoxCookieDb([join(root, "missing"), root])).toBe(join(root, "new.default-release", "cookies.sqlite"));
    expect(newestFirefoxCookieDb([join(root, "missing")])).toBeUndefined();
  });
});
