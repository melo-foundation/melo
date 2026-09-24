

// Re-export pure heuristic functions
export { suggestMetadata, stripTags, cleanChannelAsArtist, splitTitle, parseTopicChannel, cleanForQuery } from "./metadata-heuristic";
export type { TrackMetadata } from "./metadata-heuristic";

import type { TrackMetadata } from "./metadata-heuristic";

// --- API lookups ---

// The rate gate is a promise chain shared by the three APIs. Each caller
// queues behind the previous one's slot, so the wait is cumulative and two
// overlapping lookups cannot read the same "now" and fire together.
// MusicBrainz's rule is 1 req/s and it blocks clients that break it.
let apiGate: Promise<void> = Promise.resolve();

// MusicBrainz rejects anonymous clients with 403 ("the application you are
// using has not identified itself"), and the others
// are happier with a real one too.
const UA = "melo/0.1.0 ( https://github.com/melo-foundation/melo )";

async function rateLimitedFetch(url: string, minInterval: number): Promise<Response> {
  // Claim the next slot before awaiting anything, so a second caller entering
  // while we are still waiting chains onto us rather than onto the same past.
  const mine = apiGate.then(() => new Promise<void>((r) => setTimeout(r, minInterval)));
  apiGate = mine.catch(() => {});   // a rejected slot must not wedge the chain
  await mine;
  return fetch(url, { headers: { "User-Agent": UA } });
}

/** @internal test seam for the serialisation above. */
export const __rateLimitedFetchForTest = rateLimitedFetch;

// A title made only of block art, invisible format characters or punctuation
// normalises to nothing. Every containment check below would then pass
// vacuously ("" is a substring of every string) and accept the first result of
// a nonsense query. Nothing identifiable, no lookup.
export function searchableTitle(title: string): string {
  return (title || "")
    .toLowerCase()
    .replace(/[^\w\s\u3000-\u9FFF\uFF00-\uFFEF]/g, "")
    .trim();
}

/**
 * Is this result the same recording, or a different rendition of it? A search
 * API answers "いますぐ輪廻" with "いますぐ輪廻 / Retry Now (8-Bit Cover)" and the
 * query is a substring of it, so containment alone lets covers through.
 */
export function sameRecording(title: string, resultTitle: string): boolean {
  const q = searchableTitle(title);
  const r = searchableTitle(resultTitle);
  if (!q || !r) return false;
  if (!q.includes(r) && !r.includes(q)) return false;
  const shorter = Math.min(q.length, r.length);
  const longer = Math.max(q.length, r.length);
  if (shorter / longer < 0.6) return false;
  const RENDITION = /\b(8[- ]?bit|chiptune|cover|remix|karaoke|instrumental|acoustic|live|nightcore|sped ?up|slowed)\b/i;
  return !(RENDITION.test(resultTitle) && !RENDITION.test(title));
}

