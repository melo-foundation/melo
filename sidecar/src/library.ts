import { dataDir } from "./env";
import { join, basename, extname } from "path";
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, copyFileSync, unlinkSync, renameSync } from "fs";
import { writeFileAtomic, backupOnce, backupPath } from "./atomic";
import { isSafeIdForPath } from "./trackid";
import { execFile } from "child_process";
import { promisify } from "util";
import { randomUUID } from "crypto";
import { pathToFileURL } from "url";
import { YTDLP } from "./platform";
import { type TrackMetadata } from "./metadata";

const execFileAsync = promisify(execFile);

export interface LibraryTrack {
  id: string;
  title: string;
  channel: string;
  duration: number;
  thumbnail: string;
  thumbnailFile?: string;
  downloaded: boolean;
  fileName?: string;
  addedAt: number;
  metadata?: TrackMetadata;
  /** An imported file's linked YouTube video: its plays and suggestions count as that video. */
  youtubeId?: string;
}

export interface LibraryPlaylist {
  playlistId: string;
  title: string;
  thumbnail: string;
  trackIds: string[];
  addedAt: number;
}

export interface LibraryData {
  tracks: LibraryTrack[];
  playlists: LibraryPlaylist[];
}

let library: LibraryData = { tracks: [], playlists: [] };
let downloadPath = "";

const libraryJsonPath = () => join(dataDir(), "library.v2.json");

export function initLibrary(dlPath: string): void {
  downloadPath = dlPath;
  mkdirSync(downloadPath, { recursive: true });
  mkdirSync(join(downloadPath, "thumbs"), { recursive: true });
  mkdirSync(join(downloadPath, "albumart"), { recursive: true });
  library = loadLibrary();
  validateDownloads();
}

// A file that exists and will not parse is an error: read as empty, the next
// save would write an empty library over it. Absent means empty; unreadable
// means try the backup, and refuse to overwrite if that fails too.
let libraryReadFailed = false;

function parseLibrary(raw: string): LibraryData {
  const parsed = JSON.parse(raw);
    return {
      tracks: Array.isArray(parsed.tracks) ? parsed.tracks : [],
      playlists: Array.isArray(parsed.playlists) ? parsed.playlists : [],
    };
}

function loadLibrary(): LibraryData {
  const path = libraryJsonPath();
  if (!existsSync(path)) return { tracks: [], playlists: [] };   // first run
  try {
    return parseLibrary(readFileSync(path, "utf-8"));
  } catch (e) {
    const bak = backupPath(path);
    if (bak) {
      try {
        const recovered = parseLibrary(readFileSync(bak, "utf-8"));
        process.stderr.write(`[library] ${path} is unreadable; recovered ${recovered.tracks.length} tracks from the backup\n`);
        return recovered;
      } catch { /* the backup is gone too */ }
    }
    // Refuse to save over it, so a torn file is never made permanent; the
    // user still gets a running app, and their file is intact
    // on disk for them to look at.
    libraryReadFailed = true;
    process.stderr.write(`[library] ${path} exists but will not parse (${String(e)}). NOT overwriting it; this session starts empty and will not save.\n`);
    return { tracks: [], playlists: [] };
  }
}

function saveLibrary(): void {
  if (libraryReadFailed) {
    process.stderr.write("[library] refusing to save over a library that failed to load\n");
    return;
  }
  const path = libraryJsonPath();
  backupOnce(path);
  writeFileAtomic(path, JSON.stringify(library, null, 2));
}

function validateDownloads(): void {
  let changed = false;
  for (const track of library.tracks) {
    if (track.downloaded && track.fileName) {
      if (!existsSync(join(downloadPath, track.fileName))) {
        track.downloaded = false;
        track.fileName = undefined;
        changed = true;
      }
    }
  }
  if (changed) saveLibrary();
}

export function getLibrary(): LibraryData {
  return library;
}

export function addTrack(track: Omit<LibraryTrack, "downloaded" | "addedAt" | "fileName" | "thumbnailFile">, download: boolean = false): LibraryTrack {
  const existing = library.tracks.find((t) => t.id === track.id);
  if (existing) {
    // Update metadata if it changed
    existing.title = track.title || existing.title;
    existing.channel = track.channel || existing.channel;
    existing.duration = track.duration || existing.duration;
    existing.thumbnail = track.thumbnail || existing.thumbnail;
    saveLibrary();
    if (download && !existing.downloaded) {
      // Queue download handled by caller
    }
    return existing;
  }

  const entry: LibraryTrack = {
    ...track,
    downloaded: false,
    addedAt: Date.now(),
  };
  library.tracks.push(entry);
  saveLibrary();

  // Cache thumbnail in background
  if (track.thumbnail) {
    cacheThumbnail(track.id, track.thumbnail).catch(() => {});
  }

  return entry;
}

