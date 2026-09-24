import { describe, it, expect } from "vitest";
import { parseNextResponse, hasAuthCookie, cookiesForHost, parseAccountMenu, authCookie, signedInFrom } from "./innertube";

// Shape taken from a live /next response: the related list ends in a
// continuation item, and the numbers live in the primary/secondary renderers.
const response = {
  contents: {
    twoColumnWatchNextResults: {
      autoplay: { autoplay: { sets: [{ autoplayVideo: { watchEndpoint: { videoId: "next1" } } }] } },
      results: {
        results: {
          contents: [
            { videoPrimaryInfoRenderer: {
                viewCount: { videoViewCountRenderer: {
                  viewCount: { simpleText: "1,809,865,038 views" },
                  extraShortViewCount: { simpleText: "1.8B" },
                } },
                dateText: { simpleText: "Oct 24, 2009" },
                relativeDateText: { simpleText: "16 years ago" },
                videoActions: { menuRenderer: { topLevelButtons: [{ segmentedLikeDislikeButtonViewModel: {
                  likeButtonViewModel: { likeButtonViewModel: { toggleButtonViewModel: { toggleButtonViewModel: {
                    defaultButtonViewModel: { buttonViewModel: { title: "19M" } } } } } } } }] } },
              } },
            { videoSecondaryInfoRenderer: {
                owner: { videoOwnerRenderer: { subscriberCountText: { simpleText: "4.54M subscribers" } } },
                attributedDescription: { content: "The official video." },
              } },
          ],
        },
      },
      secondaryResults: {
        secondaryResults: {
          results: [
            { lockupViewModel: {
                contentId: "vid1",
                contentType: "LOCKUP_CONTENT_TYPE_VIDEO",
                metadata: { lockupMetadataViewModel: {
                  title: { content: "A song" },
                  metadata: { contentMetadataViewModel: { metadataRows: [
                    { metadataParts: [{ text: { content: "A channel" } }] },
                  ] } },
                } },
                contentImage: { thumbnailViewModel: {
                  image: { sources: [{ url: "https://i.ytimg.com/vi/vid1/hq.jpg" }] },
                  overlays: [{ thumbnailOverlayBadgeViewModel: { thumbnailBadges: [
                    { thumbnailBadgeViewModel: { text: "3:32" } },
                  ] } }],
                } },
              } },
            { continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token: "TOKEN" } } } },
          ],
        },
      },
    },
  },
};

describe("parseNextResponse", () => {
  it("keeps the continuation token the related list ends on", () => {
    expect(parseNextResponse(response).continuation).toBe("TOKEN");
  });

  it("reads the video's own numbers", () => {
    const info = parseNextResponse(response).info!;
    expect(info.views).toBe("1,809,865,038 views");
    expect(info.viewsShort).toBe("1.8B");
    expect(info.likes).toBe("19M");
    expect(info.published).toBe("Oct 24, 2009");
    expect(info.age).toBe("16 years ago");
    expect(info.subscribers).toBe("4.54M subscribers");
    expect(info.description).toBe("The official video.");
  });

  it("still parses suggestions, and survives a response with none of it", () => {
    const r = parseNextResponse(response);
    expect(r.suggestions.map((s) => s.id)).toEqual(["vid1"]);
    expect(r.autoplay?.id).toBe("next1");

    const empty = parseNextResponse({});
    expect(empty).toEqual({ autoplay: null, suggestions: [], continuation: "", info: null });
  });
});

// Signed-in is the presence of the cookie the SAPISIDHASH is computed from:
// buildHeaders sends an Authorization header exactly when this is true, so
// the UI must answer the same question the same way.
describe("hasAuthCookie", () => {
  const c = (name: string) => ({ name, value: "x", domain: ".youtube.com" }) as any;

  it("is true for SAPISID and for the 3P variant", () => {
    expect(hasAuthCookie([c("VISITOR_INFO1_LIVE"), c("SAPISID")])).toBe(true);
    expect(hasAuthCookie([c("__Secure-3PAPISID")])).toBe(true);
  });

  it("is false for a guest session's cookies", () => {
    expect(hasAuthCookie([c("VISITOR_INFO1_LIVE"), c("YSC"), c("PREF"), c("SOCS")])).toBe(false);
  });

  it("is false for nothing at all", () => {
    expect(hasAuthCookie([])).toBe(false);
  });
});

