import { useState, useCallback, useRef, useEffect, useLayoutEffect } from "react";
import "./demo.css";
import SearchBar from "./components/SearchBar";
import TrackList from "./components/TrackList";
import Player from "./components/Player";
import HomeBrowser from "./components/HomeBrowser";
import LibraryView from "./components/LibraryView";
import QueuePanel from "./components/QueuePanel";
import BackgroundLayer from "./components/BackgroundLayer";
import SettingsApp from "./SettingsApp";
import useAudioEngine from "./hooks/useAudioEngine";
import { search, getStream, getSuggestions } from "./api/invidiousApi";
import { applyThemePalette, applyButtonShape } from "./theme";
import { Icon, GlyphProvider, resolveGlyphs } from "./icons";
import { recolorBgOptions } from "./bgDefaults";
import { PROCEDURAL_REGISTRY } from "./backgrounds";
import type { SearchResult } from "./api/types";
import type { DemoSettings } from "./types";
import type { LandingTheme } from "../themes";

type View = "home" | "search" | "library";

export default function DemoApp({
  currentTheme: externalTheme,
  onThemeChange,
  onReady,
  onClose,
}: {
  currentTheme: LandingTheme;
  onThemeChange: (t: LandingTheme) => void;
  onReady?: () => void;
  onClose?: () => void;
}) {
  const [view, setView] = useState<View>("home");
  const [searchResults, setSearchResults] = useState<SearchResult[]>([]);
  const [searchPlaylists] = useState<SearchPlaylistResult[]>([]);
  const [searchLoading, setSearchLoading] = useState(false);
  const [currentTrack, setCurrentTrack] = useState<SearchResult | null>(null);
  const [streamLoading, setStreamLoading] = useState(false);
  const [queue, setQueue] = useState<SearchResult[]>([]);
  const [queueIndex, setQueueIndex] = useState(0);
  const [autoplay, setAutoplay] = useState<SearchResult | null>(null);
  const [suggestions, setSuggestions] = useState<SearchResult[]>([]);
  const [showPanel, setShowPanel] = useState(false);
  const [panelMode, setPanelMode] = useState<"suggestions" | "queue">("suggestions");
  const [error, setError] = useState<string | null>(null);
  const [showSettings, setShowSettings] = useState(true);
  const [miniPlayer, setMiniPlayer] = useState(false);
  const [minimized, setMinimized] = useState(false);
  const [maximized, setMaximized] = useState(false);
  const [showSearch, setShowSearch] = useState(true);
  const [layout, setLayout] = useState<"list" | "grid" | "compact">("grid");

  const [settings, setSettings] = useState<DemoSettings>({
    bgOpacity: 0.75,
    glyphPreset: "default",
    buttonShape: "rounded",
  });

  const engine = useAudioEngine();
  const demoRef = useRef<HTMLDivElement>(null);
  const glyphs = resolveGlyphs(settings.glyphPreset);

  // Use external theme — map to demo Theme shape for settings compatibility
  const currentTheme = {
    id: externalTheme.id,
    name: externalTheme.name,
    palette: externalTheme.palette,
  };

  const handleSetTheme = useCallback((theme: { id: string; name: string; palette: ThemePalette }) => {
    // Try to find matching landing theme to sync with parent
    onThemeChange(theme as LandingTheme);
  }, [onThemeChange]);

  // Apply theme on change (layout effect to avoid flash)
  useLayoutEffect(() => {
    const root = demoRef.current;
    if (!root) return;
    applyThemePalette(currentTheme.palette, root);
    applyButtonShape(settings.buttonShape, root);
    // Light themes use fontWeight 500 in the real app
    const fw = externalTheme.family === "light" ? 500 : 400;
    root.style.setProperty("--base-font-weight", String(fw));
    root.style.setProperty("--medium-font-weight", String(fw + 100));
    root.style.setProperty("--bold-font-weight", String(fw + 200));
  }, [currentTheme.palette, settings.buttonShape, externalTheme.family]);

  // Fade in on mount, signal ready at start so skeleton fades out simultaneously
  useEffect(() => {
    const el = demoRef.current;
    if (!el) return;
    el.style.opacity = "0";
    el.style.transition = "opacity 400ms ease";
    requestAnimationFrame(() => {
      el.style.opacity = "1";
      onReady?.();
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Apply bgOpacity
  useEffect(() => {
    demoRef.current?.style.setProperty("--bg-opacity", String(settings.bgOpacity));
  }, [settings.bgOpacity]);

  // Recolour background when theme changes
  useEffect(() => {
    setSettings(s => {
      const bg = s.background;
      if (!bg || bg.type === "none") return s;
      if (bg.type === "gradient") {
        // Regenerate gradient stops using new theme colours
        const grad = `linear-gradient(135deg, ${externalTheme.palette.bgBase} 0%, ${externalTheme.palette.accent} 100%)`;
        return { ...s, background: { ...bg, gradient: grad } };
      }
      if (!PROCEDURAL_REGISTRY[bg.type]) return s;
      return { ...s, background: { ...bg, options: recolorBgOptions(bg.type, bg.options, externalTheme.palette.accent) } };
    });
  }, [externalTheme.id]);

  // Auto-clear errors after 8 seconds
  useEffect(() => {
    if (!error) return;
    const t = setTimeout(() => setError(null), 8000);
    return () => clearTimeout(t);
  }, [error]);

  const playTrack = useCallback(async (track: SearchResult) => {
    setCurrentTrack(track);
    setStreamLoading(true);
    setError(null);
    setAutoplay(null);
    setSuggestions([]);

    const res = await getStream(track.id);
    if (!res.ok) {
      setError("This song can't play in the web demo, which works differently from the desktop app. Every song you love plays in melo on desktop.");
      setStreamLoading(false);
      return;
    }

    engine.loadAndPlay(res.data.audioUrl, false);
    setStreamLoading(false);

    // Load suggestions
    const sugRes = await getSuggestions(track.id);
    if (sugRes.ok && sugRes.data.length > 0) {
      setAutoplay(sugRes.data[0]);
      setSuggestions(sugRes.data.slice(1));
    }
  }, [engine]);

  const handleSearch = useCallback(async (query: string, _filters?: SearchFilters) => {
    setView("search");
    setSearchLoading(true);
    setError(null);
    const res = await search(query);
    if (res.ok) {
      setSearchResults(res.data);
    } else {
      setError("Search isn't reachable in the web demo right now. Try again in a moment, or search in melo on desktop.");
    }
    setSearchLoading(false);
  }, []);

  const handleSelectFromSearch = useCallback(
    (result: SearchResult) => {
      setQueue([]);
      setQueueIndex(0);
      playTrack(result);
    },
    [playTrack],
  );

  const handlePlayVideo = useCallback(
    (tracks: SearchResult[], index: number) => {
      setQueue([]);
      setQueueIndex(0);
      playTrack(tracks[index]);
    },
    [playTrack],
  );

  const handleAddToQueue = useCallback(
    (t: SearchResult) => {
      setQueue((prev) => {
        if (prev.length === 0 && currentTrack) {
          return [currentTrack, t];
        }
        return [...prev, t];
      });
      setShowPanel(true);
      setPanelMode("queue");
    },
    [currentTrack],
  );

  const handleTrackEnded = useCallback(() => {
    if (queueIndex + 1 < queue.length) {
      const next = queueIndex + 1;
      setQueueIndex(next);
      playTrack(queue[next]);
    } else if (autoplay) {
      playTrack(autoplay);
    }
  }, [autoplay, queue, queueIndex, playTrack]);

  const handlePrev = useCallback(() => {
    const audio = engine.activeAudioRef.current;
    if (audio && audio.currentTime > 3) {
      audio.currentTime = 0;
      return;
    }
    if (queueIndex > 0) {
      const prev = queueIndex - 1;
      setQueueIndex(prev);
      playTrack(queue[prev]);
    }
  }, [queue, queueIndex, playTrack, engine]);

  const handleNext = useCallback(() => {
    if (queueIndex + 1 < queue.length) {
      const next = queueIndex + 1;
      setQueueIndex(next);
      playTrack(queue[next]);
    } else if (autoplay) {
      playTrack(autoplay);
    }
  }, [autoplay, queue, queueIndex, playTrack]);

  const handlePlayAutoplay = useCallback(() => {
    if (autoplay) playTrack(autoplay);
  }, [autoplay, playTrack]);

  const handlePlaySuggestion = useCallback(
    (index: number) => {
      playTrack(suggestions[index]);
    },
    [suggestions, playTrack],
  );

  const handleJumpQueue = useCallback(
    (index: number) => {
      setQueueIndex(index);
      playTrack(queue[index]);
    },
    [queue, playTrack],
  );

  const handleReorderQueue = useCallback(
    (fromIndex: number, toIndex: number) => {
      if (fromIndex === toIndex) return;
      setQueue((prev) => {
        const next = [...prev];
        const [moved] = next.splice(fromIndex, 1);
        next.splice(toIndex, 0, moved);
        return next;
      });
      setQueueIndex((prev) => {
        if (fromIndex === prev) return toIndex;
        if (fromIndex < prev && toIndex >= prev) return prev - 1;
        if (fromIndex > prev && toIndex <= prev) return prev + 1;
        return prev;
      });
    },
    [],
  );

  const handleShuffleQueue = useCallback(() => {
    setQueue((prev) => {
      const shuffled = [...prev];
      for (let i = shuffled.length - 1; i > queueIndex + 1; i--) {
        const j = queueIndex + 1 + Math.floor(Math.random() * (i - queueIndex));
        [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
      }
      return shuffled;
    });
  }, [queueIndex]);

  const handleClearQueue = useCallback(() => {
    setQueue([]);
    setQueueIndex(0);
    setPanelMode("suggestions");
  }, []);

  const handleTrackContextMenu = useCallback((_track: SearchResult, e: React.MouseEvent) => {
    e.preventDefault();
  }, []);

  const handleQueueItemContextMenu = useCallback((_track: SearchResult, _index: number, e: React.MouseEvent) => {
    e.preventDefault();
  }, []);

  // --- Demo window drag & resize ---
  const dragRef = useRef<{ startX: number; startY: number; left: number; top: number } | null>(null);
  const settingsDragRef = useRef<{ startX: number; startY: number; left: number; top: number } | null>(null);
  const resizeRef = useRef<{ startX: number; startY: number; w: number; h: number } | null>(null);
  const [windowPos, setWindowPos] = useState({ left: 0, top: 0 });
  const [settingsPos, setSettingsPos] = useState<{ left: number; top: number } | null>(null);
  const settingsWidth = 320;
  const settingsGap = 12;
  const [windowSize, setWindowSize] = useState(() => ({
    width: Math.round(window.innerWidth * 0.7) - settingsWidth - settingsGap,
    height: Math.round(window.innerHeight * 0.8),
  }));

  // Center window on mount
  useLayoutEffect(() => {
    const el = demoRef.current;
    if (!el) return;
    const wrapperWidth = el.clientWidth;
    const totalWidth = windowSize.width + settingsGap + settingsWidth;
    const left = Math.max(0, (wrapperWidth - totalWidth) / 2);
    const top = Math.max(0, (window.innerHeight - windowSize.height) / 2);
    setWindowPos({ left, top });
    setSettingsPos({ left: left + windowSize.width + settingsGap, top });
  }, []);

  useEffect(() => {
    const onMouseMove = (e: MouseEvent) => {
      if (dragRef.current) {
        const dx = e.clientX - dragRef.current.startX;
        const dy = e.clientY - dragRef.current.startY;
        setWindowPos({ left: dragRef.current.left + dx, top: dragRef.current.top + dy });
      }
      if (settingsDragRef.current) {
        const dx = e.clientX - settingsDragRef.current.startX;
        const dy = e.clientY - settingsDragRef.current.startY;
        setSettingsPos({ left: settingsDragRef.current.left + dx, top: settingsDragRef.current.top + dy });
      }
      if (resizeRef.current) {
        const dx = e.clientX - resizeRef.current.startX;
        const dy = e.clientY - resizeRef.current.startY;
        setWindowSize({ width: Math.max(320, resizeRef.current.w + dx), height: Math.max(400, resizeRef.current.h + dy) });
      }
    };
    const onMouseUp = () => { dragRef.current = null; settingsDragRef.current = null; resizeRef.current = null; };
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
    return () => { window.removeEventListener("mousemove", onMouseMove); window.removeEventListener("mouseup", onMouseUp); };
  }, []);

  const handleDragMouseDown = useCallback((e: React.MouseEvent) => {
    if (minimized) return;
    const target = e.target as HTMLElement;
    if (target.closest("button, input, .player-progress, .player-queue-btn, .player-resize-zone")) return;
    if (e.button !== 0) return;
    e.preventDefault();
    dragRef.current = { startX: e.clientX, startY: e.clientY, left: windowPos.left, top: windowPos.top };
  }, [windowPos, minimized]);

  const handleSettingsDragMouseDown = useCallback((e: React.MouseEvent) => {
    const target = e.target as HTMLElement;
    if (target.closest("button")) return;
    if (e.button !== 0) return;
    e.preventDefault();
    const pos = settingsPos ?? { left: windowPos.left + windowSize.width + 12, top: windowPos.top };
    settingsDragRef.current = { startX: e.clientX, startY: e.clientY, left: pos.left, top: pos.top };
  }, [settingsPos, windowPos, windowSize]);

  const handleResizeMouseDown = useCallback((e: React.MouseEvent) => {
    if (minimized) return;
    e.preventDefault();
    e.stopPropagation();
    resizeRef.current = { startX: e.clientX, startY: e.clientY, w: windowSize.width, h: windowSize.height };
  }, [windowSize, minimized]);

  const handleToggleSettings = useCallback(() => {
    if (!showSettings) {
      setSettingsPos({ left: windowPos.left + windowSize.width + 12, top: windowPos.top });
    }
    setShowSettings(s => !s);
  }, [showSettings, windowPos, windowSize]);

  const preMinimizeState = useRef<{ left: number; top: number; width: number; height: number } | null>(null);
  const preMaximizeState = useRef<{ left: number; top: number; width: number; height: number } | null>(null);
  const playerZoneRef = useRef<HTMLDivElement>(null);
  const wasMaximized = useRef(false);

  const handleMinimize = useCallback(() => {
    if (!miniPlayer) {
      preMinimizeState.current = { ...windowPos, ...windowSize };
      wasMaximized.current = maximized;
      setMiniPlayer(true);
      setMinimized(true);
      setMaximized(false);
      setWindowPos({ left: 20, top: window.innerHeight - 100 });
      setWindowSize(s => ({ ...s, width: 360 }));
    }
  }, [windowPos, windowSize, miniPlayer, maximized]);

  const handleRestore = useCallback(() => {
    if (wasMaximized.current) {
      // Restore to maximized state — preMaximizeState already has the original normal size
      const navHeight = document.querySelector(".nav")?.getBoundingClientRect().height ?? 0;
      setWindowPos({ left: 0, top: navHeight });
      setWindowSize({ width: window.innerWidth, height: window.innerHeight - navHeight });
      setMaximized(true);
    } else if (preMinimizeState.current) {
      setWindowPos({ left: preMinimizeState.current.left, top: preMinimizeState.current.top });
      setWindowSize({ width: preMinimizeState.current.width, height: preMinimizeState.current.height });
    }
    preMinimizeState.current = null;
    wasMaximized.current = false;
    setMiniPlayer(false);
    setMinimized(false);
  }, []);

  const handleMaximize = useCallback(() => {
    if (miniPlayer) return;
    if (!maximized) {
      preMaximizeState.current = { ...windowPos, ...windowSize };
      const navHeight = document.querySelector(".nav")?.getBoundingClientRect().height ?? 0;
      setWindowPos({ left: 0, top: navHeight });
      setWindowSize({ width: window.innerWidth, height: window.innerHeight - navHeight });
      setMaximized(true);
    } else {
      if (preMaximizeState.current) {
        setWindowPos({ left: preMaximizeState.current.left, top: preMaximizeState.current.top });
        setWindowSize({ width: preMaximizeState.current.width, height: preMaximizeState.current.height });
      }
      setMaximized(false);
    }
  }, [miniPlayer, maximized, windowPos, windowSize]);

  const handlePlayerDoubleClick = useCallback(() => {
    if (minimized) {
      handleRestore();
      return;
    }
    setMiniPlayer(prev => {
      if (!prev) {
        // Collapsing to mini via double-click (not minimized, stays free)
        preMinimizeState.current = { ...windowPos, ...windowSize };
        const playerRect = playerZoneRef.current?.getBoundingClientRect();
        if (playerRect) {
          setWindowPos(p => ({ ...p, top: playerRect.top }));
        }
      } else {
        // Expanding from mini
        if (preMinimizeState.current) {
          setWindowPos({ left: preMinimizeState.current.left, top: preMinimizeState.current.top });
          setWindowSize({ width: preMinimizeState.current.width, height: preMinimizeState.current.height });
          preMinimizeState.current = null;
        } else {
          const playerRect = playerZoneRef.current?.getBoundingClientRect();
          if (playerRect) {
            const playerH = playerRect.height;
            setWindowPos(p => ({ ...p, top: playerRect.top - (windowSize.height - playerH) }));
          }
        }
      }
      return !prev;
    });
  }, [windowPos, windowSize, minimized, handleRestore]);

  // Compute settings window position
  const settingsLeft = settingsPos ? settingsPos.left : windowPos.left + windowSize.width + 12;
  const settingsTop = settingsPos ? settingsPos.top : windowPos.top;

  const hasQueue = queue.length > 1;

  return (
    <GlyphProvider value={glyphs}>
      <div ref={demoRef} className="demo-wrapper">
        <div
          className={`demo-window${maximized ? " demo-window--maximized" : ""}`}
          style={{
            width: windowSize.width,
            height: miniPlayer ? undefined : windowSize.height,
            left: windowPos.left,
            top: windowPos.top,
          }}

        >
          {settings.background && settings.background.type !== "none" && (
            <BackgroundLayer key={settings.background.type} config={settings.background} />
          )}

          {!miniPlayer && (
            <div className="header-zone">
              <div className="title-bar" onMouseDown={handleDragMouseDown}>
                <span className="title-bar-text">melo</span>
                <div className="title-bar-controls">
                  <button
                    className={`title-bar-btn${showSearch ? " active" : ""}`}
                    onClick={() => setShowSearch((s) => !s)}
                    title="Toggle search (Ctrl+F)"
                  >
                    <Icon name="search" size={14} />
                  </button>
                  <button className="title-bar-btn" title="Minimize" onClick={handleMinimize}><Icon name="minimize" size={12} /></button>
                  <button className="title-bar-btn" title={maximized ? "Restore" : "Maximize"} onClick={handleMaximize}><Icon name={maximized ? "restore" : "maximize"} size={12} /></button>
                  <button className="title-bar-btn title-bar-close" title="Close" onClick={() => onClose?.()}><Icon name="close" size={12} /></button>
                </div>
              </div>

              {showSearch && (
                <div className="top-bar">
                  <SearchBar onSearch={handleSearch} disabled={searchLoading} />
                  <button
                    className="settings-btn"
                    onClick={handleToggleSettings}
                    title="Settings"
                  >
                    <Icon name="settings" size={14} />
                  </button>
                </div>
              )}

              <div className="tab-bar">
                <button
                  className={`tab${view === "home" ? " active" : ""}`}
                  onClick={() => setView("home")}
                >
                  Home
                </button>
                <button
                  className={`tab${view === "library" ? " active" : ""}`}
                  onClick={() => setView("library")}
                >
                  Library
                </button>
                {searchResults.length > 0 && (
                  <button
                    className={`tab tab-shrinkable${view === "search" ? " active" : ""}`}
                    onClick={() => setView("search")}
                  >
                    Search Results
                  </button>
                )}
              </div>
            </div>
          )}


          {!miniPlayer && (
            <div className="main-area">
              {error && (
                <div className="demo-toast" role="status" onClick={() => setError(null)}>{error}</div>
              )}
              <div className="main-content">
                {view === "home" && (
                  <HomeBrowser
                    onSelectPlaylist={() => {}}
                    onPlayVideo={handlePlayVideo}
                    onTrackContextMenu={handleTrackContextMenu}
                    layout={layout}
                    onChangeLayout={setLayout}
                  />
                )}

                {view === "library" && (
                  <LibraryView
                    onPlay={handleSelectFromSearch}
                    onAddToQueue={handleAddToQueue}
                    onTrackContextMenu={handleTrackContextMenu}
                    activeId={currentTrack?.id ?? null}
                    layout={layout}
                    onChangeLayout={setLayout}
                  />
                )}

                {view === "search" && (
                  searchLoading ? (
                    <div className="searching">Searching...</div>
                  ) : (
                    <TrackList
                      results={searchResults}
                      playlists={searchPlaylists}
                      onSelect={handleSelectFromSearch}
                      onSelectPlaylist={() => {}}
                      onTrackContextMenu={handleTrackContextMenu}
                      activeId={currentTrack?.id ?? null}
                      layout={layout}
                      onChangeLayout={setLayout}
                    />
                  )
                )}
              </div>

              {showPanel && currentTrack && (
                <QueuePanel
                  mode={panelMode}
                  onSetMode={setPanelMode}
                  autoplay={autoplay}
                  suggestions={suggestions}
                  queue={queue}
                  queueIndex={queueIndex}
                  onPlayAutoplay={handlePlayAutoplay}
                  onPlaySuggestion={handlePlaySuggestion}
                  onJumpQueue={handleJumpQueue}
                  onReorderQueue={handleReorderQueue}
                  onTrackContextMenu={handleTrackContextMenu}
                  onQueueItemContextMenu={handleQueueItemContextMenu}
                  hasQueue={hasQueue}
                  onClearQueue={handleClearQueue}
                  onShuffleQueue={handleShuffleQueue}
                />
              )}
            </div>
          )}

          <div ref={playerZoneRef} className="player-zone" onDoubleClick={handlePlayerDoubleClick}>
            <Player
              track={currentTrack}
              loading={streamLoading}
              engine={engine}
              onTrackEnded={handleTrackEnded}
              onPrev={handlePrev}
              onNext={handleNext}
              hasNext={!!autoplay || queueIndex + 1 < queue.length}
              queueLength={queue.length}
              onToggleQueue={() => setShowPanel((p) => !p)}
              showQueue={showPanel}
              onPlayerMouseDown={handleDragMouseDown}
            />
          </div>

          <div className="demo-resize-handle" onMouseDown={handleResizeMouseDown} />
        </div>

        {minimized && (
          <button
            className="mini-expand-btn"
            style={{ left: windowPos.left + windowSize.width - 28, top: windowPos.top - 32 }}
            onClick={handleRestore}
            title="Expand"
          >
            <Icon name="maximize" size={14} />
          </button>
        )}

        {showSettings && (
          <div
            className="demo-settings-window"
            style={{ left: settingsLeft, top: settingsTop }}
          >
            <SettingsApp
              settings={settings}
              onUpdateSettings={setSettings}
              currentTheme={currentTheme}
              onSetTheme={handleSetTheme}
              onClose={() => setShowSettings(false)}
              onTitleBarMouseDown={handleSettingsDragMouseDown}
            />
          </div>
        )}
      </div>
    </GlyphProvider>
  );
}
