import React, { useRef, useEffect } from "react";
import LayoutToggle from "./LayoutToggle";

function startTextScroll(e: React.MouseEvent<HTMLSpanElement>) {
  const el = e.currentTarget;
  let overflow = el.scrollWidth - el.clientWidth;
  if (overflow <= 1) return;
  el.style.setProperty("--scroll-dist", `-${overflow + 8}px`);
  el.style.setProperty("--scroll-duration", `${Math.max(4, overflow / 30)}s`);
  el.classList.add("scrolling");
  const newOverflow = el.scrollWidth - el.clientWidth;
  if (newOverflow <= 1) {
    el.style.setProperty("--scroll-dist", "0px");
    el.style.setProperty("--scroll-duration", "0s");
  } else if (newOverflow !== overflow) {
    el.style.setProperty("--scroll-dist", `-${newOverflow + 8}px`);
    el.style.setProperty("--scroll-duration", `${Math.max(4, newOverflow / 30)}s`);
  }
}

function stopTextScroll(e: React.MouseEvent<HTMLSpanElement>) {
  e.currentTarget.classList.remove("scrolling");
}

function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export default function TrackList({
  results,
  playlists,
  onSelect,
  onSelectPlaylist,
  onTrackContextMenu,
  onPlaylistContextMenu: _onPlaylistContextMenu,
  activeId,
  onLoadMore,
  loadingMore,
  layout,
  onChangeLayout,
}: {
  results: SearchResult[];
  playlists: SearchPlaylistResult[];
  onSelect: (result: SearchResult) => void;
  onSelectPlaylist: (playlistId: string, title: string) => void;
  onTrackContextMenu: (track: SearchResult, e: React.MouseEvent) => void;
  onPlaylistContextMenu?: (playlistId: string, title: string, thumbnail: string, tracks: SearchResult[], e: React.MouseEvent) => void;
  activeId: string | null;
  onLoadMore?: () => void;
  loadingMore?: boolean;
  layout: "list" | "grid" | "compact";
  onChangeLayout: (mode: "list" | "grid" | "compact") => void;
}) {
  const sentinelRef = useRef<HTMLDivElement>(null);
  const loadingRef = useRef(false);

  // Track loadingMore in a ref to avoid re-creating the observer
  useEffect(() => {
    loadingRef.current = !!loadingMore;
  }, [loadingMore]);

  const onLoadMoreRef = useRef(onLoadMore);
  useEffect(() => {
    onLoadMoreRef.current = onLoadMore;
  }, [onLoadMore]);

  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting && onLoadMoreRef.current && !loadingRef.current) {
          onLoadMoreRef.current();
        }
      },
      { rootMargin: "200px" },
    );

    observer.observe(sentinel);
    return () => observer.disconnect();
  }, []);

  if (results.length === 0 && playlists.length === 0) return null;

  const playlistItems = playlists.map((p) => (
    <li
      key={`pl-${p.playlistId}`}
      className="track-item track-item-playlist"
      onClick={() => onSelectPlaylist(p.playlistId, p.title)}
    >
      <div className="track-thumb-wrap">
        <img
          className="track-thumb"
          src={p.thumbnail}
          alt=""
          loading="lazy"
        />
        <span className="track-thumb-badge">{p.videoCount} videos</span>
      </div>
      <div className="track-info">
        <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{p.title}</span>
        <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
          {p.channel} · Playlist
        </span>
      </div>
    </li>
  ));

  return (
    <>
      <div className="search-layout-bar">
        <LayoutToggle layout={layout} onChange={onChangeLayout} />
      </div>

      {layout === "grid" ? (
        <div className="library-grid">
          {playlists.map((p) => (
            <div
              key={`pl-${p.playlistId}`}
              className="library-grid-item"
              onClick={() => onSelectPlaylist(p.playlistId, p.title)}
            >
              <img className="library-grid-thumb" src={p.thumbnail} alt="" loading="lazy" />
              <span className="track-thumb-badge">{p.videoCount} videos</span>
              <div className="library-grid-info">
                <div className="library-grid-title">{p.title}</div>
                <div className="library-grid-meta">{p.channel} · Playlist</div>
              </div>
            </div>
          ))}
          {results.map((r) => (
            <div
              key={r.id}
              className={`library-grid-item${r.id === activeId ? " active" : ""}`}
              onClick={() => onSelect(r)}
              onContextMenu={(e) => onTrackContextMenu(r, e)}
            >
              <img className="library-grid-thumb" src={r.thumbnail} alt="" loading="lazy" />
              <div className="library-grid-info">
                <div className="library-grid-title">{r.title}</div>
                <div className="library-grid-meta">
                  {r.channel}
                  {r.duration > 0 && ` · ${formatDuration(r.duration)}`}
                </div>
              </div>
            </div>
          ))}
        </div>
      ) : (
        <ul className={`track-list${layout === "compact" ? " track-list-compact" : ""}`}>
          {playlistItems}
          {results.map((r) => (
            <li
              key={r.id}
              className={`track-item${r.id === activeId ? " active" : ""}`}
              onClick={() => onSelect(r)}
              onContextMenu={(e) => onTrackContextMenu(r, e)}
            >
              <img
                className="track-thumb"
                src={r.thumbnail}
                alt=""
                loading="lazy"
              />
              <div className="track-info">
                <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{r.title}</span>
                <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
                  {r.channel}
                  {r.duration > 0 && ` · ${formatDuration(r.duration)}`}
                </span>
              </div>
            </li>
          ))}
        </ul>
      )}

      <div ref={sentinelRef} className="scroll-sentinel" />
      {loadingMore && <div className="loading-more">Loading more...</div>}
    </>
  );
}
