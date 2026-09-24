import { useRef, useEffect } from "react";
import { PROCEDURAL_REGISTRY, type BgRenderer } from "../backgrounds";

const PROCEDURAL_TYPES = new Set(Object.keys(PROCEDURAL_REGISTRY));

export default function BackgroundLayer({ config }: { config: BackgroundConfig }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapperRef = useRef<HTMLDivElement>(null);
  const rendererRef = useRef<BgRenderer | null>(null);
  const rafRef = useRef<number>(0);

  const isProcedural = PROCEDURAL_TYPES.has(config.type);

  // Procedural canvas lifecycle
  useEffect(() => {
    if (!isProcedural) return;
    const canvas = canvasRef.current;
    if (!canvas) return;

    const entry = PROCEDURAL_REGISTRY[config.type];
    if (!entry) return;

    // Merge defaults with user options
    const opts: Record<string, any> = {};
    for (const [k, def] of Object.entries(entry.optionDefs)) {
      opts[k] = config.options[k] ?? def.default;
    }

    const renderer = entry.create(opts);
    rendererRef.current = renderer;
    let alive = true;

    const ctx = canvas.getContext("2d")!;
    let lastTime = 0;

    // Compute canvas pixel dimensions
    const updateCanvasSize = () => {
      const wrapper = wrapperRef.current;
      if (!wrapper) return;
      const { clientWidth: cw, clientHeight: ch } = wrapper;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(cw * dpr);
      canvas.height = Math.round(ch * dpr);
    };

    // ResizeObserver for DPR-aware sizing
    const ro = new ResizeObserver(() => updateCanvasSize());
    ro.observe(canvas.parentElement || canvas);
    updateCanvasSize();

    let hidden = document.hidden;
    const onVisibility = () => {
      hidden = document.hidden;
      if (!hidden && alive) {
        cancelAnimationFrame(rafRef.current);
        lastTime = 0;
        rafRef.current = requestAnimationFrame(animate);
      }
    };
    document.addEventListener("visibilitychange", onVisibility);

    const animate = (time: number) => {
      if (!alive || hidden) return;
      const dt = lastTime ? Math.min((time - lastTime) / 1000, 0.1) : 0.016;
      lastTime = time;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      renderer.draw(ctx, canvas.width, canvas.height, dt);
      rafRef.current = requestAnimationFrame(animate);
    };
    rafRef.current = requestAnimationFrame(animate);

    return () => {
      alive = false;
      cancelAnimationFrame(rafRef.current);
      document.removeEventListener("visibilitychange", onVisibility);
      ro.disconnect();
      renderer.destroy();
      rendererRef.current = null;
    };
  }, [config.type, isProcedural]); // eslint-disable-line react-hooks/exhaustive-deps

  // Update options without recreating renderer
  useEffect(() => {
    if (!isProcedural || !rendererRef.current) return;
    const entry = PROCEDURAL_REGISTRY[config.type];
    if (!entry) return;
    const opts: Record<string, any> = {};
    for (const [k, def] of Object.entries(entry.optionDefs)) {
      opts[k] = config.options[k] ?? def.default;
    }
    rendererRef.current.updateOptions(opts);
  }, [config.options, config.type, isProcedural]);

  if (config.type === "none") return null;

  const hasTransform = (config.scale ?? 1) !== 1 || (config.positionX ?? 0) !== 0 || (config.positionY ?? 0) !== 0;
  const hasBlend = config.blendMode && config.blendMode !== "normal";
  const wrapperStyle: React.CSSProperties = {
    position: "absolute",
    inset: 0,
    zIndex: 0,
    pointerEvents: "none",
    // When using blend modes, apply opacity on inner content to avoid
    // opacity creating an isolated compositing group that blocks blending
    opacity: hasBlend ? undefined : config.opacity,
    filter: config.blur > 0 ? `blur(${config.blur}px)` : undefined,
    mixBlendMode: (hasBlend ? config.blendMode : undefined) as React.CSSProperties["mixBlendMode"],
    overflow: "hidden",
    animation: "bg-fade-in 400ms ease",
  };
  const innerOpacity = hasBlend ? config.opacity : undefined;
  const innerTransform = hasTransform
    ? `scale(${config.scale ?? 1}) translate(${config.positionX ?? 0}%, ${config.positionY ?? 0}%)`
    : undefined;

  const contentSize: React.CSSProperties = { width: "100%", height: "100%", transform: innerTransform };

  if (config.type === "gradient") {
    return (
      <div ref={wrapperRef} style={wrapperStyle}>
        <div
          style={{
            ...contentSize,
            background: config.gradient || "none",
            opacity: innerOpacity,
          }}
        />
      </div>
    );
  }

  // Procedural types — render canvas
  if (isProcedural) {
    return (
      <div ref={wrapperRef} style={wrapperStyle}>
        <canvas ref={canvasRef} style={{ ...contentSize, display: "block", opacity: innerOpacity }} />
      </div>
    );
  }

  return null;
}