/** Last.fm: track.getCorrection + track.getInfo */
export async function lookupLastfm(artist: string, title: string, apiKey: string): Promise<TrackMetadata | null> {
  if (!apiKey) return null;
  console.log(`[metadata] Last.fm lookup: "${artist}" - "${title}"`);
  try {
    // Try correction first
    const corrUrl = `https://ws.audioscrobbler.com/2.0/?method=track.getcorrection&artist=${encodeURIComponent(artist)}&track=${encodeURIComponent(title)}&api_key=${encodeURIComponent(apiKey)}&format=json`;
    const corrRes = await rateLimitedFetch(corrUrl, 200);
    let correctedArtist = artist;
    let correctedTitle = title;
    const corrData = await corrRes.json();
    console.log("[metadata] Last.fm correction response:", JSON.stringify(corrData));
    if (corrRes.ok) {
      const corr = corrData?.corrections?.correction?.track;
      if (corr) {
        correctedArtist = corr.artist?.name || artist;
        correctedTitle = corr.name || title;
        if (correctedArtist !== artist || correctedTitle !== title) {
          console.log(`[metadata] Last.fm corrected: "${correctedArtist}" - "${correctedTitle}"`);
        }
      }
    }

    // Get full track info
    const infoUrl = `https://ws.audioscrobbler.com/2.0/?method=track.getinfo&artist=${encodeURIComponent(correctedArtist)}&track=${encodeURIComponent(correctedTitle)}&api_key=${encodeURIComponent(apiKey)}&autocorrect=1&format=json`;
    const infoRes = await rateLimitedFetch(infoUrl, 200);
    const infoData = await infoRes.json();
    console.log("[metadata] Last.fm info response:", JSON.stringify(infoData));
    if (!infoRes.ok) {
      console.log(`[metadata] Last.fm info request failed: HTTP ${infoRes.status}`);
      return null;
    }
    const trackInfo = infoData?.track;
    if (!trackInfo) {
      console.log("[metadata] Last.fm: no track info returned");
      return null;
    }

    const result: TrackMetadata = {
      artist: trackInfo.artist?.name || correctedArtist,
      cleanTitle: trackInfo.name || correctedTitle,
      source: "lastfm",
    };

    // Album info
    if (trackInfo.album) {
      result.album = trackInfo.album.title;
      // Get album art
      const images = trackInfo.album.image;
      if (Array.isArray(images)) {
        const large = images.find((img: any) => img.size === "extralarge") || images[images.length - 1];
        if (large?.["#text"]) result.albumArt = large["#text"];
      }
    }

    // Genre/tags
    const tags = trackInfo.toptags?.tag;
    if (Array.isArray(tags) && tags.length > 0) {
      result.genre = tags[0].name;
    }

    console.log(`[metadata] Last.fm hit: "${result.artist}" - "${result.cleanTitle}"${result.album ? ` [${result.album}]` : ""}${result.genre ? ` (${result.genre})` : ""}`);
    return result;
  } catch (err) {
    console.error("[metadata] Last.fm lookup error:", err);
    return null;
  }
}

/** Parse a MusicBrainz recording result into TrackMetadata */
function parseMbRecording(rec: any, artist: string, title: string): TrackMetadata | null {
  if (rec.score < 80) {
    console.log(`[metadata] MusicBrainz: best match score ${rec.score} < 80, skipping`);
    return null;
  }

  // Validate: result title should resemble our query title
  // Reject if result is much shorter than query (original matching a remix)
  const qNorm = title.toLowerCase().replace(/[^\w\s\u3000-\u9FFF]/g, "").trim();
  const rNorm = (rec.title || "").toLowerCase().replace(/[^\w\s\u3000-\u9FFF]/g, "").trim();
  if (!qNorm || !rNorm) {
    console.log(`[metadata] MusicBrainz: nothing to match on for "${title}", skipping`);
    return null;
  }
  if (qNorm.length > 3 && rNorm.length > 3) {
    const hasOverlap = qNorm.includes(rNorm) || rNorm.includes(qNorm);
    if (!hasOverlap) {
      console.log(`[metadata] MusicBrainz: title mismatch "${rec.title}" vs "${title}", skipping`);
      return null;
    }
    // Check length ratio: reject if result is <50% of query length (original vs remix)
    const shorter = Math.min(qNorm.length, rNorm.length);
    const longer = Math.max(qNorm.length, rNorm.length);
    if (shorter / longer < 0.5) {
      console.log(`[metadata] MusicBrainz: title length mismatch (${shorter}/${longer}), likely remix vs original, skipping`);
      return null;
    }
  }

  const result: TrackMetadata = {
    artist: rec["artist-credit"]?.[0]?.name || artist,
    cleanTitle: rec.title || title,
    source: "musicbrainz",
  };

  // Album from first release
  if (rec.releases && rec.releases.length > 0) {
    const release = rec.releases[0];
    result.album = release.title;
    if (release.date) {
      const year = parseInt(release.date.slice(0, 4));
      if (!isNaN(year)) result.year = year;
    }
    if (release.id) {
      result.albumArt = `https://coverartarchive.org/release/${release.id}/front-500`;
    }
  }

  // Tags/genres
  if (rec.tags && rec.tags.length > 0) {
    rec.tags.sort((a: any, b: any) => (b.count || 0) - (a.count || 0));
    result.genre = rec.tags[0].name;
  }

  console.log(`[metadata] MusicBrainz hit (score ${rec.score}): "${result.artist}" - "${result.cleanTitle}"${result.album ? ` [${result.album}]` : ""}${result.year ? ` (${result.year})` : ""}`);
  return result;
}