export function removeTrack(videoId: string, deleteFile: boolean): boolean {
  const idx = library.tracks.findIndex((t) => t.id === videoId);
  if (idx === -1) return false;

  const track = library.tracks[idx];

  if (deleteFile && track.downloaded && track.fileName) {
    try { unlinkSync(join(downloadPath, track.fileName)); } catch { /* ignore */ }
  }

  if (track.thumbnailFile) {
    try { unlinkSync(join(downloadPath, "thumbs", track.thumbnailFile)); } catch { /* ignore */ }
  }

  library.tracks.splice(idx, 1);

  for (const pl of library.playlists) {
    pl.trackIds = pl.trackIds.filter((id) => id !== videoId);
  }

  saveLibrary();
  return true;
}

// Download queue — max 3 concurrent
const downloadQueue: Array<{ videoId: string; cookieArgsFn: () => Promise<string[]>; resolve: (ok: boolean) => void }> = [];
let activeDownloads = 0;
const MAX_CONCURRENT = 3;

function processQueue(): void {
  while (activeDownloads < MAX_CONCURRENT && downloadQueue.length > 0) {
    const job = downloadQueue.shift()!;
    activeDownloads++;
    doDownload(job.videoId, job.cookieArgsFn).then(
      (ok) => { activeDownloads--; job.resolve(ok); processQueue(); },
      () => { activeDownloads--; job.resolve(false); processQueue(); },
    );
  }
}

export function downloadTrack(videoId: string, cookieArgsFn: () => Promise<string[]>): Promise<boolean> {
  return new Promise((resolve) => {
    downloadQueue.push({ videoId, cookieArgsFn, resolve });
    processQueue();
  });
}

async function doDownload(videoId: string, cookieArgsFn: () => Promise<string[]>): Promise<boolean> {
  const track = library.tracks.find((t) => t.id === videoId);
  if (!track) return false;
  if (track.downloaded && track.fileName && existsSync(join(downloadPath, track.fileName))) return true;

  try {
    const cArgs = await cookieArgsFn();
    const outputTemplate = join(downloadPath, `${videoId}.%(ext)s`);
    await execFileAsync(
      YTDLP(),
      [
        ...cArgs,
        "-f", "bestaudio/best",
        "-o", outputTemplate,
        "--no-warnings",
        "--no-playlist",
        `https://www.youtube.com/watch?v=${videoId}`,
      ],
      { timeout: 120000 },
    );

    // Find the downloaded file (extension is determined by yt-dlp)
    const files = readdirSync(downloadPath);
    const downloaded = files.find((f) => f.startsWith(videoId + ".") && !f.endsWith(".part"));
    if (downloaded) {
      track.fileName = downloaded;
      track.downloaded = true;
      saveLibrary();
      return true;
    }
    return false;
  } catch (err) {
    console.error(`Download failed for ${videoId}:`, err);
    return false;
  }
}

export function getDownloadedUrl(videoId: string): string | null {
  const track = library.tracks.find((t) => t.id === videoId);
  if (track?.downloaded && track.fileName && existsSync(join(downloadPath, track.fileName))) {
    // GStreamer consumes this directly, so it is a real file:// URI.
    return pathToFileURL(join(downloadPath, track.fileName)).href;
  }
  return null;
}

export function getTrackMetadata(videoId: string): LibraryTrack | undefined {
  return library.tracks.find((t) => t.id === videoId);
}

export function addPlaylist(playlistId: string, title: string, thumbnail: string, tracks: Array<Omit<LibraryTrack, "downloaded" | "addedAt" | "fileName" | "thumbnailFile">>): void {
  const trackIds: string[] = [];
  for (const t of tracks) {
    addTrack(t);
    trackIds.push(t.id);
  }

  const existing = library.playlists.find((p) => p.playlistId === playlistId);
  if (existing) {
    existing.title = title;
    existing.thumbnail = thumbnail;
    existing.trackIds = trackIds;
  } else {
    library.playlists.push({
      playlistId,
      title,
      thumbnail,
      trackIds,
      addedAt: Date.now(),
    });
  }

  saveLibrary();
}

export function addTrackToPlaylist(
  playlistId: string,
  track: Omit<LibraryTrack, "downloaded" | "addedAt" | "fileName" | "thumbnailFile">,
): LibraryData {
  addTrack(track);

  const playlist = library.playlists.find((p) => p.playlistId === playlistId);
  if (playlist) {
    if (!playlist.trackIds.includes(track.id)) {
      playlist.trackIds.push(track.id);
    }
    if (!playlist.thumbnail && track.thumbnail) {
      playlist.thumbnail = track.thumbnail;
    }
    saveLibrary();
  }
  return library;
}

