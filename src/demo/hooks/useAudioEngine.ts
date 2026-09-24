import { useRef, useState, useCallback, useMemo } from "react";

export interface AudioEngine {
  audioRefA: React.RefObject<HTMLAudioElement | null>;
  audioRefB: React.RefObject<HTMLAudioElement | null>;
  activeAudioRef: React.MutableRefObject<HTMLAudioElement | null>;
  analyserRef: React.MutableRefObject<AnalyserNode | null>;
  analyserNode: AnalyserNode | null;
  ctxRef: React.MutableRefObject<AudioContext | null>;
  nextReady: React.MutableRefObject<boolean>;
  ensureContext: () => void;
  loadAndPlay: (url: string, isLocal: boolean) => void;
  preloadNext: (url: string, isLocal: boolean) => void;
  crossfadeToNext: (durationMs: number) => void;
  cancelCrossfade: () => void;
  quickFinishCrossfade: () => Promise<void>;
  pause: () => void;
  resume: () => void;
  updateEQ: (bands: number[]) => void;
}

export default function useAudioEngine(): AudioEngine {
  const audioRefA = useRef<HTMLAudioElement | null>(null);
  const audioRefB = useRef<HTMLAudioElement | null>(null);

  // Always points to the currently playing element
  const activeAudioRef = useRef<HTMLAudioElement | null>(null);
  // 0 = A is active, 1 = B is active
  const activeIndexRef = useRef(0);

  const ctxRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const [analyserNode, setAnalyserNode] = useState<AnalyserNode | null>(null);

  const sourceARef = useRef<MediaElementAudioSourceNode | null>(null);
  const sourceBRef = useRef<MediaElementAudioSourceNode | null>(null);
  const gainARef = useRef<GainNode | null>(null);
  const gainBRef = useRef<GainNode | null>(null);
  const eqNodesRef = useRef<BiquadFilterNode[]>([]);

  const nextReady = useRef(false);
  const crossfadeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const crossfadingRef = useRef(false);

  // Deferred preload — stored when preloadNext is called during a crossfade
  const pendingPreloadRef = useRef<{ url: string; isLocal: boolean } | null>(null);

  // Crossfade pause tracking
  const crossfadeOldRef = useRef<HTMLAudioElement | null>(null);
  const crossfadeStartTimeRef = useRef(0);
  const crossfadeTotalDurationRef = useRef(0);
  const crossfadeElapsedRef = useRef(0);

  // quickFinishCrossfade resolve callback
  const quickFinishResolveRef = useRef<(() => void) | null>(null);

  const ensureContext = useCallback(() => {
    if (ctxRef.current) return;

    const audioA = audioRefA.current;
    const audioB = audioRefB.current;
    if (!audioA || !audioB) return;

    const ctx = new AudioContext();

    const sourceA = ctx.createMediaElementSource(audioA);
    const sourceB = ctx.createMediaElementSource(audioB);

    const gainA = ctx.createGain();
    const gainB = ctx.createGain();
    gainA.gain.value = 1;
    gainB.gain.value = 0;

    sourceA.connect(gainA);
    sourceB.connect(gainB);

    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;

    // Create 10-band graphic EQ filter chain
    const EQ_FREQS = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    const eqNodes = EQ_FREQS.map((freq, i) => {
      const f = ctx.createBiquadFilter();
      f.type = i === 0 ? "lowshelf" : i === 9 ? "highshelf" : "peaking";
      f.frequency.value = freq;
      f.gain.value = 0;
      if (f.type === "peaking") f.Q.value = 1.4;
      return f;
    });

    // Chain: gains → eq[0] → eq[1] → ... → eq[9] → analyser → destination
    gainA.connect(eqNodes[0]);
    gainB.connect(eqNodes[0]);
    for (let i = 0; i < eqNodes.length - 1; i++) eqNodes[i].connect(eqNodes[i + 1]);
    eqNodes[eqNodes.length - 1].connect(analyser);
    analyser.connect(ctx.destination);
    eqNodesRef.current = eqNodes;

    ctxRef.current = ctx;
    sourceARef.current = sourceA;
    sourceBRef.current = sourceB;
    gainARef.current = gainA;
    gainBRef.current = gainB;
    analyserRef.current = analyser;
    setAnalyserNode(analyser);

    activeAudioRef.current = audioA;
    activeIndexRef.current = 0;
  }, []);

  /** Load a preload onto the given element (internal helper, no crossfade guard). */
  const doPreload = useCallback(
    (element: HTMLAudioElement, url: string, isLocal: boolean) => {
      nextReady.current = false;

      if (isLocal) {
        element.removeAttribute("crossOrigin");
      } else {
        element.crossOrigin = "anonymous";
      }
      element.preload = "auto";
      element.src = url;
      element.load();

      const onReady = () => {
        nextReady.current = true;
        element.removeEventListener("canplaythrough", onReady);
      };
      element.addEventListener("canplaythrough", onReady);
      element.addEventListener(
        "error",
        () => console.warn("[audio] preload error", element.error),
        { once: true },
      );
    },
    [],
  );

  const cancelCrossfade = useCallback(() => {
    if (crossfadeTimerRef.current) {
      clearTimeout(crossfadeTimerRef.current);
      crossfadeTimerRef.current = null;
    }

    // Pause the fading-out element so it's cleanly stopped
    const old = crossfadeOldRef.current;
    if (old && !old.paused) old.pause();

    crossfadingRef.current = false;
    pendingPreloadRef.current = null;
    crossfadeOldRef.current = null;
    crossfadeElapsedRef.current = 0;

    // Resolve any pending quickFinishCrossfade promise
    if (quickFinishResolveRef.current) {
      quickFinishResolveRef.current();
      quickFinishResolveRef.current = null;
    }

    // Reset gains: active = 1, inactive = 0
    const ctx = ctxRef.current;
    if (!ctx) return;
    const activeGain = activeIndexRef.current === 0 ? gainARef.current : gainBRef.current;
    const inactiveGain = activeIndexRef.current === 0 ? gainBRef.current : gainARef.current;
    if (activeGain) {
      activeGain.gain.cancelScheduledValues(ctx.currentTime);
      activeGain.gain.setValueAtTime(1, ctx.currentTime);
    }
    if (inactiveGain) {
      inactiveGain.gain.cancelScheduledValues(ctx.currentTime);
      inactiveGain.gain.setValueAtTime(0, ctx.currentTime);
    }
  }, []);

  /** Gracefully finish an in-progress crossfade, then resolve.
   *  - Old gain ≤ 10%: instant drop (inaudible against the other track)
   *  - ≤ 500ms remaining: let it complete naturally
   *  - Otherwise: speed up the ramps to finish in 500ms */
  const quickFinishCrossfade = useCallback((): Promise<void> => {
    if (!crossfadingRef.current) return Promise.resolve();

    const ctx = ctxRef.current;
    if (!ctx) { cancelCrossfade(); return Promise.resolve(); }

    const old = crossfadeOldRef.current;
    const inactiveGain = activeIndexRef.current === 0 ? gainBRef.current : gainARef.current;
    const activeGain = activeIndexRef.current === 0 ? gainARef.current : gainBRef.current;

    if (!inactiveGain || !activeGain) { cancelCrossfade(); return Promise.resolve(); }

    const oldGainValue = inactiveGain.gain.value;
    const elapsed = crossfadeElapsedRef.current + (Date.now() - crossfadeStartTimeRef.current);
    const remaining = crossfadeTotalDurationRef.current - elapsed;

    // Instant drop: old track is very quiet (-20dB) or not playing
    if (oldGainValue <= 0.10 || !old || old.paused) {
      cancelCrossfade();
      return Promise.resolve();
    }

    // Speed up the ramps: use remaining time if ≤ 500ms, otherwise 500ms
    const rampMs = Math.min(500, Math.max(remaining, 0));
    const rampSec = rampMs / 1000;
    const now = ctx.currentTime;

    inactiveGain.gain.cancelScheduledValues(now);
    inactiveGain.gain.setValueAtTime(inactiveGain.gain.value, now);
    inactiveGain.gain.linearRampToValueAtTime(0, now + rampSec);

    activeGain.gain.cancelScheduledValues(now);
    activeGain.gain.setValueAtTime(activeGain.gain.value, now);
    activeGain.gain.linearRampToValueAtTime(1, now + rampSec);

    // Replace the existing crossfade timer with a shorter one
    if (crossfadeTimerRef.current) {
      clearTimeout(crossfadeTimerRef.current);
    }

    return new Promise<void>((resolve) => {
      quickFinishResolveRef.current = resolve;
      crossfadeTimerRef.current = setTimeout(() => {
        if (old && !old.paused) old.pause();
        crossfadingRef.current = false;
        crossfadeTimerRef.current = null;
        crossfadeOldRef.current = null;
        crossfadeElapsedRef.current = 0;
        pendingPreloadRef.current = null;

        quickFinishResolveRef.current = null;
        resolve();
      }, rampMs + 10);
    });
  }, [cancelCrossfade]);

  const loadAndPlay = useCallback(
    (url: string, isLocal: boolean) => {
      ensureContext();
      cancelCrossfade();

      const active = activeIndexRef.current === 0 ? audioRefA.current : audioRefB.current;
      const inactive = activeIndexRef.current === 0 ? audioRefB.current : audioRefA.current;

      if (!active) return;

      if (isLocal) {
        active.removeAttribute("crossOrigin");
      } else {
        active.crossOrigin = "anonymous";
      }
      active.src = url;
      active.load();

      const ctx = ctxRef.current;
      if (ctx?.state === "running") {
        active.play().catch(() => {});
      } else {
        ctx?.resume().then(() => active.play().catch(() => {}));
      }

      // Reset inactive element (safe — cancelCrossfade already stopped any fade)
      if (inactive) {
        inactive.pause();
        inactive.removeAttribute("src");
        inactive.load();
      }
      nextReady.current = false;
    },
    [ensureContext, cancelCrossfade],
  );

  const preloadNext = useCallback(
    (url: string, isLocal: boolean) => {
      // During crossfade, the "inactive" element is still fading out.
      // Don't overwrite it — defer the preload until the crossfade finishes.
      if (crossfadingRef.current) {
        pendingPreloadRef.current = { url, isLocal };
        return;
      }

      const inactive =
        activeIndexRef.current === 0 ? audioRefB.current : audioRefA.current;
      if (!inactive) return;

      // Extra safety: if the inactive element is somehow still playing, don't touch it
      if (!inactive.paused) {
        pendingPreloadRef.current = { url, isLocal };
        return;
      }

      doPreload(inactive, url, isLocal);
    },
    [doPreload],
  );

  const crossfadeToNext = useCallback(
    (durationMs: number) => {
      ensureContext();
      const ctx = ctxRef.current;
      if (!ctx) return;

      const activeGain = activeIndexRef.current === 0 ? gainARef.current : gainBRef.current;
      const inactiveGain = activeIndexRef.current === 0 ? gainBRef.current : gainARef.current;
      const inactive = activeIndexRef.current === 0 ? audioRefB.current : audioRefA.current;
      const active = activeIndexRef.current === 0 ? audioRefA.current : audioRefB.current;

      if (!activeGain || !inactiveGain || !inactive || !active) return;

      // Clear any in-progress crossfade timer to avoid stale callbacks
      if (crossfadeTimerRef.current) {
        clearTimeout(crossfadeTimerRef.current);
        crossfadeTimerRef.current = null;
      }
      // Resolve any pending quickFinishCrossfade promise
      if (quickFinishResolveRef.current) {
        quickFinishResolveRef.current();
        quickFinishResolveRef.current = null;
      }
      crossfadingRef.current = true;

      // Start playing the inactive (preloaded) element immediately
      if (ctx.state === "running") {
        inactive.play().catch((e) => console.warn("[crossfadeToNext] play failed:", e));
      } else {
        ctx.resume().then(() => inactive.play().catch((e) => console.warn("[crossfadeToNext] play failed:", e)));
      }

      // Swap active index so event listeners from the old element are filtered out
      const newIndex = activeIndexRef.current === 0 ? 1 : 0;
      activeIndexRef.current = newIndex;
      activeAudioRef.current = inactive;
      nextReady.current = false;

      if (durationMs <= 0) {
        // Instant swap — gapless
        activeGain.gain.cancelScheduledValues(ctx.currentTime);
        inactiveGain.gain.cancelScheduledValues(ctx.currentTime);
        activeGain.gain.setValueAtTime(0, ctx.currentTime);
        inactiveGain.gain.setValueAtTime(1, ctx.currentTime);

        active.pause();
        crossfadingRef.current = false;

        // Execute any deferred preload now that the old element is free
        if (pendingPreloadRef.current) {
          const { url, isLocal } = pendingPreloadRef.current;
          pendingPreloadRef.current = null;
          doPreload(active, url, isLocal);
        }
      } else {
        // Crossfade with Web Audio gain ramps — both channels play simultaneously
        const durationSec = durationMs / 1000;
        const now = ctx.currentTime;

        activeGain.gain.cancelScheduledValues(now);
        inactiveGain.gain.cancelScheduledValues(now);

        activeGain.gain.setValueAtTime(activeGain.gain.value, now);
        inactiveGain.gain.setValueAtTime(inactiveGain.gain.value, now);

        activeGain.gain.linearRampToValueAtTime(0, now + durationSec);
        inactiveGain.gain.linearRampToValueAtTime(1, now + durationSec);

        // Track crossfade timing for pause/resume
        crossfadeOldRef.current = active;
        crossfadeStartTimeRef.current = Date.now();
        crossfadeTotalDurationRef.current = durationMs;
        crossfadeElapsedRef.current = 0;

        crossfadeTimerRef.current = setTimeout(() => {
          active.pause();
          crossfadingRef.current = false;
          crossfadeTimerRef.current = null;
          crossfadeOldRef.current = null;

          // Now the old element is paused and free — execute any deferred preload
          if (pendingPreloadRef.current) {
            const { url, isLocal } = pendingPreloadRef.current;
            pendingPreloadRef.current = null;
            doPreload(active, url, isLocal);
          }
        }, durationMs);
      }
    },
    [ensureContext, doPreload],
  );

  /** Pause playback — during crossfade, pauses both elements and freezes gain ramps */
  const pause = useCallback(() => {
    const active = activeAudioRef.current;
    if (!active) return;

    if (crossfadingRef.current) {
      // Save crossfade progress
      const elapsed = crossfadeElapsedRef.current + (Date.now() - crossfadeStartTimeRef.current);
      crossfadeElapsedRef.current = elapsed;

      // Clear the completion timer
      if (crossfadeTimerRef.current) {
        clearTimeout(crossfadeTimerRef.current);
        crossfadeTimerRef.current = null;
      }

      // Pause the fading-out element
      const old = crossfadeOldRef.current;
      if (old && !old.paused) old.pause();

      // Suspend AudioContext to freeze gain ramps (ctx.currentTime freezes)
      ctxRef.current?.suspend();
    }

    active.pause();
  }, []);

  /** Resume playback — during crossfade, resumes both elements and unfreezes gain ramps */
  const resume = useCallback(() => {
    const ctx = ctxRef.current;
    const active = activeAudioRef.current;
    if (!active) return;

    if (crossfadingRef.current) {
      // Resume AudioContext first (unfreezes ctx.currentTime → gain ramps continue)
      (ctx?.resume() ?? Promise.resolve()).then(() => {
        active.play().catch(() => {});

        // Resume the fading-out element
        const old = crossfadeOldRef.current;
        if (old) old.play().catch(() => {});

        // Re-schedule the completion timer with remaining time
        const remaining = crossfadeTotalDurationRef.current - crossfadeElapsedRef.current;
        crossfadeStartTimeRef.current = Date.now();

        if (remaining > 0) {
          crossfadeTimerRef.current = setTimeout(() => {
            if (old) old.pause();
            crossfadingRef.current = false;
            crossfadeTimerRef.current = null;
            crossfadeOldRef.current = null;

            if (pendingPreloadRef.current) {
              const { url, isLocal } = pendingPreloadRef.current;
              pendingPreloadRef.current = null;
              if (old) doPreload(old, url, isLocal);
            }
          }, remaining);
        } else {
          // Crossfade should have completed by now
          if (old) old.pause();
          crossfadingRef.current = false;
          crossfadeOldRef.current = null;

          if (pendingPreloadRef.current) {
            const { url, isLocal } = pendingPreloadRef.current;
            pendingPreloadRef.current = null;
            if (old) doPreload(old, url, isLocal);
          }
        }
      });
    } else {
      ctx?.resume();
      active.play().catch(() => {});
    }
  }, [doPreload]);

  const updateEQ = useCallback((bands: number[]) => {
    const nodes = eqNodesRef.current;
    for (let i = 0; i < nodes.length; i++) {
      nodes[i].gain.value = bands[i] ?? 0;
    }
  }, []);

  return useMemo(() => ({
    audioRefA,
    audioRefB,
    activeAudioRef,
    analyserRef,
    analyserNode,
    ctxRef,
    nextReady,
    ensureContext,
    loadAndPlay,
    preloadNext,
    crossfadeToNext,
    cancelCrossfade,
    quickFinishCrossfade,
    pause,
    resume,
    updateEQ,
  }), [analyserNode, ensureContext, loadAndPlay, preloadNext, crossfadeToNext, cancelCrossfade, quickFinishCrossfade, pause, resume, updateEQ]);
}
