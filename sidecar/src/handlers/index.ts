// RPC method registry: thin adapters over the sidecar modules.
import { method, notify, RpcError, log } from "../rpc";
import { loadSettings, saveSettings, touchesCookieIdentity, autoTagEnabled, tagServicesOf } from "../settings";
import { installedBrowsers } from "../browsers";
import * as it from "../innertube";
import * as st from "../streams";
import * as lib from "../library";
import * as meta from "../metadata";
import * as ly from "../lyrics";
import * as wt from "../watchtime";
import * as gc from "../guest-cookies";
import { detectSilence, getCachedSilence, forgetSilence } from "../silence";
import { updateNow } from "../ytdlp";
import { LOCALES, REGIONS } from "../locales";
import * as plug from "../plugins/manager";
import { pluginSettings, setPluginSetting } from "../plugins/settings-store";
import { EMPTY_GRANTS } from "../plugins/permissions";

const ck = () => {
  const s = loadSettings();
  return [s.cookieSource, s.browser, s.cookieProfile] as const;
};

let jobSeq = 0;
const jobId = (prefix: string) => `${prefix}-${++jobSeq}`;

// Tag one track: the auto-tag button and adding a track with auto-tag on share
// this body. "heuristic" is the local title cleanup alone; anything else is the
// Last.fm / MusicBrainz / Deezer chain with the heuristic as fallback. Tracks
// edited by hand are left alone. True when the track was tagged.
async function enrichTrack(track: any, mode: string, s: ReturnType<typeof loadSettings>): Promise<boolean> {
  if (track.metadata?.source === "manual") return false;
  const heuristic = meta.suggestMetadata(track.title, track.channel);
  if (mode === "heuristic") {
    if (!heuristic.artist && !heuristic.cleanTitle) return false;
    lib.updateTrackMetadata(track.id, heuristic);
    return true;
  }
  const artist = heuristic.artist || track.channel;
  const title = heuristic.cleanTitle || track.title;
  const cleanChannel = track.channel.replace(/\s*-\s*Topic$/, "");
  const rawChannel = artist !== cleanChannel ? cleanChannel : undefined;
  const result = await meta.lookupMetadata(artist, title, s.lastfmApiKey || undefined, rawChannel, tagServicesOf(s));
  if (result) {
    if (result.albumArt) {
      let artFile = await lib.cacheAlbumArt(track.id, result.albumArt);
      if (!artFile && result.source) {
        const altUrl = await meta.lookupAlbumArt(artist, title, s.lastfmApiKey || undefined, result.source, tagServicesOf(s));
        if (altUrl) {
          artFile = await lib.cacheAlbumArt(track.id, altUrl);
          if (artFile) result.albumArt = altUrl;
        }
      }
      if (artFile) result.albumArtFile = artFile;
    }
    lib.updateTrackMetadata(track.id, result);
    return true;
  }
  if (!heuristic.artist && !heuristic.cleanTitle) return false;
  lib.updateTrackMetadata(track.id, heuristic);   // api+heuristic fallback
  return true;
}