// A request carries the cookies a browser would send to that host and no
// others. Given accounts.google.com and .google.com.br cookies, youtube.com
// answers a signed-in session with CookieMismatch.
describe("cookiesForHost", () => {
  const c = (name: string, domain: string) => ({ name, value: "x", domain }) as any;
  const jar = [
    c("SID", ".youtube.com"),
    c("PREF", "www.youtube.com"),
    c("LOGIN_INFO", "music.youtube.com"),
    c("SID", ".google.com"),
    c("LSID", "accounts.google.com"),
    c("NID", ".google.com.br"),
    c("x", ".chromewebstore.google.com"),
    c("y", "notyoutube.com"),
  ];
  const names = (host: string) => cookiesForHost(jar, host).map((k: any) => k.domain);

  it("keeps the parent domain and the host itself", () => {
    expect(names("www.youtube.com")).toEqual([".youtube.com", "www.youtube.com"]);
  });

  it("drops every google.com cookie from a youtube.com request", () => {
    const d = names("www.youtube.com");
    expect(d).not.toContain(".google.com");
    expect(d).not.toContain("accounts.google.com");
    expect(d).not.toContain(".google.com.br");
  });

  it("does not match a domain that merely ends in the same letters", () => {
    expect(names("www.youtube.com")).not.toContain("notyoutube.com");
  });

  it("keeps a sibling host's host-only cookie off another subdomain", () => {
    expect(names("music.youtube.com")).toEqual([".youtube.com", "music.youtube.com"]);
  });
});

// The account a signed-in session opens as, from InnerTube's account_menu —
// the call youtube.com makes to draw its avatar menu. Shape taken from a live
// response; the values here are invented.
describe("parseAccountMenu", () => {
  const live = {
    actions: [{ openPopupAction: { popup: { multiPageMenuRenderer: { header: {
      activeAccountHeaderRenderer: {
        accountName: { simpleText: "Ada Lovelace" },
        accountPhoto: { thumbnails: [{ url: "https://yt3.ggpht.com/abc=s108-c-k", width: 108, height: 108 }] },
        channelHandle: { simpleText: "@ada" },
        manageAccountTitle: { simpleText: "Manage your Google Account" },
      },
    } } } } }],
  };

  it("reads the name, handle and photo", () => {
    expect(parseAccountMenu(live)).toEqual({
      name: "Ada Lovelace", handle: "@ada", photo: "https://yt3.ggpht.com/abc=s108-c-k",
    });
  });

  it("reads text given as runs as well as simpleText", () => {
    const runs = JSON.parse(JSON.stringify(live));
    runs.actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer
      .accountName = { runs: [{ text: "Ada " }, { text: "Lovelace" }] };
    expect(parseAccountMenu(runs)?.name).toBe("Ada Lovelace");
  });

  it("is null for a signed-out response, which carries no account header", () => {
    expect(parseAccountMenu({ actions: [{ openPopupAction: { popup: {} } }] })).toBeNull();
    expect(parseAccountMenu({})).toBeNull();
  });
});

// The auth cookie counts only where YouTube sees it: SAPISIDHASH comes from
// document.cookie, which on youtube.com holds only youtube.com's cookies. A
// signed-out Chromium can keep SAPISID, __Secure-3PAPISID and SID on
// .google.com.br, which a search of the whole jar would read as signed in.
describe("authCookie", () => {
  const c = (name: string, domain: string, value = "v") => ({ name, value, domain }) as any;

  it("ignores an auth cookie left on another Google domain", () => {
    const jar = [c("SAPISID", ".google.com.br"), c("__Secure-3PAPISID", ".google.com.br"),
                 c("SID", ".google.com.br"), c("YSC", ".youtube.com")];
    expect(authCookie(jar, "www.youtube.com")).toBe("");
    expect(hasAuthCookie(jar)).toBe(false);
  });

  it("finds SAPISID when youtube.com holds it", () => {
    expect(authCookie([c("SAPISID", ".youtube.com", "abc")], "www.youtube.com")).toBe("abc");
  });

  it("falls back to the 3P variant on youtube.com", () => {
    expect(authCookie([c("__Secure-3PAPISID", ".youtube.com", "xyz")], "music.youtube.com")).toBe("xyz");
  });

  it("prefers youtube.com's copy when google.com holds another", () => {
    const jar = [c("SAPISID", ".google.com", "google"), c("SAPISID", ".youtube.com", "youtube")];
    expect(authCookie(jar, "www.youtube.com")).toBe("youtube");
  });
});

// Signed in means YouTube names an account: during a sign-out the auth cookie
// can outlive YouTube's acceptance of it. account_menu decides; only a request
// with no answer at all falls back to the cookie.
describe("signedInFrom", () => {
  const ada = { name: "Ada", handle: "@ada", photo: "" };
  it("is signed in when YouTube names the account", () => {
    expect(signedInFrom(true, { answered: true, account: ada })).toBe(true);
  });
  it("is signed out when YouTube answers with no account, cookie or not", () => {
    expect(signedInFrom(true, { answered: true, account: null })).toBe(false);
  });
  it("trusts the cookie when YouTube could not be asked", () => {
    expect(signedInFrom(true, { answered: false, account: null })).toBe(true);
  });
  it("is signed out without an auth cookie", () => {
    expect(signedInFrom(false, { answered: false, account: null })).toBe(false);
  });
});
