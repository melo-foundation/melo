import { describe, it, expect, beforeAll, afterEach, vi } from "vitest";
import { createHash } from "crypto";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, utimesSync, existsSync, statSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import * as openpgp from "openpgp";
import { setEnv } from "./env";
import {
  maybeUpdateYtdlp, downloadYtdlp, updateNow, ytdlpReady, ytdlpReleaseUrl, ytdlpAssetName, setYtdlpTrustForTests,
} from "./ytdlp";

const ASSET = ytdlpAssetName();
const GOOD = "#!/bin/sh\necho 2026.09.01\n";
const OLD = "#!/bin/sh\necho 2025.01.01\n";
const DAY_AGO = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000);

interface Keys { privateKey: openpgp.PrivateKey; publicKey: openpgp.PublicKey }
let signer: Keys;
let stranger: Keys;

async function makeKeys(name: string): Promise<Keys> {
  const { privateKey, publicKey } = await openpgp.generateKey({ userIDs: [{ name }], format: "object" });
  return { privateKey, publicKey };
}

function trustSigner(opts: { checkElf?: boolean; fingerprint?: string } = {}): void {
  setYtdlpTrustForTests({
    armoredKey: signer.publicKey.armor(),
    fingerprint: opts.fingerprint ?? signer.publicKey.getFingerprint(),
    checkElf: opts.checkElf ?? false,
  });
}

beforeAll(async () => {
  signer = await makeKeys("signer");
  stranger = await makeKeys("stranger");
});

const sha = (s: string | Buffer) => createHash("sha256").update(s).digest("hex");

/** A release's three files: the binary, SHA2-256SUMS and its detached signature. */
async function release(binary: string, opts: { signWith?: Keys; listedHash?: string } = {}) {
  const sums = Buffer.from(`${opts.listedHash ?? sha(binary)}  ${ASSET}\n${"0".repeat(64)}  yt-dlp.tar.gz\n`);
  const sig = await openpgp.sign({
    message: await openpgp.createMessage({ binary: new Uint8Array(sums) }),
    signingKeys: (opts.signWith ?? signer).privateKey,
    detached: true,
    format: "binary",
  });
  return new Map<string, Buffer>([
    [ytdlpReleaseUrl("stable"), Buffer.from(binary)],
    [ytdlpReleaseUrl("stable", "SHA2-256SUMS"), sums],
    [ytdlpReleaseUrl("stable", "SHA2-256SUMS.sig"), Buffer.from(sig as Uint8Array)],
  ]);
}

function stubFetch(files: Map<string, Buffer>, gate?: Promise<void>) {
  const fetchMock = vi.fn(async (url: string) => {
    if (gate) await gate;
    const body = files.get(url);
    if (!body) return new Response(null, { status: 404 });
    return new Response(new Uint8Array(body), { status: 200, headers: { "content-length": String(body.length) } });
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

const binaryFetches = (m: ReturnType<typeof stubFetch>) =>
  m.mock.calls.filter(([url]) => url === ytdlpReleaseUrl("stable")).length;

/** A temp dir with the binary at its yt-dlp path, or no binary when contents is null. */
function setupBin(contents: string | null): string {
  const dir = mkdtempSync(join(tmpdir(), "melo-ytdlp-"));
  const bin = join(dir, "yt-dlp");
  if (contents !== null) {
    writeFileSync(bin, contents);
    chmodSync(bin, 0o755);
    utimesSync(bin, DAY_AGO, DAY_AGO);
  }
  setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: bin, osPrefersDark: true, appVersion: "test" });
  return bin;
}

function captureLog(): () => string {
  const lines: string[] = [];
  vi.spyOn(process.stderr, "write").mockImplementation((s: string | Uint8Array) => { lines.push(String(s)); return true; });
  vi.spyOn(process.stdout, "write").mockImplementation((s: string | Uint8Array) => { lines.push(String(s)); return true; });
  return () => lines.join("");
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  trustSigner();
});

