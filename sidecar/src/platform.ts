import { ytdlpPath } from "./env";

/**
 * Path to the yt-dlp binary — injected via `initialize` (user-writable,
 * self-updating dir). Lazy: env is not available at module load time.
 */
export function YTDLP(): string {
  return ytdlpPath();
}

/** Platform-appropriate User-Agent string */
export const USER_AGENT = process.platform === "win32"
  ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:137.0) Gecko/20100101 Firefox/137.0"
  : process.platform === "darwin"
    ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:137.0) Gecko/20100101 Firefox/137.0"
    : "Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0";
