import { describe, it, expect } from "vitest";
import { youtubeCookies } from "./guest-cookies";

// What an import may keep. A guest profile is YouTube's cookies and nothing
// else: no google.com cookie, .google.com.br included.
describe("youtubeCookies", () => {
  const c = (domain: string) => ({ domain, name: "n", value: "v" });

  it("keeps youtube.com and every subdomain of it", () => {
    const kept = youtubeCookies([c(".youtube.com"), c("www.youtube.com"), c("music.youtube.com")]);
    expect(kept.map((k) => k.domain)).toEqual([".youtube.com", "www.youtube.com", "music.youtube.com"]);
  });

  it("drops google.com in every form", () => {
    const kept = youtubeCookies([c(".google.com"), c("accounts.google.com"), c(".google.com.br"), c("www.google.com")]);
    expect(kept).toEqual([]);
  });

  it("drops a domain that only ends in the same letters", () => {
    expect(youtubeCookies([c("notyoutube.com"), c("youtube.com.evil.test")])).toEqual([]);
  });
});
