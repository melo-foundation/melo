import { existsSync } from "fs";
import { homedir } from "os";

// Browsers offered as accounts: those whose cookie store sits where yt-dlp
// looks without a path. Others (a Flatpak Chromium under ~/.var/app) would fail
// when picked. yt-dlp also searches Snap and Flatpak paths for Firefox.
//
// Display order, not detection order.
const ORDER = ["firefox", "chrome", "chromium", "brave", "edge"] as const;

export interface BrowserProbe {
  platform: string;
  home: string;
  env: Record<string, string | undefined>;
  exists: (path: string) => boolean;
}

function storeDirs(o: BrowserProbe): Record<string, string[]> {
  if (o.platform === "win32") {
    const local = o.env.LOCALAPPDATA ?? "", roaming = o.env.APPDATA ?? "";
    return {
      firefox: [`${roaming}/Mozilla/Firefox/Profiles`],
      chrome: [`${local}/Google/Chrome/User Data`],
      chromium: [`${local}/Chromium/User Data`],
      brave: [`${local}/BraveSoftware/Brave-Browser/User Data`],
      edge: [`${local}/Microsoft/Edge/User Data`],
    };
  }
  if (o.platform === "darwin") {
    const as = `${o.home}/Library/Application Support`;
    return {
      firefox: [`${as}/Firefox/Profiles`],
      chrome: [`${as}/Google/Chrome`],
      chromium: [`${as}/Chromium`],
      brave: [`${as}/BraveSoftware/Brave-Browser`],
      edge: [`${as}/Microsoft Edge`],
    };
  }
  const config = o.env.XDG_CONFIG_HOME || `${o.home}/.config`;
  return {
    // yt-dlp's list: Firefox 147+ makes new profiles under XDG_CONFIG_HOME
    firefox: [`${config}/mozilla/firefox`,
              `${o.home}/.mozilla/firefox`,
              `${o.home}/.var/app/org.mozilla.firefox/config/mozilla/firefox`,
              `${o.home}/.var/app/org.mozilla.firefox/.mozilla/firefox`,
              `${o.home}/snap/firefox/common/.mozilla/firefox`],
    chrome: [`${config}/google-chrome`],
    chromium: [`${config}/chromium`],
    brave: [`${config}/BraveSoftware/Brave-Browser`],
    edge: [`${config}/microsoft-edge`],
  };
}

/** The folders Firefox's profiles live in, newest layout first. */
export function firefoxRoots(o: BrowserProbe = { platform: process.platform, home: homedir(), env: process.env, exists: existsSync }): string[] {
  return storeDirs(o).firefox;
}

export function detectBrowsers(o: BrowserProbe): string[] {
  const dirs = storeDirs(o);
  return ORDER.filter((b) => dirs[b].some((d) => o.exists(d)));
}

export function installedBrowsers(): string[] {
  return detectBrowsers({ platform: process.platform, home: homedir(), env: process.env, exists: existsSync });
}

export interface BrowserLogin { browser: string; signedIn: boolean | null }
export interface BrowserPick { pick?: string; choose?: string[] }

// The browser "Use browser account" plays with: the one signed in to YouTube,
// a choice when several are, else the saved one if installed, else the first
// installed. Nothing installed keeps the saved one.
export function pickBrowser(logins: BrowserLogin[], saved: string): BrowserPick {
  const signed = logins.filter((l) => l.signedIn === true).map((l) => l.browser);
  if (signed.length === 1) return { pick: signed[0] };
  if (signed.length > 1) return { choose: signed };
  if (logins.some((l) => l.browser === saved) || !logins.length) return { pick: saved };
  return { pick: logins[0].browser };
}