/** Run a single MusicBrainz query and return the top recording or null */
async function mbQuery(query: string): Promise<any | null> {
  const url = `https://musicbrainz.org/ws/2/recording?query=${encodeURIComponent(query)}&limit=3&fmt=json`;
  const res = await rateLimitedFetch(url, 1100);
  const data = await res.json();
  console.log("[metadata] MusicBrainz response:", JSON.stringify(data));
  if (!res.ok) {
    console.log(`[metadata] MusicBrainz request failed: HTTP ${res.status}`);
    return null;
  }
  const recordings = data?.recordings;
  if (!Array.isArray(recordings) || recordings.length === 0) {
    console.log("[metadata] MusicBrainz: no recordings found");
    return null;
  }
  return recordings[0];
}

/** Resolve an artist name via MusicBrainz alias search */
async function mbResolveArtist(artist: string): Promise<string | null> {
  console.log(`[metadata] MusicBrainz artist alias lookup: "${artist}"`);
  const url = `https://musicbrainz.org/ws/2/artist?query=alias:"${artist}"&limit=1&fmt=json`;
  const res = await rateLimitedFetch(url, 1100);
  const data = await res.json();
  console.log("[metadata] MusicBrainz artist response:", JSON.stringify(data));
  if (!res.ok || !data?.artists?.length) return null;
  const match = data.artists[0];
  if (match.score < 80 || match.name === artist) return null;
  console.log(`[metadata] MusicBrainz resolved artist alias: "${artist}" → "${match.name}"`);
  return match.name;
}

/** MusicBrainz: fuzzy recording search with artist alias fallback */
export async function lookupMusicBrainz(artist: string, title: string): Promise<TrackMetadata | null> {
  console.log(`[metadata] MusicBrainz lookup: "${artist}" - "${title}"`);
  try {
    // Try direct query first
    let rec = await mbQuery(`recording:"${title}" AND artist:"${artist}"`);
    if (rec) {
      const result = parseMbRecording(rec, artist, title);
      if (result) return result;
    }

    // Fallback: resolve artist alias, then retry recording search
    const resolved = await mbResolveArtist(artist);
    if (resolved) {
      rec = await mbQuery(`recording:"${title}" AND artist:"${resolved}"`);
      if (rec) {
        const result = parseMbRecording(rec, artist, title);
        if (result) return result;
      }
    }

    return null;
  } catch (err) {
    console.error("[metadata] MusicBrainz lookup error:", err);
    return null;
  }
}

