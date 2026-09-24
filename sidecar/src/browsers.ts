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
    firefox: [`${o.home}/.mozilla/firefox`,
              `${o.home}/snap/firefox/common/.mozilla/firefox`,
              `${o.home}/.var/app/org.mozilla.firefox/.mozilla/firefox`],
    chrome: [`${config}/google-chrome`],
    chromium: [`${config}/chromium`],
    brave: [`${config}/BraveSoftware/Brave-Browser`],
    edge: [`${config}/microsoft-edge`],
  };
}

export function detectBrowsers(o: BrowserProbe): string[] {
  const dirs = storeDirs(o);
  return ORDER.filter((b) => dirs[b].some((d) => o.exists(d)));
}

export function installedBrowsers(): string[] {
  return detectBrowsers({ platform: process.platform, home: homedir(), env: process.env, exists: existsSync });
}
