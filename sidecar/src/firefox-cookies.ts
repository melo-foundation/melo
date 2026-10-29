import { copyFileSync, existsSync, readdirSync, statSync } from "fs";
import { createRequire } from "module";
import { join } from "path";
import { makeTempDir, removeTempDir } from "./ytdlp-proc";

export interface FirefoxCookie {
  domain: string; path: string; secure: boolean; expiry: number; name: string; value: string;
}

// node:sqlite is in Node 22.13 and later; a source build on an older system
// Node reads Firefox through yt-dlp instead.
function sqlite(): typeof import("node:sqlite") | null {
  try { return createRequire(import.meta.url)("node:sqlite"); } catch { return null; }
}

export function canReadFirefox(): boolean { return sqlite() !== null; }

/** The cookies.sqlite written last under these folders (profiles one level down), as yt-dlp picks. */
export function newestFirefoxCookieDb(roots: string[]): string | undefined {
  let best: string | undefined, bestTime = -1;
  for (const root of roots) {
    let names: string[];
    try { names = readdirSync(root); } catch { continue; }
    for (const name of names) {
      const db = join(root, name, "cookies.sqlite");
      try { const t = statSync(db).mtimeMs; if (t > bestTime) { best = db; bestTime = t; } } catch { /* no store */ }
    }
  }
  return best;
}

// youtube.com's own cookies only: Firefox keeps a copy per container and per
// site that embeds YouTube, each with its own visitor id, and yt-dlp keeps
// whichever it reads last. Expired ones stay until Firefox cleans up.
export function readFirefoxYoutubeCookies(dbPath: string, now = Math.floor(Date.now() / 1000)): FirefoxCookie[] {
  const sq = sqlite();
  if (!sq) throw new Error("node:sqlite unavailable");
  // a copy, with its write-ahead log: Firefox holds the live file open
  const dir = makeTempDir("melo-firefox-");
  try {
    const copy = join(dir, "cookies.sqlite");
    copyFileSync(dbPath, copy);
    if (existsSync(dbPath + "-wal")) copyFileSync(dbPath + "-wal", copy + "-wal");
    const db = new sq.DatabaseSync(copy);
    try {
      const version = Number((db.prepare("PRAGMA user_version").get() as any)?.user_version ?? 0);
      const rows = db.prepare("SELECT host, name, value, path, expiry, isSecure FROM moz_cookies WHERE originAttributes = ''").all() as any[];
      return rows
        .map((r) => ({ domain: String(r.host), path: String(r.path || "/"), secure: !!r.isSecure, name: String(r.name), value: String(r.value),
                       // schema 16 (Firefox 142) stores milliseconds; 0 is a session cookie, kept a year as elsewhere
                       expiry: Number(r.expiry) ? Math.floor(Number(r.expiry) / (version >= 16 ? 1000 : 1)) : now + 86400 * 365 }))
        .filter((c) => {
          const d = c.domain.replace(/^\./, "").toLowerCase();
          return (d === "youtube.com" || d.endsWith(".youtube.com")) && c.expiry > now;
        });
    } finally { db.close(); }
  } finally { removeTempDir(dir); }
}