export function registerHandlers(): void {
  // --- YouTube data ---
  method("yt/search", ({ query, filters }) => it.fetchSearch(query, ...ck(), filters));
  method("yt/searchContinuation", ({ token }) => it.fetchSearchContinuation(token, ...ck()));
  // a mood chip's params open that mood's home; none is the plain home
  method("yt/getHome", (p: any) => it.fetchMusicHome(...ck(), p?.params || undefined));
  method("yt/homeContinuation", ({ token }) => it.fetchMusicHomeContinuation(token, ...ck()));
  method("yt/getRecommended", async ({ count }) => {
    const [tracks, chips] = await Promise.all([
      st.fetchRecommendedTracks(count ?? 30),
      it.fetchRecommendedChips(...ck()).catch(() => []),
    ]);
    return { tracks, chips };
  });
  method("yt/getRecommendedByChip", ({ token, count }) => it.fetchRecommendedByChip(token, ...ck(), count ?? 30));
  method("yt/recommendedContinuation", ({ token }) => it.fetchRecommendedContinuation(token, ...ck()));
  method("yt/getNext", ({ videoId }) => it.fetchNext(videoId, ...ck()));
  method("yt/nextContinuation", ({ token }) => it.fetchNextContinuation(token, ...ck()));
  method("yt/getStream", ({ videoId }) => st.fetchStreamUrl(videoId));
  method("lyrics/get", ({ videoId, artist, title, album, duration }) =>
    ly.getLyrics({ videoId, artist, title, album, duration,
                   allowAuto: loadSettings().lyricsAutoCaptions === true }));
  method("yt/getPlaylistTracks", ({ playlistId }) => st.fetchPlaylistTracks(playlistId));
  // scroll pagination: cursor comes from getPlaylistTracks, "" when exhausted
  method("yt/getPlaylistMore", ({ cursor, count }) => st.moreList(cursor, count ?? 60));

  // --- Radio ---
  method("radio/start", ({ playlistId, startIndex }) => st.startSongRadio(playlistId, startIndex));
  method("radio/next", () => st.nextRadioTrack());
  method("radio/nextBatch", ({ count }) => st.nextRadioBatch(count ?? 20));

  // --- Playback reporting ---
  method("report/playback", ({ videoId, duration }) => wt.reportPlayback(videoId, duration, ...ck()).then((cpn) => ({ cpn })));
  method("report/delayplay", ({ videoId, cpn, duration }) => wt.reportDelayplay(videoId, cpn, duration, ...ck()));
  method("report/watchtime", ({ videoId, cpn, st: s, et, duration }) => wt.reportWatchtime(videoId, cpn, s, et, duration, ...ck()));

  // --- Library ---
  method("library/get", () => lib.getLibrary());
  method("library/addTrack", ({ track, download }) => {
    const added = lib.addTrack(track, false);
    notify("library/changed", {});
    // Auto-tag new tracks in the background, so adding stays instant; only a
    // track with no tags yet, so adding one again never overwrites tags (a
    // hand edit included).
    const s = loadSettings();
    if (autoTagEnabled(s.metadataAutoEnrich) && !added.metadata) {
      enrichTrack(added, "api", s)
        .then((tagged) => { if (tagged) notify("library/changed", {}); })
        .catch((e) => log("[autotag]", String(e)));
    }
    if (download) {
      const id = jobId("dl");
      // NB: library tracks key on `id` (SearchResult shape), not videoId
      lib.downloadTrack(track.id, st.cookieArgs).then((ok) => {
        notify("job/done", { jobId: id, ok, result: { videoId: track.id } });
        notify("library/changed", {});
      });
      return { track: added, jobId: id };
    }
    return { track: added };
  });
  method("library/removeTrack", ({ videoId, deleteFile }) => {
    const ok = lib.removeTrack(videoId, !!deleteFile);
    notify("library/changed", {});
    return { ok };
  });
  method("library/downloadTrack", ({ videoId }) => {
    const id = jobId("dl");
    lib.downloadTrack(videoId, st.cookieArgs).then((ok) => {
      notify("job/done", { jobId: id, ok, result: { videoId } });
      notify("library/changed", {});
    });
    return { jobId: id };
  });
  method("library/downloadAll", ({ trackIds }) => {
    const data = lib.getLibrary();
    const ids = ((trackIds && trackIds.length ? trackIds : data.tracks.map((t) => t.id)) as string[])
      .filter((vid) => data.tracks.some((t) => t.id === vid && !t.downloaded));
    const id = jobId("dlall");
    for (const vid of ids) {
      lib.downloadTrack(vid, st.cookieArgs).then((ok) => {
        notify("job/done", { jobId: id + ":" + vid, ok, result: { videoId: vid } });
        notify("library/changed", {});
      });
    }
    return { jobId: id, count: ids.length };
  });
  method("library/addPlaylist", ({ playlistId, title, thumbnail, tracks }) => {
    lib.addPlaylist(playlistId, title, thumbnail, tracks);
    notify("library/changed", {});
  });
  method("library/removePlaylist", ({ playlistId }) => {
    const ok = lib.removePlaylist(playlistId);
    notify("library/changed", {});
    return { ok };
  });
  method("library/renamePlaylist", ({ playlistId, title }) => {
    const ok = lib.renamePlaylist(playlistId, title);
    notify("library/changed", {});
    return { ok };
  });
  method("library/addTrackToPlaylist", ({ playlistId, track }) => {
    lib.addTrackToPlaylist(playlistId, track);
    notify("library/changed", {});
  });
  method("library/removeTrackFromPlaylist", ({ playlistId, trackId }) => {
    lib.removeTrackFromPlaylist(playlistId, trackId);
    notify("library/changed", {});
  });
  method("library/createPlaylist", ({ title, trackId }) => lib.createPlaylist(title, trackId));
  method("library/setYoutubeLink", ({ videoId, link }) => {
    const r = lib.setYoutubeLink(videoId, link);
    if (r.ok) notify("library/changed", {});
    return r;
  });
  method("library/replaceFile", ({ videoId, path }) => {
    const r = lib.replaceFile(videoId, path);
    if (r.ok) { forgetSilence(videoId); notify("library/changed", {}); }
    return r;
  });
  method("library/importFiles", ({ paths }) => {
    const tracks = lib.importLocalFiles(paths);
    notify("library/changed", {});
    return { tracks };
  });

  // --- Metadata ---
  method("metadata/get", ({ videoId }) => lib.getTrackMetadata(videoId) ?? null);
  method("metadata/save", ({ videoId, metadata }) => {
    const ok = lib.updateTrackMetadata(videoId, metadata);
    notify("library/changed", {});
    return { ok };
  });
  method("metadata/lookup", async ({ artist, title, rawArtist }) => {
    // Full chain (Last.fm -> MusicBrainz -> Deezer,
    // instrumental handling, raw-artist retry, title-only fallback)
    const s = loadSettings();
    const result = await meta.lookupMetadata(artist, title, s.lastfmApiKey || undefined, rawArtist, tagServicesOf(s));
    if (!result) return { ok: false, error: "No results found" };
    return { ok: true, result };
  });
  method("metadata/importArtFile", ({ videoId, path }) => {
    const artFile = lib.importAlbumArtFile(videoId, path);
    return artFile ? { ok: true, artFile } : { ok: false };
  });
  method("metadata/suggest", ({ title, channel }) => meta.suggestMetadata(title, channel));
  method("metadata/cacheAlbumArt", ({ videoId, artUrl }) => lib.cacheAlbumArt(videoId, artUrl).then((path) => ({ path })));
  // Tag every non-manual track; "heuristic"
  // = local cleanup only, "api+heuristic" = Last.fm/MusicBrainz/Deezer chain
  // with heuristic fallback. Skips manually-edited tracks.
  method("metadata/batchEnrich", async ({ mode }) => {
    const data = lib.getLibrary();
    const s = loadSettings();
    let count = 0;
    for (const track of data.tracks)
      if (await enrichTrack(track, mode, s)) count++;
    if (count) notify("library/changed", {});
    return { count };
  });

  // --- Cookies ---
  // Whether the session is signed in, asked of whatever identity is current,
  // so an empty home can say which of its several causes this one is.
  method("cookies/status", async (p: any) => {
    // the current identity unless the caller names another: the account menu
    // asks about every installed browser, not only the one in use
    const [cs, cb, cp] = ck();
    const source = p?.source ?? cs, browser = p?.browser ?? cb, profile = p?.profile ?? cp;
    // asked fresh when a menu opens or melo returns to the front: the browser's
    // login may have changed since it was read
    if (p?.fresh && source === "browser") it.forgetBrowser(browser);
    let cookies: Awaited<ReturnType<typeof it.resolveCookies>> = [];
    try { cookies = await it.resolveCookies(source, browser, profile); } catch { /* none is an answer */ }
    const hasCookie = it.hasAuthCookie(cookies);
    let account: Awaited<ReturnType<typeof it.fetchAccountInfo>> = null;
    let answered = false;
    if (hasCookie) {
      try { account = await it.fetchAccountInfo(source, browser, profile); answered = true; }
      catch { /* YouTube not reached: the cookie decides */ }
    }
    const signedIn = it.signedInFrom(hasCookie, { answered, account });
    return {
      signedIn, account: signedIn ? account : null,
      // what a request to youtube.com actually carries
      cookieCount: it.cookiesForHost(cookies, "www.youtube.com").length,
      source, browser, profile,
    };
  });
  method("cookies/browsers", () => ({ browsers: installedBrowsers() }));
  method("cookies/profiles", () => ({ profiles: gc.listProfiles() }));
  method("cookies/import", ({ browser, profile }) => gc.importBrowserCookies(browser, profile).then((count) => ({ count })));
  method("cookies/resetGuest", ({ profile }) => gc.resetGuestSession(profile));
  method("cookies/create", ({ name }) => gc.createProfile(name));
  method("cookies/delete", ({ name }) => gc.deleteProfile(name));
  method("cookies/rename", ({ oldName, newName }) => gc.renameProfile(oldName, newName));

  // --- Audio analysis ---
  method("audio/detectSilence", ({ source, duration, thresholdDb, scanStart, scanEnd, videoId }) => {
    if (videoId) {
      const cached = getCachedSilence(videoId);
      if (cached) return cached;
    }
    return detectSilence(source, duration, thresholdDb ?? -40, scanStart ?? 15, scanEnd ?? 15, videoId);
  });

  // --- Settings ---
  method("settings/get", () => loadSettings());
  // the picker reads the list from here so it can never offer a code that
  // localePref() would reject
  method("settings/locales", () => ({ locales: LOCALES, regions: REGIONS() }));
  // user accepted the nightly prompt: switch channel and pull it now
  method("ytdlp/setChannel", async ({ channel }) => {
    saveSettings({ ytdlpChannel: channel === "nightly" ? "nightly" : "stable" });
    return { ok: await updateNow(channel === "nightly" ? "nightly" : "stable") };
  });
  method("settings/set", ({ patch, removeUi }) => {
    const saved = saveSettings(patch, Array.isArray(removeUi) ? removeUi : []);
    // Every identity switch passes through here — the title bar's account menu
    // and the settings window's profile picker alike — so the caches are
    // dropped once, here, rather than at each call site that could forget.
    if (touchesCookieIdentity(patch ?? {})) it.clearCookieCache();
    return saved;
  });

  // ---- plugins ----
  method("plugins/list", () => ({ plugins: plug.listPlugins() }));
  method("plugins/setEnabled", ({ id, on }) => {
    const s = loadSettings();
    const plugins = plug.setPluginEnabled(id, on);
    const listed = plugins.find((p) => p.id === id);
    const enabled = { ...(s.plugins?.enabled ?? {}), [id]: on };
    saveSettings({ plugins: { ...(s.plugins ?? { enabled: {} }), enabled,
      grants: listed
        ? { ...(s.plugins?.grants ?? {}), [id]: listed.grants }
        : (s.plugins?.grants ?? {}) } });
    return { plugins };
  });
  method("plugins/setGrants", ({ id, grants }) => {
    const s = loadSettings();
    // persist the sanitized grants from the manager, not the raw patch
    const plugins = plug.setPluginGrants(id, grants);
    const listed = plugins.find((p) => p.id === id);
    saveSettings({ plugins: { ...(s.plugins ?? { enabled: {} }),
      grants: { ...(s.plugins?.grants ?? {}), [id]: listed?.grants ?? EMPTY_GRANTS } } });
    return { plugins };
  });
  method("plugins/rescan", () => ({ plugins: plug.rescanPlugins() }));
  method("plugins/sources", () => ({ sources: plug.sourceList() }));
  // The schema comes from the loaded manifest, never from the caller — an
  // unknown plugin id gets an empty value bag rather than free-form storage.
  method("plugins/getSettings", ({ id }) => {
    const p = plug.listPlugins().find((x) => x.id === id);
    return { values: p ? pluginSettings(id, p.settings) : {} };
  });
  // Options for a `file` field. The folder and the extension filter come from
  // the manifest; the caller only names which field it is asking about.
  method("plugins/settingFiles", ({ id, key }) => ({ files: plug.pluginSettingFiles(id, key) }));
  method("plugins/setSetting", ({ id, key, value }) => {
    const p = plug.listPlugins().find((x) => x.id === id);
    return { values: p ? setPluginSetting(id, p.settings, key, value) : {} };
  });
  method("plugin/search", ({ sourceId, query, continuation }) => plug.pluginSearch(sourceId, query, continuation));
  // wrap in the { ok, ... } envelope onStreamResolved expects (parity with
  // yt/getStream); a plugin failure rejects and surfaces via RpcCall::failed
  method("plugin/resolveStream", async ({ sourceId, trackId }) =>
    ({ ok: true, ...(await plug.pluginResolveStream(sourceId, trackId)) }));
  method("player/event", ({ type, payload }) => { plug.dispatchPlayerEvent(type, payload); return {}; });
}