export function removeTrackFromPlaylist(playlistId: string, trackId: string): LibraryData {
  // The track stays in the library — a playlist holds ids, and dropping the
  // id is the whole of removing it from the playlist.
  const playlist = library.playlists.find((p) => p.playlistId === playlistId);
  if (playlist) {
    const i = playlist.trackIds.indexOf(trackId);
    if (i !== -1) {
      playlist.trackIds.splice(i, 1);
      saveLibrary();
    }
  }
  return library;
}

export function createPlaylist(title: string, trackId?: string): LibraryPlaylist {
  const playlist: LibraryPlaylist = {
    playlistId: "local-" + Date.now(),
    title,
    thumbnail: "",
    trackIds: trackId ? [trackId] : [],
    addedAt: Date.now(),
  };
  library.playlists.push(playlist);
  saveLibrary();
  return playlist;
}

export function removePlaylist(playlistId: string): boolean {
  const idx = library.playlists.findIndex((p) => p.playlistId === playlistId);
  if (idx === -1) return false;
  library.playlists.splice(idx, 1);
  saveLibrary();
  return true;
}

export function renamePlaylist(playlistId: string, newTitle: string): boolean {
  const pl = library.playlists.find((p) => p.playlistId === playlistId);
  if (!pl) return false;
  pl.title = newTitle;
  saveLibrary();
  return true;
}

export function importLocalFiles(filePaths: string[]): LibraryTrack[] {
  const imported: LibraryTrack[] = [];
  for (const fp of filePaths) {
    if (!existsSync(fp)) continue;
    const ext = extname(fp);
    const name = basename(fp, ext);
    const id = `local-${randomUUID()}`;
    const destName = `${id}${ext}`;
    const dest = join(downloadPath, destName);

    try {
      copyFileSync(fp, dest);
    } catch (err) {
      console.error(`Failed to copy ${fp}:`, err);
      continue;
    }

    const entry: LibraryTrack = {
      id,
      title: name,
      channel: "Local file",
      duration: 0,
      thumbnail: "",
      downloaded: true,
      fileName: destName,
      addedAt: Date.now(),
    };
    library.tracks.push(entry);
    imported.push(entry);
  }
  if (imported.length > 0) saveLibrary();
  return imported;
}

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

/** A YouTube video id from what a person pastes: a bare id, or a watch,
 *  youtu.be, music.youtube.com, shorts, embed or live link. */
export function parseYoutubeId(input: string): string | null {
  const s = String(input ?? "").trim();
  if (!s) return null;
  if (VIDEO_ID.test(s)) return s;
  let u: URL;
  try { u = new URL(s.includes("://") ? s : `https://${s}`); } catch { return null; }
  const host = u.hostname.replace(/^(www|m)\./, "");
  if (host === "youtu.be") {
    const id = u.pathname.slice(1, 12);
    return VIDEO_ID.test(id) ? id : null;
  }
  if (host === "youtube.com" || host === "music.youtube.com") {
    const v = u.searchParams.get("v");
    if (v && VIDEO_ID.test(v)) return v;
    const m = u.pathname.match(/^\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{11})/);
    if (m) return m[1];
  }
  return null;
}

/** Link an imported file to a YouTube video, or clear the link with "". */
export function setYoutubeLink(id: string, link: string): { ok: boolean; youtubeId?: string; error?: string } {
  const t = library.tracks.find((x) => x.id === id);
  if (!t) return { ok: false, error: "not in the library" };
  if (!t.id.startsWith("local-")) return { ok: false, error: "a YouTube track is already its video" };
  if (!String(link ?? "").trim()) {
    delete t.youtubeId;
    saveLibrary();
    return { ok: true };
  }
  const y = parseYoutubeId(link);
  if (!y) return { ok: false, error: "not a YouTube link" };
  t.youtubeId = y;
  saveLibrary();
  return { ok: true, youtubeId: y };
}

const AUDIO_EXTS = new Set([".mp3", ".opus", ".ogg", ".webm", ".m4a", ".flac", ".wav"]);

/** Use a file the person chose as an entry's audio, replacing any download.
 *  The entry keeps its id, so a YouTube track still counts as its video. */
