import { describe, it, expect } from "vitest";
import { withConsent } from "./guest-cookies";

// From the EU and UK, youtube.com answers a visitor without SOCS with its consent
// page; yt-dlp sends SOCS=CAI ("accept all") unless signed in or already answered.
describe("the consent cookie", () => {
  it("goes with a visitor that has not answered", () => {
    expect(withConsent("")).toBe("SOCS=CAI");
    expect(withConsent("YSC=a; VISITOR_INFO1_LIVE=b")).toBe("YSC=a; VISITOR_INFO1_LIVE=b; SOCS=CAI");
    expect(withConsent("YSC=a; SOCS=CAAaBgiA")).toBe("YSC=a; SOCS=CAI");
  });

  it("leaves an answer and a signed-in account alone", () => {
    expect(withConsent("SOCS=CAISNQgD")).toBe("SOCS=CAISNQgD");
    expect(withConsent("SAPISID=x; SID=y")).toBe("SAPISID=x; SID=y");
    expect(withConsent("__Secure-3PAPISID=x")).toBe("__Secure-3PAPISID=x");
  });
});
