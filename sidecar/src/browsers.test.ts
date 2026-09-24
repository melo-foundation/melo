import { describe, it, expect } from "vitest";
import { detectBrowsers } from "./browsers";

// Which browsers to offer as accounts: the ones whose cookie store is where
// yt-dlp looks for it without being handed a path. A browser listed but not
// readable would be a menu entry that fails when picked.
describe("detectBrowsers", () => {
  const on = (paths: string[]) => (p: string) => paths.includes(p);

  it("finds Chromium and Firefox on Linux from their default locations", () => {
    const got = detectBrowsers({ platform: "linux", home: "/h", env: {},
      exists: on(["/h/.config/chromium", "/h/.mozilla/firefox"]) });
    expect(got).toEqual(["firefox", "chromium"]);
  });

  it("finds a Snap or Flatpak Firefox, which yt-dlp searches too", () => {
    expect(detectBrowsers({ platform: "linux", home: "/h", env: {},
      exists: on(["/h/snap/firefox/common/.mozilla/firefox"]) })).toEqual(["firefox"]);
    expect(detectBrowsers({ platform: "linux", home: "/h", env: {},
      exists: on(["/h/.var/app/org.mozilla.firefox/.mozilla/firefox"]) })).toEqual(["firefox"]);
  });

  it("finds Windows browsers under LOCALAPPDATA and APPDATA", () => {
    const env = { LOCALAPPDATA: "C:\\L", APPDATA: "C:\\R" };
    const got = detectBrowsers({ platform: "win32", home: "C:\\U", env,
      exists: on(["C:\\L/Google/Chrome/User Data", "C:\\L/Microsoft/Edge/User Data", "C:\\R/Mozilla/Firefox/Profiles"]) });
    expect(got).toEqual(["firefox", "chrome", "edge"]);
  });

  it("finds macOS browsers under Application Support", () => {
    const got = detectBrowsers({ platform: "darwin", home: "/Users/a", env: {},
      exists: on(["/Users/a/Library/Application Support/BraveSoftware/Brave-Browser"]) });
    expect(got).toEqual(["brave"]);
  });

  it("finds nothing when nothing is installed", () => {
    expect(detectBrowsers({ platform: "linux", home: "/h", env: {}, exists: () => false })).toEqual([]);
  });
});