/** Deezer: search API fallback */
export async function lookupDeezer(artist: string, title: string): Promise<TrackMetadata | null> {
  console.log(`[metadata] Deezer lookup: "${artist}" - "${title}"`);
  try {
    const query = `artist:"${artist}" track:"${title}"`;
    const url = `https://api.deezer.com/search?q=${encodeURIComponent(query)}&limit=3`;
    const res = await rateLimitedFetch(url, 100);
    const data = await res.json();
    console.log("[metadata] Deezer response:", JSON.stringify(data));
    if (!res.ok) {
      console.log(`[metadata] Deezer request failed: HTTP ${res.status}`);
      return null;
    }
    if (!data?.data || data.data.length === 0) {
      console.log("[metadata] Deezer: no results");
      return null;
    }

    const track = data.data[0];
    if (!sameRecording(title, track.title || "")) {
      console.log(`[metadata] Deezer: "${track.title}" is not the same recording as "${title}"`);
      return null;
    }
    const result: TrackMetadata = {
      artist: track.artist?.name || artist,
      cleanTitle: track.title || title,
      source: "deezer",
    };

    if (track.album) {
      result.album = track.album.title;
      if (track.album.cover_xl) {
        result.albumArt = track.album.cover_xl;
      } else if (track.album.cover_big) {
        result.albumArt = track.album.cover_big;
      }
    }

    console.log(`[metadata] Deezer hit: "${result.artist}" - "${result.cleanTitle}"${result.album ? ` [${result.album}]` : ""}`);
    return result;
  } catch (err) {
    console.error("[metadata] Deezer lookup error:", err);
    return null;
  }
}

/** Deezer: title-only search fallback (no artist filter) with similarity validation */
export async function lookupDeezerTitleOnly(title: string): Promise<TrackMetadata | null> {
  console.log(`[metadata] Deezer title-only lookup: "${title}"`);
  try {
    const query = `track:"${title}"`;
    const url = `https://api.deezer.com/search?q=${encodeURIComponent(query)}&limit=3`;
    const res = await rateLimitedFetch(url, 100);
    const data = await res.json();
    if (!res.ok || !data?.data?.length) {
      console.log("[metadata] Deezer title-only: no results");
      return null;
    }

    const track = data.data[0];
    const resultTitle = track.title || "";

    if (!sameRecording(title, resultTitle)) {
      console.log(`[metadata] Deezer title-only: "${resultTitle}" is not the same recording as "${title}"`);
      return null;
    }

    const result: TrackMetadata = {
      artist: track.artist?.name,
      cleanTitle: resultTitle,
      source: "deezer",
    };

    if (track.album) {
      result.album = track.album.title;
      if (track.album.cover_xl) {
        result.albumArt = track.album.cover_xl;
      } else if (track.album.cover_big) {
        result.albumArt = track.album.cover_big;
      }
    }

    console.log(`[metadata] Deezer title-only hit: "${result.artist}" - "${result.cleanTitle}"${result.album ? ` [${result.album}]` : ""}`);
    return result;
  } catch (err) {
    console.error("[metadata] Deezer title-only error:", err);
    return null;
  }
}

// Which services a lookup asks, in chain order (settings: tagLastfm,
// tagMusicBrainz, tagDeezer; Last.fm also needs a key). Every service query,
// fallbacks included, goes by it, so a switched-off service is never contacted.
export interface TagServices { lastfm: boolean; musicbrainz: boolean; deezer: boolean }
export const ALL_SERVICES: TagServices = { lastfm: true, musicbrainz: true, deezer: true };
export type TagService = "lastfm" | "musicbrainz" | "deezer";

export function lookupOrder(services: TagServices, lastfmKey?: string): TagService[] {
  const out: TagService[] = [];
  if (services.lastfm && lastfmKey) out.push("lastfm");
  if (services.musicbrainz) out.push("musicbrainz");
  if (services.deezer) out.push("deezer");
  return out;
}

async function lookupFrom(service: TagService, artist: string, title: string, lastfmKey?: string): Promise<TrackMetadata | null> {
  if (service === "lastfm") return lookupLastfm(artist, title, lastfmKey!);
  if (service === "musicbrainz") return lookupMusicBrainz(artist, title);   // cover art via coverartarchive
  return lookupDeezer(artist, title);
}

/** Run the lookup chain for a single artist/title pair, over the services that are on */
async function runLookupChain(artist: string, title: string, lastfmKey: string | undefined, services: TagServices): Promise<TrackMetadata | null> {
  for (const service of lookupOrder(services, lastfmKey)) {
    const hit = await lookupFrom(service, artist, title, lastfmKey);
    if (hit) return hit;
  }
  return null;
}

