// Tagging one library track: the auto-tag button, adding a track with auto-tag
// on, and a YouTube Music track that arrives already knowing its album.
import * as lib from "./library";
import * as meta from "./metadata";
import { tagServicesOf, type SettingsV2 } from "./settings";

type TagSettings = Pick<SettingsV2, "lastfmApiKey" | "tagYoutubeMusic" | "tagLastfm" | "tagMusicBrainz" | "tagDeezer">;

// The keys a YouTube Music result carries beyond the track shape
export interface MusicExtras { artists?: string[]; album?: string; albumId?: string; year?: number }

/** Split a track sent to library/addTrack into the stored track and its YouTube Music extras. */
export function splitMusicExtras(track: any): { track: any; extras: MusicExtras } {
  const { artists, album, albumId, year, ...rest } = track;
  const extras: MusicExtras = {};
  if (Array.isArray(artists) && artists.length) extras.artists = artists.map(String);
  if (typeof album === "string" && album) extras.album = album;
  if (typeof albumId === "string" && albumId) extras.albumId = albumId;
  if (Number(year) > 0) extras.year = Number(year);
  return { track: rest, extras };
}

// The video a library track is: a YouTube track's own id, or an imported file's linked video
export function videoIdOf(track: { id: string; youtubeId?: string; source?: string }): string | undefined {
  if (track.youtubeId) return track.youtubeId;
  if (track.source && track.source !== "youtube") return undefined;   // a plugin's track
  return /^[A-Za-z0-9_-]{11}$/.test(track.id) ? track.id : undefined;
}

/** The tags a track's own YouTube Music info gives, with no lookup; null when it has no album. */
export function carriedMetadata(track: { title: string; channel: string; thumbnail?: string }, extras?: MusicExtras): meta.TrackMetadata | null {
  if (!extras?.album) return null;
  return meta.musicMetadata({ title: track.title, artist: track.channel || (extras.artists ?? []).join(", "),
                              album: extras.album, year: extras.year, cover: track.thumbnail });
}

async function store(track: lib.LibraryTrack, result: meta.TrackMetadata, artist: string, title: string,
                     s: TagSettings, videoId?: string): Promise<void> {
  if (result.albumArt) {
    let artFile = await lib.cacheAlbumArt(track.id, result.albumArt);
    if (!artFile && result.source) {
      const altUrl = await meta.lookupAlbumArt(artist, title, s.lastfmApiKey || undefined, result.source, tagServicesOf(s), videoId);
      if (altUrl) {
        artFile = await lib.cacheAlbumArt(track.id, altUrl);
        if (artFile) result.albumArt = altUrl;
      }
    }
    if (artFile) result.albumArtFile = artFile;
  }
  lib.updateTrackMetadata(track.id, result);
}

// "heuristic" is the local title cleanup alone; anything else is the
// YouTube Music / Last.fm / MusicBrainz / Deezer chain with the heuristic as
// fallback. Tracks edited by hand are left alone. True when the track was tagged.
export async function enrichTrack(track: lib.LibraryTrack, mode: string, s: TagSettings, extras?: MusicExtras): Promise<boolean> {
  if (track.metadata?.source === "manual") return false;
  const heuristic = meta.suggestMetadata(track.title, track.channel);
  if (mode === "heuristic") {
    if (!heuristic.artist && !heuristic.cleanTitle) return false;
    lib.updateTrackMetadata(track.id, heuristic);
    return true;
  }
  const artist = heuristic.artist || track.channel;
  const title = heuristic.cleanTitle || track.title;
  const services = tagServicesOf(s);
  const videoId = services.ytmusic ? videoIdOf(track) : undefined;
  const carried = videoId ? carriedMetadata(track, extras) : null;
  if (carried) {
    console.log(`[metadata] YouTube Music (carried): ${track.id} "${carried.artist}" - "${carried.cleanTitle}" [${carried.album}]`);
    await store(track, carried, artist, title, s, videoId);
    return true;
  }
  const cleanChannel = track.channel.replace(/\s*-\s*Topic$/, "");
  const rawChannel = artist !== cleanChannel ? cleanChannel : undefined;
  const result = await meta.lookupMetadata(artist, title, s.lastfmApiKey || undefined, rawChannel, services, videoId);
  if (result) {
    await store(track, result, artist, title, s, videoId);
    return true;
  }
  if (!heuristic.artist && !heuristic.cleanTitle) return false;
  lib.updateTrackMetadata(track.id, heuristic);   // api+heuristic fallback
  return true;
}
