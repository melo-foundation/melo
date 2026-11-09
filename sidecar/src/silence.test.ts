import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, mkdtempSync, writeFileSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { fileURLToPath } from "url";
import { setEnv } from "./env";
import { detectSilence } from "./silence";

// The ffmpeg melo ships (scripts/build-ffmpeg.sh), not whatever is on PATH:
// the point is that the minimal build decodes and measures what the scan
// hands it. Skips when it has not been built.
const FFMPEG = fileURLToPath(new URL("../../vendor/ffmpeg/bin/ffmpeg", import.meta.url));

// 3 s silence, 5 s of 440 Hz at half scale, 3 s silence; 16-bit mono WAV.
function wav(path: string): void {
  const rate = 48000;
  const secs = [{ amp: 0, n: 3 * rate }, { amp: 0.5, n: 5 * rate }, { amp: 0, n: 3 * rate }];
  const n = secs.reduce((a, s) => a + s.n, 0);
  const b = Buffer.alloc(44 + n * 2);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * 2, 4); b.write("WAVE", 8);
  b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(n * 2, 40);
  let i = 0;
  for (const s of secs)
    for (let k = 0; k < s.n; k++, i++)
      b.writeInt16LE(Math.round(s.amp * 32767 * Math.sin((2 * Math.PI * 440 * k) / rate)), 44 + i * 2);
  writeFileSync(path, b);
}

describe.skipIf(!existsSync(FFMPEG))("silence scan with melo's ffmpeg", () => {
  let file = "";
  beforeAll(() => {
    const dir = mkdtempSync(join(tmpdir(), "melo-silence-"));
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: join(dir, "yt-dlp"), ffmpegPath: FFMPEG,
             osPrefersDark: true, appVersion: "test" });
    file = join(dir, "t.wav");
    wav(file);
  });

  it("finds the silence at both ends", async () => {
    const r = await detectSilence(file, 11, -40, 5, 5);
    expect(r.skipStart).toBeCloseTo(3, 1);
    expect(r.skipEnd).toBeCloseTo(8, 1);
  });
});

// ffmpeg runs on stream URLs a plugin returned; it may open nothing but a file
// or plain http (the relay).
describe.skipIf(process.platform === "win32")("silence scan ffmpeg arguments", () => {
  it("limits every ffmpeg input to file and http", async () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-silence-args-"));
    const log = join(dir, "args.log");
    const fake = join(dir, "ffmpeg");
    writeFileSync(fake, `#!/bin/sh\necho "$@" >> '${log}'\nexit 0\n`, { mode: 0o755 });
    setEnv({ dataDir: dir, musicDir: dir, ytdlpPath: join(dir, "yt-dlp"), ffmpegPath: fake,
             osPrefersDark: true, appVersion: "test" });
    const src = join(dir, "t.wav");
    writeFileSync(src, "x");
    await detectSilence(src, 100, -40, 15, 15);
    const lines = readFileSync(log, "utf8").trim().split("\n");
    expect(lines).toHaveLength(2);
    for (const l of lines) expect(l).toMatch(/-protocol_whitelist file,http,tcp -i /);
  });
});