/** Try to find album art URL from the services that are on (skips the source that already failed) */
export async function lookupAlbumArt(artist: string, title: string, lastfmKey?: string, skipSource?: string, services: TagServices = ALL_SERVICES): Promise<string | null> {
  console.log(`[metadata] Album art fallback lookup: "${artist}" - "${title}" (skip: ${skipSource})`);
  for (const service of lookupOrder(services, lastfmKey)) {
    if (service === skipSource) continue;
    const hit = await lookupFrom(service, artist, title, lastfmKey);
    if (hit?.albumArt) return hit.albumArt;
  }
  return null;
}

/** Detect and strip instrumental/karaoke markers from a title */
const INST_SUFFIX = /\s*[-–—]\s*(?:off\s*vocal(?:\s*ver(?:sion)?\.?)?|instrumental(?:\s*ver(?:sion)?\.?)?|karaoke|カラオケ|オフボーカル|inst\.?)\s*$/i;
const INST_PAREN = /\s*[（(](?:off\s*vocal(?:\s*ver(?:sion)?\.?)?|instrumental(?:\s*ver(?:sion)?\.?)?|karaoke|カラオケ|オフボーカル|inst\.?)[）)]/gi;

function stripInstrumental(title: string): { cleaned: string; wasInstrumental: boolean } {
  const wasInstrumental = INST_SUFFIX.test(title) || INST_PAREN.test(title);
  const cleaned = title.replace(INST_SUFFIX, "").replace(INST_PAREN, "").trim();
  return { cleaned, wasInstrumental };
}

/** If the original track was instrumental but the API returned the vocal version, tag it */
function maybeTagInstrumental(result: TrackMetadata, instrumental: boolean): TrackMetadata {
  if (!instrumental || !result.cleanTitle) return result;
  // Don't double-tag if the API already returned an instrumental version
  if (/\b(?:instrumental|inst\.?|off\s*vocal|karaoke|カラオケ|オフボーカル)\b/i.test(result.cleanTitle)) return result;
  return { ...result, cleanTitle: `${result.cleanTitle} (Instrumental)` };
}

/** Chain: Last.fm → MusicBrainz → Deezer, with optional raw artist retry */
export async function lookupMetadata(artist: string, title: string, lastfmKey?: string, rawArtist?: string, services: TagServices = ALL_SERVICES): Promise<TrackMetadata | null> {
  // Detect and strip instrumental markers before searching
  const { cleaned: searchTitle, wasInstrumental } = stripInstrumental(title);
  const actualTitle = wasInstrumental ? searchTitle : title;

  if (!searchableTitle(actualTitle) && !searchableTitle(artist)) {
    console.log(`[metadata] Nothing searchable in "${artist}" - "${actualTitle}", skipping`);
    return null;
  }

  console.log(`[metadata] Starting lookup chain for: "${artist}" - "${actualTitle}"${wasInstrumental ? " (instrumental)" : ""}`);

  const result = await runLookupChain(artist, actualTitle, lastfmKey, services);
  if (result) return maybeTagInstrumental(result, wasInstrumental);

  // Retry with raw artist name (e.g. Japanese name vs romanized)
  if (rawArtist && rawArtist !== artist) {
    console.log(`[metadata] Retrying with raw artist: "${rawArtist}" - "${actualTitle}"`);
    const retryResult = await runLookupChain(rawArtist, actualTitle, lastfmKey, services);
    if (retryResult) return maybeTagInstrumental(retryResult, wasInstrumental);
  }

  // Final fallback: title-only Deezer search (no artist filter)
  // the title-only search is Deezer's, so it goes with Deezer
  const titleOnly = services.deezer ? await lookupDeezerTitleOnly(actualTitle) : null;
  if (titleOnly) return maybeTagInstrumental(titleOnly, wasInstrumental);

  console.log(`[metadata] No results from any API for: "${artist}" - "${actualTitle}"`);
  return null;
}
