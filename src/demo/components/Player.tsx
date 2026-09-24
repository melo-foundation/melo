import { useRef, useEffect, useState, useCallback } from "react";
import { Icon } from "../icons";
import type { AudioEngine } from "../hooks/useAudioEngine";

const isAlbumArtUrl = (url: string) => url.includes("albumart/") || url.includes("coverartarchive.org") || url.includes("cover_xl");

function formatTime(s: number): string {
  if (!isFinite(s)) return "0:00";
  const mins = Math.floor(s / 60);
  const secs = Math.floor(s % 60);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

export default function Player({
  track,
  loading,
  engine,
  onTrackEnded,
  onPrev,
  onNext,
  hasNext,
  queueLength,
  onToggleQueue,
  showQueue,
  onPlayerMouseDown,
}: {
  track: SearchResult | null;
  loading: boolean;
  engine: AudioEngine;
  onTrackEnded: () => void;
  onPrev: () => void;
  onNext: () => void;
  hasNext: boolean;
  queueLength: number;
  onToggleQueue: () => void;
  showQueue: boolean;
  onPlayerMouseDown?: (e: React.MouseEvent) => void;
}) {
  const playerRef = useRef<HTMLDivElement>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  const [volumeDisplay, setVolumeDisplay] = useState<number | null>(null);
  const volumeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const progressBarRef = useRef<HTMLDivElement>(null);
  const progressRafRef = useRef<number>(0);

  // Smooth progress bar via rAF (timeupdate is too infrequent for wide bars)
  useEffect(() => {
    const tick = () => {
      const audio = engine.activeAudioRef.current;
      const bar = progressBarRef.current;
      if (audio && bar && audio.duration > 0) {
        bar.style.width = `${(audio.currentTime / audio.duration) * 100}%`;
      }
      progressRafRef.current = requestAnimationFrame(tick);
    };
    if (isPlaying) {
      progressRafRef.current = requestAnimationFrame(tick);
    }
    return () => cancelAnimationFrame(progressRafRef.current);
  }, [isPlaying, engine.activeAudioRef]);

  // Audio element event listeners — attach to BOTH elements, filter by active
  useEffect(() => {
    const audioA = engine.audioRefA.current;
    const audioB = engine.audioRefB.current;
    if (!audioA || !audioB) return;

    const onTimeUpdate = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      setCurrentTime(audio.currentTime);
      if (audio.duration && isFinite(audio.duration)) {
        setDuration(audio.duration);
      }
    };

    const onMetadata = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      setDuration(audio.duration);
    };

    const onPlay = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      setIsPlaying(true);
      if (audio.duration && isFinite(audio.duration)) {
        setDuration(audio.duration);
      }
      setCurrentTime(audio.currentTime);
      engine.ctxRef.current?.resume();
    };

    const onPause = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      setIsPlaying(false);
    };

    const onEnded = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      setIsPlaying(false);
      onTrackEnded();
    };

    const onProgress = (e: Event) => {
      const audio = e.currentTarget as HTMLAudioElement;
      if (audio !== engine.activeAudioRef.current) return;
      if (audio.buffered.length > 0) {
        setBuffered(audio.buffered.end(audio.buffered.length - 1));
      }
    };

    const events = [
      ["timeupdate", onTimeUpdate],
      ["loadedmetadata", onMetadata],
      ["play", onPlay],
      ["pause", onPause],
      ["ended", onEnded],
      ["progress", onProgress],
    ] as const;

    for (const [evt, handler] of events) {
      audioA.addEventListener(evt, handler);
      audioB.addEventListener(evt, handler);
    }

    return () => {
      for (const [evt, handler] of events) {
        audioA.removeEventListener(evt, handler);
        audioB.removeEventListener(evt, handler);
      }
    };
  }, [engine, onTrackEnded]);

  const togglePlay = useCallback(() => {
    const audio = engine.activeAudioRef.current;
    if (!audio) return;
    if (audio.paused) {
      engine.resume();
    } else {
      engine.pause();
    }
  }, [engine]);

  const handleSeek = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      const audio = engine.activeAudioRef.current;
      if (!audio || !duration) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      audio.currentTime = ratio * duration;
    },
    [engine, duration],
  );

  // Volume wheel handler — applies to BOTH elements
  useEffect(() => {
    const el = playerRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      const audioA = engine.audioRefA.current;
      const audioB = engine.audioRefB.current;
      if (!audioA) return;
      e.preventDefault();
      const delta = e.deltaY > 0 ? -0.05 : 0.05;
      const newVol = Math.max(0, Math.min(1, audioA.volume + delta));
      audioA.volume = newVol;
      if (audioB) audioB.volume = newVol;
      setVolumeDisplay(Math.round(newVol * 100));
      if (volumeTimer.current) clearTimeout(volumeTimer.current);
      volumeTimer.current = setTimeout(() => setVolumeDisplay(null), 1000);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [engine]);

  const progress = duration ? (currentTime / duration) * 100 : 0;
  const bufferedPct = duration ? (buffered / duration) * 100 : 0;

  return (
    <>
      <div
        ref={playerRef}
        className="player"
        onMouseDown={onPlayerMouseDown}
      >
        <audio ref={engine.audioRefA} />
        <audio ref={engine.audioRefB} />
        {track ? (
          <div className="player-meta">
            {track.thumbnail && (
              <img className={`player-thumb${isAlbumArtUrl(track.thumbnail) ? " album-art" : ""}`} src={track.thumbnail} alt="" />
            )}
            <div className="player-info">
              <span
                className="player-title"
                onMouseEnter={(e) => {
                  const el = e.currentTarget;
                  const overflow = el.scrollWidth - el.clientWidth;
                  if (overflow > 1) {
                    el.style.setProperty("--scroll-dist", `-${overflow + 8}px`);
                    el.style.setProperty("--scroll-duration", `${Math.max(4, overflow / 30)}s`);
                    el.classList.add("scrolling");
                  }
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.classList.remove("scrolling");
                }}
              >
                {track.title}
              </span>
              <span
                className="player-channel"
                onMouseEnter={(e) => {
                  const el = e.currentTarget;
                  const overflow = el.scrollWidth - el.clientWidth;
                  if (overflow > 1) {
                    el.style.setProperty("--scroll-dist", `-${overflow + 8}px`);
                    el.style.setProperty("--scroll-duration", `${Math.max(4, overflow / 30)}s`);
                    el.classList.add("scrolling");
                  }
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.classList.remove("scrolling");
                }}
              >
                {track.channel}
              </span>
            </div>
          </div>
        ) : (
          <div className="player-skeleton">
            <div className={`player-thumb skeleton${loading ? " shimmer" : ""}`} />
            <div className="player-info">
              <span className={`player-title skeleton${loading ? " shimmer" : ""}`} />
              <span className={`player-channel skeleton${loading ? " shimmer" : ""}`} />
            </div>
          </div>
        )}

        <div className="player-controls">
          <button
            className="player-skip"
            onClick={onPrev}
            disabled={!track}
            title="Previous"
          >
            <Icon name="prevTrack" size={14} />
          </button>

          <button className="player-playpause" onClick={togglePlay} disabled={!track}>
            {isPlaying
              ? <Icon name="pause" size={14} />
              : <Icon name="play" size={14} />
            }
          </button>

          <button
            className="player-skip"
            onClick={onNext}
            disabled={!hasNext}
            title="Next"
          >
            <Icon name="nextTrack" size={14} />
          </button>
        </div>

        <div className="player-progress-wrap">
          <span className="player-time">{formatTime(currentTime)}</span>
          <div className="player-progress" onClick={handleSeek}>
            <div className="player-progress-buffered" style={{ width: `${bufferedPct}%` }} />
            <div ref={progressBarRef} className="player-progress-played" style={{ width: `${progress}%` }} />
          </div>
          <span className="player-time">{formatTime(duration)}</span>
        </div>

        <button
          className={`player-queue-btn${showQueue ? " active" : ""}`}
          onClick={onToggleQueue}
          disabled={!track}
          title="Queue"
        >
          <Icon name="queueList" size={14} />{queueLength > 1 && <span>{queueLength}</span>}
        </button>

      </div>

      {volumeDisplay !== null && (
        <div className="player-volume-display">
          {volumeDisplay}%
        </div>
      )}
    </>
  );
}
