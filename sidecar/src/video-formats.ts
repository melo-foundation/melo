// Which video-only format to ask YouTube for, and whether it is a picture at all.

export type VideoCodec = "av1" | "vp9" | "h264";

export interface VideoFormatLike {
  itag: number;
  has_video: boolean;
  has_audio: boolean;
  width?: number;
  height?: number;
  fps?: number;
  bitrate?: number;
  mime_type: string;
}

const ALL_CODECS: VideoCodec[] = ["av1", "vp9", "h264"];

export function codecOf(mime: string): VideoCodec | null {
  const m = /codecs="([^".]*)/.exec(mime ?? "");
  const tag = (m?.[1] ?? "").toLowerCase();
  if (tag === "av01") return "av1";
  if (tag === "vp9" || tag === "vp09") return "vp9";
  if (tag === "avc1") return "h264";
  return null;
}

/** First codec in `codecs` with a video-only candidate at or under `maxHeight`;
 *  within it the greatest height, then the greatest bitrate. */
export function pickVideoFormat<T extends VideoFormatLike>(
  formats: T[], maxHeight: number, codecs: VideoCodec[],
): T | null {
  const usable = formats.filter((f) =>
    f.has_video && !f.has_audio && (f.height ?? 0) > 0 && (f.height ?? 0) <= maxHeight);
  for (const codec of codecs) {
    const mine = usable.filter((f) => codecOf(f.mime_type) === codec);
    if (!mine.length) continue;
    mine.sort((a, b) => (b.height! - a.height!) || ((b.bitrate ?? 0) - (a.bitrate ?? 0)));
    return mine[0];
  }
  return null;
}

// A still picture encodes under 200 kbps per megapixel; a real video runs several times that.
const STILL_BPS_PER_MEGAPIXEL = 200_000;

export function isStillFormat(f: { width?: number; height?: number; bitrate?: number }): boolean {
  const px = (f.width ?? 0) * (f.height ?? 0);
  if (!px || !f.bitrate) return false;
  return f.bitrate / (px / 1e6) < STILL_BPS_PER_MEGAPIXEL;
}

/** A still only if every video-only format at `height`, in every codec, is under the threshold:
 *  AV1 encodes the same picture at a lower bitrate than VP9. */
export function isStillAtHeight(formats: VideoFormatLike[], height: number): boolean {
  const at = formats.filter((f) => f.has_video && !f.has_audio && f.height === height);
  return at.length > 0 && at.every(isStillFormat);
}

export function parseCodecs(input: unknown): VideoCodec[] {
  if (!Array.isArray(input)) return [...ALL_CODECS];
  const out = input.filter((c): c is VideoCodec => (ALL_CODECS as string[]).includes(c));
  return out.length ? out : [...ALL_CODECS];
}

export function videoCacheKey(videoId: string, maxHeight: number): string {
  return `${videoId}:${maxHeight}`;
}
