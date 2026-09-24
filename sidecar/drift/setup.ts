import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { setEnv } from "../src/env";
import type { CookieSource } from "../src/settings";

// Fresh anonymous guest session per run: a temp dataDir means an empty
// cookie jar — CI has no personalization, and these tests only assert
// STRUCTURE (fields parse, tokens chain), never content.
export const DRIFT_DATA_DIR = mkdtempSync(join(tmpdir(), "melo-drift-"));

setEnv({
  dataDir: DRIFT_DATA_DIR,
  musicDir: DRIFT_DATA_DIR,
  ytdlpPath: join(DRIFT_DATA_DIR, "bin", process.platform === "win32" ? "yt-dlp.exe" : "yt-dlp"),
  osPrefersDark: true,
  appVersion: "drift",
});

export const CK: [CookieSource, string, string] = ["guest", "", "drift"];

// Ubiquitous video by a YouTube-owned artist, unlikely to be taken down
export const STABLE_VIDEO = "dQw4w9WgXcQ";

// GitHub runner IPs get bot-checked by YouTube's STREAM endpoints sometimes.
// Those tests pass-with-warning on a bot wall (it's not parser drift); the
// browse/search endpoints don't hit it in practice.
export function isBotWall(message: string): boolean {
  return /sign in to confirm|not a bot|captcha|consent/i.test(message);
}
