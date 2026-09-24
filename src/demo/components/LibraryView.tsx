import { useState, useMemo } from "react";
import LayoutToggle from "./LayoutToggle";
import { Icon } from "../icons";
import { demoLibrary } from "../demoLibrary";
import type { SearchResult } from "../api/types";

function formatDuration(seconds: number): string {
  if (!seconds) return "";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function startTextScroll(e: React.MouseEvent<HTMLSpanElement>) {
  const el = e.currentTarget;
  const overflow = el.scrollWidth - el.clientWidth;
  if (overflow <= 1) return;
  el.style.setProperty("--scroll-dist", `-${overflow + 8}px`);
  el.style.setProperty("--scroll-duration", `${Math.max(4, overflow / 30)}s`);
  el.classList.add("scrolling");
}

function stopTextScroll(e: React.MouseEvent<HTMLSpanElement>) {
  e.currentTarget.classList.remove("scrolling");
}

type SortKey = "addedAt" | "title" | "channel" | "duration";

export default function LibraryView({
  onPlay,
  onAddToQueue: _onAddToQueue,
  onTrackContextMenu,
  activeId,
  layout,
  onChangeLayout,
}: {
  onPlay: (track: SearchResult) => void;
  onAddToQueue?: (track: SearchResult) => void;
  onTrackContextMenu: (track: SearchResult, e: React.MouseEvent) => void;
  activeId: string | null;
  layout: "list" | "grid" | "compact";
  onChangeLayout: (mode: "list" | "grid" | "compact") => void;
}) {
  const library = demoLibrary;
  const [sortKey, setSortKey] = useState<SortKey>("addedAt");
  const [sortAsc, setSortAsc] = useState(false);
  const [expandedPlaylist, setExpandedPlaylist] = useState<string | null>(null);
  const [expandedAlbum, setExpandedAlbum] = useState<string | null>(null);
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(new Set());

  const toggleSection = (section: string) => {
    setCollapsedSections((prev) => {
      const next = new Set(prev);
      if (next.has(section)) next.delete(section);
      else next.add(section);
      return next;
    });
  };

  const trackMap = useMemo(() => {
    const m = new Map<string, LibraryTrack>();
    for (const t of library.tracks) m.set(t.id, t);
    return m;
  }, [library.tracks]);

  const filteredTracks = useMemo(() => {
    const tracks = [...library.tracks];
    tracks.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case "addedAt": cmp = a.addedAt - b.addedAt; break;
        case "title": cmp = (b.metadata?.cleanTitle || b.title).localeCompare(a.metadata?.cleanTitle || a.title); break;
        case "channel": cmp = (b.metadata?.artist || b.channel).localeCompare(a.metadata?.artist || a.channel); break;
        case "duration": cmp = b.duration - a.duration; break;
      }
      return sortAsc ? cmp : -cmp;
    });
    return tracks;
  }, [library.tracks, sortKey, sortAsc]);

  const filteredPlaylists = useMemo(() => {
    const pls = [...library.playlists];
    const dir = sortAsc ? 1 : -1;
    pls.sort((a, b) => {
      switch (sortKey) {
        case "title": return b.title.localeCompare(a.title) * dir;
        case "addedAt": return (a.addedAt - b.addedAt) * dir;
        case "channel": return b.title.localeCompare(a.title) * dir;
        case "duration": {
          const aDur = a.trackIds.reduce((s, id) => s + (trackMap.get(id)?.duration || 0), 0);
          const bDur = b.trackIds.reduce((s, id) => s + (trackMap.get(id)?.duration || 0), 0);
          return (bDur - aDur) * dir;
        }
      }
    });
    return pls;
  }, [library.playlists, sortKey, sortAsc, trackMap]);

  // Album grouping
  const albumGroups = useMemo(() => {
    const groups = new Map<string, LibraryTrack[]>();
    for (const t of filteredTracks) {
      if (!t.metadata?.album) continue;
      const album = t.metadata.album;
      if (!groups.has(album)) groups.set(album, []);
      groups.get(album)!.push(t);
    }
    const result = Array.from(groups.entries()).map(([album, tracks]) => ({
      album,
      tracks,
      artist: tracks[0]?.metadata?.artist || tracks[0]?.channel || "",
      art: tracks[0].thumbnail,
      addedAt: Math.max(...tracks.map((t) => t.addedAt)),
      totalDuration: tracks.reduce((s, t) => s + t.duration, 0),
    }));
    const dir = sortAsc ? 1 : -1;
    result.sort((a, b) => {
      switch (sortKey) {
        case "title": return b.album.localeCompare(a.album) * dir;
        case "channel": return b.artist.localeCompare(a.artist) * dir;
        case "addedAt": return (a.addedAt - b.addedAt) * dir;
        case "duration": return (b.totalDuration - a.totalDuration) * dir;
      }
    });
    return result;
  }, [filteredTracks, sortKey, sortAsc]);

  const toSearchResult = (t: LibraryTrack): SearchResult => ({
    id: t.id,
    title: t.metadata?.cleanTitle || t.title,
    channel: t.metadata?.artist || t.channel,
    duration: t.duration,
    thumbnail: t.thumbnail,
  });

  const handleSort = (key: SortKey) => {
    if (sortKey === key) setSortAsc((a) => !a);
    else { setSortKey(key); setSortAsc(false); }
  };

  const displayTitle = (t: LibraryTrack) => t.metadata?.cleanTitle || t.title;
  const displayArtist = (t: LibraryTrack) => t.metadata?.artist || t.channel;

  const hasPlaylists = filteredPlaylists.length > 0;
  const hasAlbums = albumGroups.length > 0;
  const hasSections = hasPlaylists || hasAlbums;

  const downloadedCount = library.tracks.filter((t) => t.downloaded).length;
  const totalCount = library.tracks.length;

  return (
    <div className="library-view">
      <div className="library-header">
        <div className="library-header-top">
          <h2 className="library-title">Library</h2>
          <span className="library-stats">{downloadedCount}/{totalCount} downloaded</span>
        </div>
        <div className="library-sort-bar">
          {(["addedAt", "title", "channel", "duration"] as SortKey[]).map((key) => (
            <button
              key={key}
              className={`library-sort-btn${sortKey === key ? " active" : ""}`}
              onClick={() => handleSort(key)}
            >
              {key === "addedAt" ? "Date" : key === "channel" ? "Artist" : key.charAt(0).toUpperCase() + key.slice(1)}
              {sortKey === key && <>{" "}<Icon name={sortAsc ? "sortAsc" : "sortDesc"} size={8} /></>}
            </button>
          ))}
          <LayoutToggle layout={layout} onChange={onChangeLayout} />
        </div>
      </div>

      {/* Playlists section */}
      {hasPlaylists && (
        <div className="library-playlists">
          <div
            className="library-section-title library-section-collapsible"
            onClick={() => toggleSection("playlists")}
          >
            <span>Playlists</span>
            <span className="library-expand-icon">{collapsedSections.has("playlists") ? <Icon name="chevronRight" size={10} /> : <Icon name="chevronDown" size={10} />}</span>
          </div>
          {!collapsedSections.has("playlists") && (
            layout === "grid" ? (
              <div className="library-grid">
                {filteredPlaylists.map((pl) => {
                  const plTracks = pl.trackIds.map((id) => trackMap.get(id)).filter((t): t is LibraryTrack => !!t);
                  return (
                    <div
                      key={pl.playlistId}
                      className="library-grid-item"
                      onClick={() => setExpandedPlaylist(expandedPlaylist === pl.playlistId ? null : pl.playlistId)}
                    >
                      {pl.thumbnail && (
                        <img className="library-grid-thumb" src={pl.thumbnail} alt="" loading="lazy" />
                      )}
                      <div className="library-grid-info">
                        <div className="library-grid-title">{pl.title}</div>
                        <div className="library-grid-meta">{plTracks.length} tracks</div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              filteredPlaylists.map((pl) => {
                const expanded = expandedPlaylist === pl.playlistId;
                const plTracks = pl.trackIds.map((id) => trackMap.get(id)).filter((t): t is LibraryTrack => !!t);
                return (
                  <div key={pl.playlistId} className={`library-playlist-card${layout === "compact" ? " library-playlist-card-compact" : ""}`}>
                    <div
                      className="library-playlist-header"
                      onClick={() => setExpandedPlaylist(expanded ? null : pl.playlistId)}
                    >
                      {layout !== "compact" && pl.thumbnail && (
                        <img className="library-playlist-thumb" src={pl.thumbnail} alt="" loading="lazy" />
                      )}
                      <div className="library-playlist-info">
                        <span className="library-playlist-name">{pl.title}</span>
                        <span className="library-playlist-meta">{plTracks.length} tracks</span>
                      </div>
                      <span className="library-expand-icon">{expanded ? <Icon name="chevronDown" size={10} /> : <Icon name="chevronRight" size={10} />}</span>
                    </div>
                    {expanded && (
                      <ul className={`track-list library-playlist-tracks${layout === "compact" ? " track-list-compact" : ""}`}>
                        {plTracks.map((t, i) => {
                          const sr = toSearchResult(t);
                          return (
                            <li
                              key={`${t.id}-${i}`}
                              className={`track-item${t.id === activeId ? " active" : ""}`}
                              onClick={() => onPlay(sr)}
                              onContextMenu={(e) => onTrackContextMenu(sr, e)}
                            >
                              <span className="track-index">{i + 1}</span>
                              <img className="track-thumb" src={sr.thumbnail} alt="" loading="lazy" />
                              <div className="track-info">
                                <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{displayTitle(t)}</span>
                                <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
                                  {displayArtist(t)}
                                  {t.duration > 0 && ` \u00B7 ${formatDuration(t.duration)}`}
                                </span>
                              </div>
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                );
              })
            )
          )}
        </div>
      )}

      {/* Albums section */}
      {hasAlbums && (
        <div className="library-playlists">
          <div
            className="library-section-title library-section-collapsible"
            onClick={() => toggleSection("albums")}
          >
            <span>Albums</span>
            <span className="library-expand-icon">{collapsedSections.has("albums") ? <Icon name="chevronRight" size={10} /> : <Icon name="chevronDown" size={10} />}</span>
          </div>
          {!collapsedSections.has("albums") && (
            layout === "grid" ? (
              <div className="library-grid">
                {albumGroups.map(({ album, tracks, artist, art }) => (
                  <div
                    key={album}
                    className={`library-grid-item${expandedAlbum === album ? " active" : ""}`}
                    onClick={() => setExpandedAlbum(expandedAlbum === album ? null : album)}
                  >
                    <img className="library-grid-thumb" src={art} alt="" loading="lazy" />
                    <div className="library-grid-info">
                      <div className="library-grid-title">{album}</div>
                      <div className="library-grid-meta">{artist} &middot; {tracks.length} tracks</div>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              albumGroups.map(({ album, tracks, artist, art }) => {
                const expanded = expandedAlbum === album;
                return (
                  <div key={album} className={`library-playlist-card${layout === "compact" ? " library-playlist-card-compact" : ""}`}>
                    <div
                      className="library-playlist-header"
                      onClick={() => setExpandedAlbum(expanded ? null : album)}
                    >
                      {layout !== "compact" && (
                        <img className="library-playlist-thumb" src={art} alt="" loading="lazy" />
                      )}
                      <div className="library-playlist-info">
                        <span className="library-playlist-name">{album}</span>
                        <span className="library-playlist-meta">{artist} &middot; {tracks.length} tracks</span>
                      </div>
                      <span className="library-expand-icon">{expanded ? <Icon name="chevronDown" size={10} /> : <Icon name="chevronRight" size={10} />}</span>
                    </div>
                    {expanded && (
                      <ul className={`track-list library-playlist-tracks${layout === "compact" ? " track-list-compact" : ""}`}>
                        {tracks.map((t, i) => {
                          const sr = toSearchResult(t);
                          return (
                            <li
                              key={`${t.id}-${i}`}
                              className={`track-item${t.id === activeId ? " active" : ""}`}
                              onClick={() => onPlay(sr)}
                              onContextMenu={(e) => onTrackContextMenu(sr, e)}
                            >
                              <span className="track-index">{i + 1}</span>
                              <img className="track-thumb" src={sr.thumbnail} alt="" loading="lazy" />
                              <div className="track-info">
                                <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{displayTitle(t)}</span>
                                <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
                                  {displayArtist(t)}
                                  {t.duration > 0 && ` \u00B7 ${formatDuration(t.duration)}`}
                                </span>
                              </div>
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                );
              })
            )
          )}
        </div>
      )}

      {/* All Tracks section */}
      {filteredTracks.length > 0 && (
        <>
          {hasSections && (
            <div
              className="library-section-title library-section-collapsible"
              onClick={() => toggleSection("tracks")}
            >
              <span>All Tracks</span>
              <span className="library-expand-icon">{collapsedSections.has("tracks") ? <Icon name="chevronRight" size={10} /> : <Icon name="chevronDown" size={10} />}</span>
            </div>
          )}
          {!collapsedSections.has("tracks") && (
            layout === "grid" ? (
              <div className="library-grid">
                {filteredTracks.map((t) => {
                  const sr = toSearchResult(t);
                  return (
                    <div
                      key={t.id}
                      className={`library-grid-item${t.id === activeId ? " active" : ""}`}
                      onClick={() => onPlay(sr)}
                      onContextMenu={(e) => onTrackContextMenu(sr, e)}
                    >
                      <img className="library-grid-thumb" src={sr.thumbnail} alt="" loading="lazy" />
                      <div className="library-grid-info">
                        <div className="library-grid-title">{displayTitle(t)}</div>
                        <div className="library-grid-meta">
                          {displayArtist(t)}
                          {t.duration > 0 && ` \u00B7 ${formatDuration(t.duration)}`}
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <ul className={`track-list${layout === "compact" ? " track-list-compact" : ""}`}>
                {filteredTracks.map((t) => {
                  const sr = toSearchResult(t);
                  return (
                    <li
                      key={t.id}
                      className={`track-item${t.id === activeId ? " active" : ""}`}
                      onClick={() => onPlay(sr)}
                      onContextMenu={(e) => onTrackContextMenu(sr, e)}
                    >
                      <img className="track-thumb" src={sr.thumbnail} alt="" loading="lazy" />
                      <div className="track-info">
                        <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{displayTitle(t)}</span>
                        <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
                          {displayArtist(t)}
                          {t.metadata?.album && ` \u00B7 ${t.metadata.album}`}
                          {t.metadata?.year && ` \u00B7 ${t.metadata.year}`}
                        </span>
                      </div>
                    </li>
                  );
                })}
              </ul>
            )
          )}
        </>
      )}

      {filteredTracks.length === 0 && filteredPlaylists.length === 0 && (
        <div className="library-empty">Your library is empty.</div>
      )}
    </div>
  );
}