export function replaceFile(id: string, path: string): { ok: boolean; error?: string } {
  const t = library.tracks.find((x) => x.id === id);
  if (!t) return { ok: false, error: "not in the library" };
  if (!isSafeIdForPath(t.id)) return { ok: false, error: "this entry cannot hold a file" };
  if (!downloadPath) return { ok: false, error: "no download folder is set" };
  if (!existsSync(path)) return { ok: false, error: "file not found" };
  const ext = extname(path).toLowerCase();
  if (!AUDIO_EXTS.has(ext)) return { ok: false, error: "not an audio file" };
  const dest = `${t.id}${ext}`;
  const part = join(downloadPath, `${dest}.part`);
  try {
    copyFileSync(path, part);
    if (t.fileName && t.fileName !== dest && existsSync(join(downloadPath, t.fileName)))
      unlinkSync(join(downloadPath, t.fileName));
    renameSync(part, join(downloadPath, dest));
  } catch (err) {
    try { if (existsSync(part)) unlinkSync(part); } catch { /* nothing left to clean */ }
    return { ok: false, error: String((err as Error).message ?? err) };
  }
  t.fileName = dest;
  t.downloaded = true;
  saveLibrary();
  return { ok: true };
}

async function cacheThumbnail(videoId: string, thumbnailUrl: string): Promise<void> {
  // videoId reaches here from track.id, and a plugin's search result is where
  // a track can come from. It is about to be a filename.
  if (!isSafeIdForPath(videoId)) {
    process.stderr.write(`[library] refusing to cache a thumbnail under an unsafe id\n`);
    return;
  }
  const thumbDir = join(downloadPath, "thumbs");
  mkdirSync(thumbDir, { recursive: true });

  // Check if already cached (any extension)
  const existing = ["jpg", "webp", "png"].find((ext) =>
    existsSync(join(thumbDir, `${videoId}.${ext}`)),
  );
  if (existing) {
    const track = library.tracks.find((t) => t.id === videoId);
    if (track && !track.thumbnailFile) {
      track.thumbnailFile = `${videoId}.${existing}`;
      saveLibrary();
    }
    return;
  }

  try {
    const response = await fetch(thumbnailUrl);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const buf = Buffer.from(await response.arrayBuffer());

    // Detect actual format from magic bytes
    let ext = "jpg";
    if (buf.length >= 12 && buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") {
      ext = "webp";
    } else if (buf.length >= 8 && buf[0] === 0x89 && buf.toString("ascii", 1, 4) === "PNG") {
      ext = "png";
    }

    const fileName = `${videoId}.${ext}`;
    writeFileSync(join(thumbDir, fileName), buf);

    const track = library.tracks.find((t) => t.id === videoId);
    if (track) {
      track.thumbnailFile = fileName;
      saveLibrary();
    }
  } catch (err) {
    console.error(`Failed to cache thumbnail for ${videoId}:`, err);
  }
}

export function updateTrackMetadata(videoId: string, metadata: TrackMetadata | null): boolean {
  const track = library.tracks.find((t) => t.id === videoId);
  if (!track) return false;
  if (metadata === null) {
    delete track.metadata;
  } else {
    track.metadata = metadata;
  }
  saveLibrary();
  return true;
}

/** Copy a user-picked local image into albumart/. */
export function importAlbumArtFile(videoId: string, srcPath: string): string | null {
  try {
    const artDir = join(downloadPath, "albumart");
    mkdirSync(artDir, { recursive: true });
    const ext = (extname(srcPath) || ".jpg").toLowerCase();
    const fileName = `custom-${videoId}${ext}`;
    copyFileSync(srcPath, join(artDir, fileName));
    return fileName;
  } catch {
    return null;
  }
}

export async function cacheAlbumArt(videoId: string, artUrl: string): Promise<string | null> {
  const artDir = join(downloadPath, "albumart");
  mkdirSync(artDir, { recursive: true });

  const existing = ["jpg", "webp", "png"].find((ext) =>
    existsSync(join(artDir, `${videoId}.${ext}`)),
  );
  if (existing) return `${videoId}.${existing}`;

  try {
    const response = await fetch(artUrl);
    if (!response.ok) return null;
    const buf = Buffer.from(await response.arrayBuffer());

    // Detect format from magic bytes
    let ext = "jpg";
    if (buf.length >= 12 && buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") {
      ext = "webp";
    } else if (buf.length >= 8 && buf[0] === 0x89 && buf.toString("ascii", 1, 4) === "PNG") {
      ext = "png";
    }

    const fileName = `${videoId}.${ext}`;
    writeFileSync(join(artDir, fileName), buf);
    return fileName;
  } catch (err) {
    console.error(`Failed to cache album art for ${videoId}:`, err);
    return null;
  }
}

