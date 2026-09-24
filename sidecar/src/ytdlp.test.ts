import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, utimesSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { setEnv } from "./env";
import { isPipYtdlp, maybeUpdateYtdlp, downloadYtdlp, ytdlpReleaseUrl } from "./ytdlp";

const PIP_WRAPPER = `#!/usr/bin/python3
# -*- coding: utf-8 -*-
import re
import sys
from yt_dlp import main
if __name__ == '__main__':
    sys.exit(main())
`;

function setupBin(contents: string, name = "yt-dlp"): string {
  const dir = mkdtempSync(join(tmpdir(), "melo-ytdlp-"));
  const bin = join(dir, name);
  writeFileSync(bin, contents);
  chmodSync(bin, 0o755);
  setEnv({
    dataDir: dir,
    musicDir: dir,
    ytdlpPath: bin,
    osPrefersDark: true,
    appVersion: "test",
  });
  return bin;
}

describe("isPipYtdlp", () => {
  it("is true for a PyPI console-script wrapper", () => {
    const bin = setupBin(PIP_WRAPPER);
    expect(isPipYtdlp(bin)).toBe(true);
  });

  it("is false for a missing file or a standalone binary", () => {
    expect(isPipYtdlp("/nonexistent/yt-dlp")).toBe(false);
    const bin = setupBin("\x7fELF" + "standalone-payload");
    expect(isPipYtdlp(bin)).toBe(false);
  });
});

describe("maybeUpdateYtdlp", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("replaces a pip wrapper with the GitHub binary instead of --update-to", async () => {
    const bin = setupBin(PIP_WRAPPER);
    const payload = Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0, 1, 2, 3]);
    const fetchMock = vi.fn(async () => ({
      ok: true,
      arrayBuffer: async () => payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength),
    }));
    vi.stubGlobal("fetch", fetchMock);

    await maybeUpdateYtdlp();

    expect(fetchMock).toHaveBeenCalled();
    expect(readFileSync(bin)).toEqual(payload);
    expect(isPipYtdlp(bin)).toBe(false);
  });
});

describe("downloadYtdlp", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("does not overwrite an existing standalone binary", async () => {
    const bin = setupBin("\x7fELFkeep-me");
    vi.stubGlobal("fetch", vi.fn(async () => {
      throw new Error("should not fetch");
    }));
    expect(await downloadYtdlp()).toBe(true);
    expect(readFileSync(bin, "utf8")).toBe("\x7fELFkeep-me");
  });
});

describe("release channel", () => {
  it("points nightly at its own repo", () => {
    expect(ytdlpReleaseUrl("nightly")).toContain("yt-dlp-nightly-builds");
    expect(ytdlpReleaseUrl("stable")).not.toContain("nightly");
    expect(ytdlpReleaseUrl("stable")).toContain("/yt-dlp/yt-dlp/releases/");
  });

  it("treats anything that is not nightly as stable", () => {
    expect(ytdlpReleaseUrl("")).toBe(ytdlpReleaseUrl("stable"));
    expect(ytdlpReleaseUrl("banana")).toBe(ytdlpReleaseUrl("stable"));
  });
});