describe("first-run install", () => {
  it("installs a binary whose signed hash matches, leaving no staging file", async () => {
    trustSigner();
    const bin = setupBin(null);
    stubFetch(await release(GOOD));
    const logged = captureLog();
    expect(await ytdlpReady()).toBe(bin);
    expect(readFileSync(bin, "utf8")).toBe(GOOD);
    expect(statSync(bin).mode & 0o777).toBe(0o755);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).toContain('"state":"downloading"');
    expect(logged()).toContain('"state":""');
  });

  it("refuses a SHA2-256SUMS signed by another key", async () => {
    trustSigner();
    const bin = setupBin(null);
    stubFetch(await release(GOOD, { signWith: stranger }));
    const logged = captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/yt-dlp could not be verified; not installed/);
    expect(existsSync(bin)).toBe(false);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).toMatch(/\[ytdlp\] update refused: SHA2-256SUMS signature does not verify/);
    expect(logged()).toContain('"state":"failed"');
  });

  it("refuses a valid signature from a key whose fingerprint is not the pinned one", async () => {
    trustSigner({ fingerprint: stranger.publicKey.getFingerprint() });
    const bin = setupBin(null);
    stubFetch(await release(GOOD));
    const logged = captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/could not be verified/);
    expect(existsSync(bin)).toBe(false);
    expect(logged()).toMatch(/update refused: signing key fingerprint .* is not the pinned/);
  });

  it("refuses a binary whose hash differs from the signed entry", async () => {
    trustSigner();
    const bin = setupBin(null);
    stubFetch(await release(GOOD, { listedHash: sha("something else") }));
    const logged = captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/could not be verified/);
    expect(existsSync(bin)).toBe(false);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).toMatch(/update refused: sha256 of .* SHA2-256SUMS lists/);
  });

  it.runIf(process.platform === "linux")("refuses a non-ELF binary when the ELF check is on", async () => {
    trustSigner({ checkElf: true });
    const bin = setupBin(null);
    stubFetch(await release(GOOD));
    const logged = captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/could not be verified/);
    expect(existsSync(bin)).toBe(false);
    expect(logged()).toMatch(/update refused: .* is not an ELF binary/);
  });

  it("refuses a binary that fails --version", async () => {
    trustSigner();
    const bin = setupBin(null);
    stubFetch(await release("#!/bin/sh\nexit 3\n"));
    const logged = captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/could not be verified/);
    expect(existsSync(bin)).toBe(false);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).toMatch(/update refused: the downloaded binary failed --version/);
  });

  it("makes concurrent callers share one download", async () => {
    trustSigner();
    const bin = setupBin(null);
    let finish!: () => void;
    const gate = new Promise<void>((r) => { finish = r; });
    const fetchMock = stubFetch(await release(GOOD), gate);
    captureLog();
    const a = ytdlpReady();
    const b = ytdlpReady();
    const c = downloadYtdlp();
    finish();
    expect(await a).toBe(bin);
    expect(await b).toBe(bin);
    expect(await c).toBe(true);
    expect(binaryFetches(fetchMock)).toBe(1);
    expect(readFileSync(bin, "utf8")).toBe(GOOD);
  });

  it("reports throttled progress while the binary streams in", async () => {
    trustSigner();
    const bin = setupBin(null);
    const files = await release(GOOD + "#".repeat(8000));
    const binary = files.get(ytdlpReleaseUrl("stable"))!;
    const fetchMock = stubFetch(files);
    // the binary arrives in 10 chunks, 60 ms apart
    fetchMock.mockImplementation(async (url: string) => {
      if (url !== ytdlpReleaseUrl("stable")) {
        const b = files.get(url)!;
        return new Response(new Uint8Array(b), { status: 200 });
      }
      let i = 0;
      const step = Math.ceil(binary.length / 10);
      const stream = new ReadableStream<Uint8Array>({
        async pull(ctl) {
          if (i >= binary.length) { ctl.close(); return; }
          await new Promise((r) => setTimeout(r, 60));
          ctl.enqueue(new Uint8Array(binary.subarray(i, i + step)));
          i += step;
        },
      });
      return new Response(stream, { status: 200, headers: { "content-length": String(binary.length) } });
    });
    const logged = captureLog();
    expect(await ytdlpReady()).toBe(bin);
    const progress = logged().split("\n").filter((l) => l.includes('"received"'))
      .map((l) => JSON.parse(l).params as { state: string; received: number; total: number });
    expect(progress.length).toBeGreaterThanOrEqual(2);
    expect(progress.length).toBeLessThan(10);
    for (const p of progress) {
      expect(p.state).toBe("downloading");
      expect(p.total).toBe(binary.length);
    }
    const received = progress.map((p) => p.received);
    expect(received).toEqual([...received].sort((a, b) => a - b));
    expect(received.at(-1)).toBe(binary.length);
    expect(readFileSync(bin).equals(binary)).toBe(true);
  });

  it("says the download failed when the network does", async () => {
    trustSigner();
    setupBin(null);
    stubFetch(new Map());
    captureLog();
    await expect(ytdlpReady()).rejects.toThrow(/yt-dlp could not be downloaded/);
  });

  it("does not touch an existing binary", async () => {
    trustSigner();
    const bin = setupBin(OLD);
    const fetchMock = stubFetch(new Map());
    expect(await downloadYtdlp()).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(readFileSync(bin, "utf8")).toBe(OLD);
  });
});

