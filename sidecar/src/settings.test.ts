import { describe, it, expect } from "vitest";
import { touchesCookieIdentity, defaultSettings, autoTagEnabled, tagServicesOf } from "./settings";
import { setEnv } from "./env";

// Switching identity has to drop the sidecar's cookie caches, or the new
// identity's requests go out carrying the old one's visitorData.
describe("touchesCookieIdentity", () => {
  it("is true for each key that selects an identity", () => {
    expect(touchesCookieIdentity({ cookieSource: "browser" })).toBe(true);
    expect(touchesCookieIdentity({ cookieProfile: "Jazz" })).toBe(true);
    expect(touchesCookieIdentity({ browser: "chromium" })).toBe(true);
  });

  it("is true when an identity key rides along with unrelated ones", () => {
    expect(touchesCookieIdentity({ homeSource: "youtube", cookieProfile: "rap" })).toBe(true);
  });

  it("is false for patches that leave the identity alone", () => {
    expect(touchesCookieIdentity({ homeSource: "youtube" })).toBe(false);
    expect(touchesCookieIdentity({ crossfadeSeconds: 3 })).toBe(false);
    expect(touchesCookieIdentity({ ui: { barMain: "strip" } })).toBe(false);
    expect(touchesCookieIdentity({})).toBe(false);
  });

  it("is false when the key is present but carries no value", () => {
    expect(touchesCookieIdentity({ browser: undefined })).toBe(false);
  });
});

// New installs open on YouTube. Existing ones keep whatever they saved: an
// existing settings file carries homeSource explicitly and is merged over
// these defaults.
describe("defaultSettings", () => {
  // the defaults name the download folder, so the environment initialize
  // would have set up has to exist first
  setEnv({ dataDir: "/tmp/melo-test", musicDir: "/tmp/melo-test/music",
           ytdlpPath: "/tmp/melo-test/yt-dlp", osPrefersDark: true, appVersion: "test" });

  it("opens new installs on YouTube, not YouTube Music", () => {
    expect(defaultSettings().homeSource).toBe("youtube");
  });

  it("skips silence on new installs", () => {
    expect(defaultSettings().silenceSkip).toBe(true);
  });

  it("tags with every service on new installs", () => {
    expect(tagServicesOf(defaultSettings())).toEqual({ lastfm: true, musicbrainz: true, deezer: true });
  });

  it("reads a service switched off as off", () => {
    expect(tagServicesOf({ ...defaultSettings(), tagMusicBrainz: false }).musicbrainz).toBe(false);
  });
});

describe("autoTagEnabled", () => {
  it("is on for new", () => {
    expect(autoTagEnabled("new")).toBe(true);
  });
  it("is off for off and for nothing saved", () => {
    expect(autoTagEnabled("off")).toBe(false);
    expect(autoTagEnabled(undefined)).toBe(false);
  });
});
