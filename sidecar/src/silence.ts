import { execFile } from "child_process";
import { promisify } from "util";
import { getEnv } from "./env";
import { relayUrl } from "./stream-relay";

const execFileAsync = promisify(execFile);

export interface SilenceResult {
  skipStart: number; // seconds to skip at beginning
  skipEnd: number; // effective end time (duration - trailing silence)
}

const cache = new Map<string, SilenceResult>();

/** The file behind this id changed: scan it afresh next time. */
export function forgetSilence(videoId: string): void {
  cache.delete(videoId);
}

export function getCachedSilence(videoId: string): SilenceResult | undefined {
  return cache.get(videoId);
}

function rms(buf: Float32Array, start: number, length: number): number {
  let sum = 0;
  const end = Math.min(start + length, buf.length);
  for (let i = start; i < end; i++) sum += buf[i] * buf[i];
  return Math.sqrt(sum / (end - start));
}

// One detection per video at a time: play + prefetch (+ rapid skips) would
// race the RESULT cache and run up to 4 identical ffmpeg pairs concurrently.
const pending = new Map<string, Promise<SilenceResult>>();

export function detectSilence(
  source: string,
  duration: number,
  thresholdDb: number,
  scanStart: number,
  scanEnd: number,
  videoId?: string,
): Promise<SilenceResult> {
  if (videoId) {
    const cached = cache.get(videoId);
    if (cached) return Promise.resolve(cached);
    const inflight = pending.get(videoId);
    if (inflight) return inflight;
  }
  const work = detectSilenceUncached(source, duration, thresholdDb, scanStart, scanEnd, videoId);
  if (videoId) {
    pending.set(videoId, work);
    work.finally(() => pending.delete(videoId));
  }
  return work;
}

// Two ffmpeg processes pull from the same relay URL the deck is streaming
// (the tail scan uses -sseof, forcing a fetch at the far end of the file).
// googlevideo throttles to ~2x realtime, so racing the deck at track start
// costs audible buffering. Local files have no such contention.
const REMOTE_SCAN_DELAY_MS = 3000;

const isRemote = (source: string) => /^https?:/i.test(source);

async function detectSilenceUncached(
  source: string,
  duration: number,
  thresholdDb: number,
  scanStart: number,
  scanEnd: number,
  videoId?: string,
): Promise<SilenceResult> {
  const fallback: SilenceResult = { skipStart: 0, skipEnd: duration };

  try {
    const sampleRate = 16000;
    if (isRemote(source)) await new Promise((r) => setTimeout(r, REMOTE_SCAN_DELAY_MS));
    // melo's ffmpeg has no TLS, so an https source is read through the local
    // relay, which fetches it with Node's. The relay reuses the deck's entry
    // when the deck is already streaming this URL.
    const input = /^https:/i.test(source) ? await relayUrl(source) : source;
    const ffmpeg = getEnv().ffmpegPath || "ffmpeg";
    const ffmpegBase = ["-f", "f32le", "-acodec", "pcm_f32le", "-ac", "1", "-ar", String(sampleRate), "-v", "error", "-"];
    const threshold = Math.pow(10, thresholdDb / 20);
    const windowSamples = Math.floor(sampleRate * 50 / 1000); // 50ms windows = 800 samples

    const [headResult, tailResult] = await Promise.all([
      execFileAsync(ffmpeg, ["-i", input, "-t", String(scanStart), ...ffmpegBase], {
        timeout: 10000 + scanStart * 500,
        maxBuffer: 10 * 1024 * 1024,
        encoding: "buffer",
      }),
      execFileAsync(ffmpeg, ["-sseof", `-${scanEnd}`, "-i", input, ...ffmpegBase], {
        timeout: 10000 + scanEnd * 500,
        maxBuffer: 10 * 1024 * 1024,
        encoding: "buffer",
      }),
    ]);

    const headBuf = headResult.stdout as unknown as Buffer;
    const tailBuf = tailResult.stdout as unknown as Buffer;
    const headSamples = new Float32Array(headBuf.buffer, headBuf.byteOffset, headBuf.byteLength / 4);
    const tailSamples = new Float32Array(tailBuf.buffer, tailBuf.byteOffset, tailBuf.byteLength / 4);

    // Leading silence: scan forward
    let leadingSamples = 0;
    for (let i = 0; i < headSamples.length; i += windowSamples) {
      if (rms(headSamples, i, windowSamples) >= threshold) break;
      leadingSamples = i + windowSamples;
    }
    const skipStart = leadingSamples / sampleRate;

    // Trailing silence: scan backward
    let trailingSamples = 0;
    for (let i = tailSamples.length - windowSamples; i >= 0; i -= windowSamples) {
      if (rms(tailSamples, i, windowSamples) >= threshold) break;
      trailingSamples = tailSamples.length - i;
    }
    const skipEnd = duration - trailingSamples / sampleRate;

    const result: SilenceResult = { skipStart, skipEnd: Math.max(skipEnd, skipStart) };
    console.log(`[silence] ${videoId?.slice(0, 8) ?? "?"}: skipStart=${skipStart.toFixed(2)}s skipEnd=${skipEnd.toFixed(2)}s (threshold=${thresholdDb}dB)`);
    if (videoId) cache.set(videoId, result);
    return result;
  } catch (err) {
    console.error("[silence] detection error:", err);
    return fallback;
  }
}
