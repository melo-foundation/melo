import { useRef, useState } from "react";
import { Icon } from "../icons";

const isAlbumArtUrl = (url: string) => url.includes("albumart/") || url.includes("coverartarchive.org") || url.includes("cover_xl");

function formatDuration(seconds: number): string {
  if (!seconds) return "";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

type PanelMode = "suggestions" | "queue";

export default function QueuePanel({
  mode,
  onSetMode,
  autoplay,
  suggestions,
  queue,
  queueIndex,
  onPlayAutoplay,
  onPlaySuggestion,
  onJumpQueue,
  onReorderQueue,
  onTrackContextMenu,
  onQueueItemContextMenu,
  hasQueue,
  onSaveQueue,
  onClearQueue,
  onShuffleQueue,
}: {
  mode: PanelMode;
  onSetMode: (mode: PanelMode) => void;
  autoplay: SearchResult | null;
  suggestions: SearchResult[];
  queue: SearchResult[];
  queueIndex: number;
  onPlayAutoplay: () => void;
  onPlaySuggestion: (index: number) => void;
  onJumpQueue: (index: number) => void;
  onReorderQueue: (fromIndex: number, toIndex: number) => void;
  onTrackContextMenu: (track: SearchResult, e: React.MouseEvent) => void;
  onQueueItemContextMenu: (track: SearchResult, index: number, e: React.MouseEvent) => void;
  hasQueue: boolean;
  onSaveQueue?: (e: React.MouseEvent) => void;
  onClearQueue?: () => void;
  onShuffleQueue?: () => void;
}) {
  // When a playlist queue is active, merge autoplay into the suggestions list
  const allSuggestions = hasQueue && autoplay
    ? [autoplay, ...suggestions]
    : suggestions;

  // Drag-and-drop state
  const dragIndexRef = useRef<number | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);
  const [dragOverHalf, setDragOverHalf] = useState<"top" | "bottom">("bottom");

  const handleDragStart = (e: React.DragEvent, index: number) => {
    dragIndexRef.current = index;
    e.dataTransfer.effectAllowed = "move";
    // Make the drag image slightly transparent
    if (e.currentTarget instanceof HTMLElement) {
      e.currentTarget.classList.add("dragging");
    }
  };

  const handleDragEnd = (e: React.DragEvent) => {
    if (e.currentTarget instanceof HTMLElement) {
      e.currentTarget.classList.remove("dragging");
    }
    if (dragIndexRef.current !== null && dragOverIndex !== null) {
      let toIndex = dragOverIndex;
      if (dragOverHalf === "bottom") toIndex++;
      // Adjust if dragging downward past the original position
      if (toIndex > dragIndexRef.current) toIndex--;
      if (toIndex !== dragIndexRef.current) {
        onReorderQueue(dragIndexRef.current, toIndex);
      }
    }
    dragIndexRef.current = null;
    setDragOverIndex(null);
  };

  const handleDragOver = (e: React.DragEvent, index: number) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const rect = e.currentTarget.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    setDragOverIndex(index);
    setDragOverHalf(e.clientY < midY ? "top" : "bottom");
  };

  const handleDragLeave = () => {
    setDragOverIndex(null);
  };

  // When queue is empty, always show suggestions (no queue tab to switch to)
  const effectiveMode = hasQueue ? mode : "suggestions";

  return (
    <div className="queue-panel">
      {hasQueue && (
        <div className="queue-tabs">
          <button
            className={`queue-tab${effectiveMode === "suggestions" ? " active" : ""}`}
            onClick={() => onSetMode("suggestions")}
          >
            Suggestions
          </button>
          <button
            className={`queue-tab${effectiveMode === "queue" ? " active" : ""}`}
            onClick={() => onSetMode("queue")}
          >
            Queue ({queue.length})
          </button>
        </div>
      )}

      {effectiveMode === "suggestions" && (
        <div className="queue-suggestions">
          {!hasQueue && autoplay && (
            <>
              <div className="queue-section-label">Autoplay</div>
              <div
                className="queue-item autoplay"
                onClick={onPlayAutoplay}
                onContextMenu={(e) => onTrackContextMenu(autoplay, e)}
              >
                <img className={`queue-item-thumb${isAlbumArtUrl(autoplay.thumbnail) ? " album-art" : ""}`} src={autoplay.thumbnail} alt="" loading="lazy" />
                <div className="queue-item-info">
                  <span className="queue-item-title">{autoplay.title || "Loading..."}</span>
                  <span className="queue-item-meta">{autoplay.channel}</span>
                </div>
              </div>
            </>
          )}

          {allSuggestions.length > 0 && (
            <>
              {!hasQueue && <div className="queue-section-label">Suggestions</div>}
              {allSuggestions.map((track, i) => {
                // When queue is active, first item is the merged autoplay
                const isAutoplay = hasQueue && i === 0 && autoplay;
                const onClick = isAutoplay
                  ? onPlayAutoplay
                  : () => onPlaySuggestion(hasQueue && autoplay ? i - 1 : i);

                return (
                  <div
                    key={`${track.id}-${i}`}
                    className="queue-item"
                    onClick={onClick}
                    onContextMenu={(e) => onTrackContextMenu(track, e)}
                  >
                    <img className={`queue-item-thumb${isAlbumArtUrl(track.thumbnail) ? " album-art" : ""}`} src={track.thumbnail} alt="" loading="lazy" />
                    <div className="queue-item-info">
                      <span className="queue-item-title">{track.title || "Loading..."}</span>
                      <span className="queue-item-meta">
                        {track.channel}
                        {track.duration > 0 && ` · ${formatDuration(track.duration)}`}
                      </span>
                    </div>
                  </div>
                );
              })}
            </>
          )}

          {!autoplay && suggestions.length === 0 && (
            <div className="queue-empty">No suggestions available</div>
          )}
        </div>
      )}

      {effectiveMode === "queue" && (
        <div className="queue-list-wrap">
          <div className="queue-header">
            <span className="queue-count">{queueIndex + 1} / {queue.length}</span>
            {onSaveQueue && queue.length > 0 && (
              <button className="queue-save-btn" onClick={onSaveQueue} title="Save queue as playlist">
                <Icon name="save" size={14} />
              </button>
            )}
            {onShuffleQueue && queue.length - queueIndex > 2 && (
              <button className="queue-save-btn" onClick={onShuffleQueue} title="Shuffle upcoming tracks">
                <Icon name="shuffle" size={14} />
              </button>
            )}
            {onClearQueue && queue.length > 0 && (
              <button className="queue-save-btn" onClick={onClearQueue} title="Clear queue">
                <Icon name="close" size={14} />
              </button>
            )}
          </div>
          {queue.map((track, i) => {
            let dragClass = "";
            if (dragOverIndex === i && dragIndexRef.current !== null && dragIndexRef.current !== i) {
              dragClass = dragOverHalf === "top" ? " drag-over-top" : " drag-over-bottom";
            }
            return (
              <div
                key={`${track.id}-${i}`}
                className={`queue-item${i === queueIndex ? " active" : ""}${i < queueIndex ? " played" : ""}${dragClass}`}
                onClick={() => onJumpQueue(i)}
                onContextMenu={(e) => onQueueItemContextMenu(track, i, e)}
                draggable
                onDragStart={(e) => handleDragStart(e, i)}
                onDragEnd={handleDragEnd}
                onDragOver={(e) => handleDragOver(e, i)}
                onDragLeave={handleDragLeave}
              >
                <span className="queue-item-index">{i + 1}</span>
                {track.thumbnail && (
                  <img className={`queue-item-thumb${isAlbumArtUrl(track.thumbnail) ? " album-art" : ""}`} src={track.thumbnail} alt="" loading="lazy" />
                )}
                <div className="queue-item-info">
                  <span className="queue-item-title">{track.title}</span>
                  <span className="queue-item-meta">
                    {track.channel}
                    {track.duration > 0 && ` · ${formatDuration(track.duration)}`}
                  </span>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