describe("updates", () => {
  it("replaces an outdated binary with the verified release", async () => {
    trustSigner();
    const bin = setupBin(OLD);
    stubFetch(await release(GOOD));
    const logged = captureLog();
    await maybeUpdateYtdlp();
    expect(readFileSync(bin, "utf8")).toBe(GOOD);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).not.toContain("ytdlp/status");
  });

  it("skips the download when the installed binary matches the signed hash", async () => {
    trustSigner();
    const bin = setupBin(GOOD);
    const fetchMock = stubFetch(await release(GOOD));
    captureLog();
    await maybeUpdateYtdlp();
    expect(binaryFetches(fetchMock)).toBe(0);
    expect(Date.now() - statSync(bin).mtimeMs).toBeLessThan(60000);
  });

  it("does not check again within a day", async () => {
    trustSigner();
    const bin = setupBin(OLD);
    utimesSync(bin, new Date(), new Date());
    const fetchMock = stubFetch(await release(GOOD));
    await maybeUpdateYtdlp();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("keeps the existing binary when the update is refused", async () => {
    trustSigner();
    const bin = setupBin(OLD);
    stubFetch(await release(GOOD, { signWith: stranger }));
    const logged = captureLog();
    expect(await updateNow("stable")).toBe(false);
    expect(readFileSync(bin, "utf8")).toBe(OLD);
    expect(existsSync(bin + ".part")).toBe(false);
    expect(logged()).toMatch(/\[ytdlp\] update refused: /);
    expect(logged()).not.toContain("ytdlp/status");
  });

  it("keeps the existing binary when the new one fails --version", async () => {
    trustSigner();
    const bin = setupBin(OLD);
    stubFetch(await release("#!/bin/sh\nexit 1\n"));
    captureLog();
    expect(await updateNow("stable")).toBe(false);
    expect(readFileSync(bin, "utf8")).toBe(OLD);
    expect(existsSync(bin + ".part")).toBe(false);
  });
});

describe("release channel", () => {
  it("points nightly at its own repo", () => {
    expect(ytdlpReleaseUrl("nightly")).toContain("yt-dlp-nightly-builds");
    expect(ytdlpReleaseUrl("stable")).not.toContain("nightly");
    expect(ytdlpReleaseUrl("stable")).toContain("/yt-dlp/yt-dlp/releases/");
    expect(ytdlpReleaseUrl("nightly", "SHA2-256SUMS.sig")).toMatch(/nightly-builds\/releases\/latest\/download\/SHA2-256SUMS\.sig$/);
  });

  it("treats anything that is not nightly as stable", () => {
    expect(ytdlpReleaseUrl("")).toBe(ytdlpReleaseUrl("stable"));
    expect(ytdlpReleaseUrl("banana")).toBe(ytdlpReleaseUrl("stable"));
  });
});
