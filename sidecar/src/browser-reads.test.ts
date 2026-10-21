import { describe, it, expect, vi, beforeEach } from "vitest";

const h = vi.hoisted(() => ({ dump: vi.fn() }));
vi.mock("./guest-cookies", async (orig) => ({
  ...(await orig<typeof import("./guest-cookies")>()),
  dumpBrowserCookies: h.dump,
}));
import { KeyringError } from "./guest-cookies";
import { browserUnread, clearCookieCache, forgetBrowser, noteKeyringFailure, resolveCookies, retryBrowser } from "./innertube";
import { sessionCookie } from "./streams";
import { trackingHeaders, trackingUrl } from "./watchtime";

const jar = [{ domain: ".youtube.com", name: "SAPISID", value: "v", path: "/", secure: true, expiry: 2e9 }];

describe("reading a browser's store", () => {
  beforeEach(() => { clearCookieCache(); h.dump.mockReset(); });

  it("reads once a session, and callers asking at once share the read", async () => {
    let finish!: (v: typeof jar) => void;
    h.dump.mockReturnValue(new Promise((r) => { finish = r; }));
    const a = resolveCookies("browser", "chrome", ""), b = resolveCookies("browser", "chrome", "");
    finish(jar);
    expect((await a).map((c) => c.name)).toEqual(["SAPISID"]);
    await b;
    await resolveCookies("browser", "chrome", "");
    expect(h.dump).toHaveBeenCalledTimes(1);
  });

  it("a menu opening during a read waits for it, not a second prompt", async () => {
    let finish!: (v: typeof jar) => void;
    h.dump.mockReturnValue(new Promise((r) => { finish = r; }));
    const a = resolveCookies("browser", "chrome", "");
    forgetBrowser("chrome");
    const b = resolveCookies("browser", "chrome", "");
    finish(jar);
    await Promise.all([a, b]);
    expect(h.dump).toHaveBeenCalledTimes(1);
  });

  it("re-reads only when asked to forget", async () => {
    h.dump.mockResolvedValue(jar);
    await resolveCookies("browser", "chrome", "");
    forgetBrowser("chrome");
    await resolveCookies("browser", "chrome", "");
    expect(h.dump).toHaveBeenCalledTimes(2);
  });

  it("a keyring that said no is not asked again until the browser is picked again", async () => {
    h.dump.mockRejectedValue(new KeyringError("kwallet-query failed with return code 1"));
    await expect(resolveCookies("browser", "chrome", "")).rejects.toBeInstanceOf(KeyringError);
    expect(browserUnread("chrome")).toBe(true);
    forgetBrowser("chrome");   // an account menu opening
    await expect(resolveCookies("browser", "chrome", "")).rejects.toBeInstanceOf(KeyringError);
    expect(h.dump).toHaveBeenCalledTimes(1);
    retryBrowser("chrome");    // Use browser account
    h.dump.mockResolvedValue(jar);
    await resolveCookies("browser", "chrome", "");
    expect(browserUnread("chrome")).toBe(false);
    expect(h.dump).toHaveBeenCalledTimes(2);
  });

  it("a stream's keyring complaint marks the browser only when melo's read lacked the sign-in too", async () => {
    noteKeyringFailure("brave", "ERROR: failed to read from keyring");
    expect(browserUnread("brave")).toBe(false);             // nothing read: not known
    h.dump.mockResolvedValue(jar);
    await resolveCookies("browser", "brave", "");
    noteKeyringFailure("brave", "ERROR: failed to read from keyring");
    expect(browserUnread("brave")).toBe(false);             // signed in anyway
    forgetBrowser("brave");
    h.dump.mockResolvedValue([{ ...jar[0], name: "PREF" }]);
    await resolveCookies("browser", "brave", "");
    noteKeyringFailure("brave", "WARNING: something else");
    expect(browserUnread("brave")).toBe(false);
    noteKeyringFailure("brave", "ERROR: failed to read from keyring");
    expect(browserUnread("brave")).toBe(true);
    clearCookieCache();        // an identity switch
    expect(browserUnread("brave")).toBe(false);
  });
});

describe("the youtubei.js session's cookies", () => {
  const c = (domain: string, name: string) => ({ domain, name, value: "v" });
  it("carry what youtube.com would get, nothing from Google or look-alikes", () => {
    expect(sessionCookie([c(".youtube.com", "SID"), c("www.youtube.com", "A"), c(".google.com", "G"),
                          c("accounts.google.com", "LSID"), c(".google.com.br", "B"), c("notyoutube.com", "N"),
                          c("youtube.com.evil.test", "E"), c("music.youtube.com", "M")]))
      .toBe("SID=v; A=v");
    expect(sessionCookie([c(".google.com", "G")])).toBeUndefined();
  });
});

describe("watchtime tracking URLs", () => {
  it("are fetched only on https YouTube and Google hosts", () => {
    for (const ok of ["https://s.youtube.com/api/stats/playback?x=1", "https://www.youtube.com/ptracking?a",
                      "https://www.google.com/pagead/x"])
      expect(trackingUrl(ok)).toBe(ok);
    for (const bad of ["http://s.youtube.com/api/stats/playback", "https://youtube.com.evil.test/x",
                       "https://notyoutube.com/x", "https://evil.test/?u=youtube.com", "javascript:alert(1)", "", null, 5])
      expect(trackingUrl(bad)).toBe("");
  });

  it("carry the cookies to youtube.com only", () => {
    const headers = { Cookie: "SID=v", Authorization: "SAPISIDHASH x", "X-Goog-AuthUser": "0",
                      "X-Goog-Visitor-Id": "vd", Referer: "r" };
    expect(trackingHeaders("https://s.youtube.com/a", headers)).toEqual(headers);
    expect(trackingHeaders("https://www.google.com/a", headers)).toEqual({ Referer: "r" });
  });
});
