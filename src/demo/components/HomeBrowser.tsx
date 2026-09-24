import { useState, useEffect, useCallback, useRef } from "react";
import LayoutToggle from "./LayoutToggle";
import { Icon } from "../icons";
import { getTrending } from "../api/invidiousApi";

function formatDuration(seconds: number): string {
  if (!seconds) return "";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

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

export default function HomeBrowser({
  onSelectPlaylist,
  onPlayVideo,
  onTrackContextMenu,
  layout,
  onChangeLayout,
}: {
  onSelectPlaylist: (playlistId: string, title: string) => void;
  onPlayVideo: (tracks: SearchResult[], index: number) => void;
  onTrackContextMenu: (track: SearchResult, e: React.MouseEvent) => void;
  layout: "list" | "grid" | "compact";
  onChangeLayout: (mode: "list" | "grid" | "compact") => void;
}) {
  const [sections] = useState<HomeSection[]>([]);
  const [recommended, setRecommended] = useState<SearchResult[]>([]);
  const [loadingMixes, setLoadingMixes] = useState(true);
  const [loadingRecs, setLoadingRecs] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchAll = useCallback(() => {
    setLoadingMixes(true);
    setLoadingRecs(true);
    setError(null);
    setRecommended([]);

    getTrending().then((res) => {
      setLoadingMixes(false);
      setLoadingRecs(false);
      if (res.ok) {
        setRecommended(res.data);
      } else {
        setError("Recommendations aren't reachable in the web demo right now. Try again in a moment.");
      }
    });
  }, []);

  useEffect(() => { fetchAll(); }, [fetchAll]);

  // Drag-to-scroll for chip bar with momentum
  const chipBarRef = useRef<HTMLDivElement>(null);
  const chipDragState = useRef<{ startX: number; scrollLeft: number; lastX: number; velocity: number; time: number } | null>(null);
  const chipDragged = useRef(false);
  const chipMomentum = useRef<number>(0);

  const dpiScale = window.devicePixelRatio || 1;

  const onChipBarMouseDown = useCallback((e: React.MouseEvent) => {
    const bar = chipBarRef.current;
    if (!bar) return;
    if (chipMomentum.current) { cancelAnimationFrame(chipMomentum.current); chipMomentum.current = 0; }
    chipDragged.current = false;
    chipDragState.current = { startX: e.clientX, scrollLeft: bar.scrollLeft, lastX: e.clientX, velocity: 0, time: Date.now() };
  }, []);

  useEffect(() => {
    const onMouseMove = (e: MouseEvent) => {
      const d = chipDragState.current;
      const bar = chipBarRef.current;
      if (!d || !bar) return;
      const dx = (e.clientX - d.startX) / dpiScale;
      if (Math.abs(dx) > 3) chipDragged.current = true;
      const now = Date.now();
      const dt = Math.max(1, now - d.time);
      const moveDx = (e.clientX - d.lastX) / dpiScale;
      d.velocity = moveDx / dt * 16; // px per frame
      d.lastX = e.clientX;
      d.time = now;
      bar.scrollLeft = d.scrollLeft - dx;
    };
    const onMouseUp = () => {
      const d = chipDragState.current;
      const bar = chipBarRef.current;
      chipDragState.current = null;
      if (!d || !bar || !chipDragged.current) return;
      let v = -d.velocity;
      const animate = () => {
        if (Math.abs(v) < 0.5) { chipMomentum.current = 0; return; }
        bar.scrollLeft += v;
        v *= 0.92;
        chipMomentum.current = requestAnimationFrame(animate);
      };
      chipMomentum.current = requestAnimationFrame(animate);
    };
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
    return () => {
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
    };
  }, [dpiScale]);

  const loading = loadingMixes && loadingRecs;
  const refreshing = (loadingMixes || loadingRecs) && !loading;
  if (loading) return <div className="home-loading">Loading your recommendations...</div>;

  const renderRecommendedGrid = () => (
    <div className="home-grid home-grid-videos">
      {recommended.map((track, i) => (
        <button
          key={track.id}
          className="home-tile home-tile-video"
          onClick={() =>
            track.id.startsWith("RD")
              ? onSelectPlaylist(track.id, track.title)
              : onPlayVideo(recommended, i)
          }
          onContextMenu={(e) => {
            if (!track.id.startsWith("RD")) onTrackContextMenu(track, e);
          }}
        >
          <div className="home-tile-thumb-wrap">
            <img className="home-tile-thumb home-tile-thumb-video" src={track.thumbnail} alt="" loading="lazy" />
            {track.duration > 0 && (
              <span className="home-tile-duration">{formatDuration(track.duration)}</span>
            )}
          </div>
          <div className="home-tile-info">
            <span className="home-tile-title">{track.title}</span>
            {track.channel && (
              <span className="home-tile-desc">{track.channel}</span>
            )}
          </div>
        </button>
      ))}
    </div>
  );

  const renderRecommendedList = (compact: boolean) => (
    <ul className={`track-list${compact ? " track-list-compact" : ""}`}>
      {recommended.map((track, i) => (
        <li
          key={track.id}
          className="track-item"
          onClick={() =>
            track.id.startsWith("RD")
              ? onSelectPlaylist(track.id, track.title)
              : onPlayVideo(recommended, i)
          }
          onContextMenu={(e) => {
            if (!track.id.startsWith("RD")) onTrackContextMenu(track, e);
          }}
        >
          <img className="track-thumb" src={track.thumbnail} alt="" loading="lazy" />
          <div className="track-info">
            <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{track.title}</span>
            <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
              {track.channel}
              {track.duration > 0 && ` · ${formatDuration(track.duration)}`}
            </span>
          </div>
        </li>
      ))}
    </ul>
  );

  const renderSectionGrid = (section: HomeSection) => (
    <div className="home-grid">
      {section.playlists.map((p) => (
        <button
          key={p.playlistId}
          className="home-tile"
          onClick={() => onSelectPlaylist(p.playlistId, p.title)}
        >
          {p.thumbnail && (
            <img className="home-tile-thumb" src={p.thumbnail} alt="" loading="lazy" />
          )}
          <div className="home-tile-info">
            <span className="home-tile-title">{p.title}</span>
            {p.description && (
              <span className="home-tile-desc">{p.description}</span>
            )}
          </div>
        </button>
      ))}
    </div>
  );

  const renderSectionList = (section: HomeSection, compact: boolean) => (
    <ul className={`track-list${compact ? " track-list-compact" : ""}`}>
      {section.playlists.map((p) => (
        <li
          key={p.playlistId}
          className="track-item"
          onClick={() => onSelectPlaylist(p.playlistId, p.title)}
        >
          <img className="track-thumb" src={p.thumbnail} alt="" loading="lazy" />
          <div className="track-info">
            <span className="track-title" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>{p.title}</span>
            <span className="track-meta" onMouseEnter={startTextScroll} onMouseLeave={stopTextScroll}>
              {p.description || "Playlist"}
            </span>
          </div>
        </li>
      ))}
    </ul>
  );

  return (
    <div className="home-browser">
      <div className="home-toolbar-row">
        <div className="chip-bar" ref={chipBarRef} onMouseDown={onChipBarMouseDown}>
          <button className="chip home-refresh-chip" onClick={fetchAll} disabled={refreshing}>
            {refreshing ? "..." : <Icon name="refresh" size={14} />}
          </button>
        </div>
        <div className="home-layout-toggle">
          <LayoutToggle layout={layout} onChange={onChangeLayout} />
        </div>
      </div>

      {error && <div className="home-error">{error}</div>}

      {/* Recommended videos */}
      {recommended.length > 0 && (
        <div className="home-section">
          {layout === "grid" ? renderRecommendedGrid() : renderRecommendedList(layout === "compact")}
        </div>
      )}

      {/* YouTube Music mix playlists */}
      {sections.map((section) => (
        <div key={section.title} className="home-section">
          <h2 className="home-section-title">{section.title}</h2>
          <p className="home-section-subtitle">YouTube Music</p>
          {layout === "grid" ? renderSectionGrid(section) : renderSectionList(section, layout === "compact")}
        </div>
      ))}

      {recommended.length === 0 && sections.length === 0 && (
        <div className="home-empty">No recommendations found.</div>
      )}
    </div>
  );
}
