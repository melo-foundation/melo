import { describe, it, expect } from "vitest";
import { detectBrowsers, pickBrowser } from "./browsers";

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

  // Firefox 147+ creates new profiles under XDG_CONFIG_HOME; older ones stay in ~/.mozilla
  it("finds a new Firefox profile in the XDG config folder, as yt-dlp does", () => {
    expect(detectBrowsers({ platform: "linux", home: "/h", env: {},
      exists: on(["/h/.config/mozilla/firefox"]) })).toEqual(["firefox"]);
    expect(detectBrowsers({ platform: "linux", home: "/h", env: { XDG_CONFIG_HOME: "/x" },
      exists: on(["/x/mozilla/firefox"]) })).toEqual(["firefox"]);
    expect(detectBrowsers({ platform: "linux", home: "/h", env: {},
      exists: on(["/h/.var/app/org.mozilla.firefox/config/mozilla/firefox"]) })).toEqual(["firefox"]);
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

// "Use browser account" plays with a browser that is installed and signed in,
// not whatever the setting held.
describe("pickBrowser", () => {
  const login = (browser: string, signedIn: boolean | null) => ({ browser, signedIn });

  it("picks the one signed-in browser over the saved one", () => {
    expect(pickBrowser([login("firefox", false), login("chrome", true)], "firefox")).toEqual({ pick: "chrome" });
  });

  it("offers a choice when several are signed in", () => {
    expect(pickBrowser([login("firefox", true), login("chrome", true), login("brave", false)], "firefox"))
      .toEqual({ choose: ["firefox", "chrome"] });
  });

  it("keeps the saved browser when none is signed in and it is installed", () => {
    expect(pickBrowser([login("chrome", false), login("firefox", null)], "firefox")).toEqual({ pick: "firefox" });
  });

  it("falls back to the first installed when the saved one is not installed", () => {
    expect(pickBrowser([login("chrome", false), login("brave", null)], "firefox")).toEqual({ pick: "chrome" });
  });

  it("keeps the saved browser when none is installed", () => {
    expect(pickBrowser([], "firefox")).toEqual({ pick: "firefox" });
  });
});
