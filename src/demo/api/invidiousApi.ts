import type { SearchResult, StreamResult, ApiResponse } from "./types";

// Invidious instances. The live list is fetched at runtime from ytify's
// continuously-tested Uma repo; these are the last-known-good fallbacks.
const FALLBACK_INSTANCES = [
  "https://invidious.schenkel.eti.br",
  "https://yt.omada.cafe",
  "https://invidious.kemonomimi.nl",
];

const UMA_LIST_URL = "https://raw.githubusercontent.com/n-ce/Uma/main/list.json";

let instances = FALLBACK_INSTANCES;
let instancesLoaded: Promise<void> | null = null;

function loadInstances(): Promise<void> {
  if (!instancesLoaded) {
    instancesLoaded = fetch(UMA_LIST_URL)
      .then((r) => r.json())
      .then((j) => {
        const iv: string[] = Array.isArray(j?.iv) ? j.iv : [];
        instances = [...new Set([...iv, ...FALLBACK_INSTANCES])];
      })
      .catch(() => { /* fallbacks stand */ });
  }
  return instancesLoaded;
}

// Instance that most recently served a valid response; tried first.
let preferred: string | null = null;

// Simple in-memory cache
const cache = new Map<string, { data: unknown; ts: number }>();

function getCached<T>(key: string, ttlMs: number): T | null {
  const entry = cache.get(key);
  if (entry && Date.now() - entry.ts < ttlMs) return entry.data as T;
  return null;
}

function setCache(key: string, data: unknown) {
  cache.set(key, { data, ts: Date.now() });
}

async function fetchWithTimeout(url: string, timeoutMs = 8000): Promise<Response> {
  const controller = new AbortController();
  const id = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(id);
  }
}

// Fetches path from the first instance whose JSON passes `validate` —
// instances routinely half-break (alive but no streams), so a 200 isn't enough.
async function tryInstance(
  instance: string,
  path: string,
  validate: (json: any) => boolean,
): Promise<any> {
  const res = await fetchWithTimeout(`${instance}${path}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = await res.json();
  if (!validate(json)) throw new Error("invalid response");
  preferred = instance;
  return json;
}

async function fetchJsonWithFallback(
  path: string,
  validate: (json: any) => boolean,
): Promise<any> {
  await loadInstances();

  if (preferred) {
    try {
      return await tryInstance(preferred, path, validate);
    } catch { /* fall through to the race */ }
  }

  // No known-good instance: race them all, most are dead at any given time.
  try {
    return await Promise.any(
      instances
        .filter((i) => i !== preferred)
        .map((i) => tryInstance(i, path, validate)),
    );
  } catch {
    throw new Error("All streaming instances failed");
  }
}

function thumbOf(item: any): string {
  const thumbs: any[] = item.videoThumbnails || [];
  const medium = thumbs.find((t) => t.quality === "medium");
  return medium?.url || thumbs[0]?.url || "";
}

function mapVideo(item: any): SearchResult {
  return {
    id: item.videoId || "",
    title: item.title || "",
    channel: item.author || "",
    thumbnail: thumbOf(item),
    duration: item.lengthSeconds || 0,
  };
}

export async function search(query: string): Promise<ApiResponse<SearchResult[]>> {
  const cacheKey = `search:${query}`;
  const cached = getCached<SearchResult[]>(cacheKey, 5 * 60_000);
  if (cached) return { ok: true, data: cached };

  try {
    const json = await fetchJsonWithFallback(
      `/api/v1/search?q=${encodeURIComponent(query)}&type=video`,
      (j) => Array.isArray(j),
    );
    const items: SearchResult[] = json
      .filter((i: any) => i.type === "video" && !i.liveNow && i.lengthSeconds > 0)
      .map(mapVideo);
    setCache(cacheKey, items);
    return { ok: true, data: items };
  } catch (e: any) {
    return { ok: false, error: e.message || "Search failed" };
  }
}

export async function getStream(videoId: string): Promise<ApiResponse<StreamResult>> {
  const cacheKey = `stream:${videoId}`;
  const cached = getCached<StreamResult>(cacheKey, 5 * 60_000);
  if (cached) return { ok: true, data: cached };

  try {
    // local=true routes audio through the instance's proxy — googlevideo URLs
    // are IP-locked to the instance and 403 when fetched from the browser.
    const json = await fetchJsonWithFallback(
      `/api/v1/videos/${videoId}?local=true`,
      (j) =>
        Array.isArray(j?.adaptiveFormats) &&
        j.adaptiveFormats.some((f: any) => String(f.type || "").startsWith("audio")),
    );

    const sorted = json.adaptiveFormats
      .filter((f: any) => String(f.type || "").startsWith("audio"))
      .sort((a: any, b: any) => (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0));

    const stream = sorted.find((f: any) => f.type.includes("webm"))
      || sorted.find((f: any) => f.type.includes("mp4"))
      || sorted[0];

    const result: StreamResult = {
      audioUrl: stream.url,
      duration: json.lengthSeconds || 0,
      title: json.title || "",
      channel: json.author || "",
      thumbnail: thumbOf(json),
      relatedStreams: (json.recommendedVideos || [])
        .filter((r: any) => r.lengthSeconds > 0 && r.lengthSeconds < 600)
        .slice(0, 15)
        .map(mapVideo),
    };

    setCache(cacheKey, result);
    return { ok: true, data: result };
  } catch (e: any) {
    return { ok: false, error: e.message || "Stream fetch failed" };
  }
}

export async function getSuggestions(videoId: string): Promise<ApiResponse<SearchResult[]>> {
  const streamResult = await getStream(videoId);
  if (!streamResult.ok) return streamResult;
  return { ok: true, data: streamResult.data.relatedStreams };
}

// YouTube trending is long-form content (music trending is all hour-long
// mixes), so the home feed is built from rotating curated searches instead.
const HOME_QUERIES = [
  "top hits official music video",
  "pop hits official audio",
  "classic rock official music video",
  "edm official music video",
  "hip hop hits official video",
  "indie rock official music video",
];

export async function getTrending(): Promise<ApiResponse<SearchResult[]>> {
  const query = HOME_QUERIES[Math.floor(Math.random() * HOME_QUERIES.length)];
  const res = await search(query);
  if (!res.ok) return res;
  return {
    ok: true,
    data: res.data.filter((t) => t.duration < 600).slice(0, 20),
  };
}
