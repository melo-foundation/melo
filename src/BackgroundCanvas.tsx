import { useEffect, useRef } from "react";

/* ── Bokeh circles ── */

interface Circle {
  x: number; y: number;
  vx: number; vy: number;
  size: number; alpha: number;
  colorIdx: number;
}

function initCircles(count: number, sizeRange: number): Circle[] {
  const out: Circle[] = [];
  for (let i = 0; i < count; i++) {
    const angle = Math.random() * Math.PI * 2;
    const v = 0.15 + Math.random() * 0.5;
    out.push({
      x: Math.random() * 1920, y: Math.random() * 1080,
      vx: Math.cos(angle) * v, vy: Math.sin(angle) * v,
      size: 30 + Math.random() * sizeRange,
      alpha: 0.06 + Math.random() * 0.12,
      colorIdx: Math.floor(Math.random() * 100),
    });
  }
  return out;
}

function drawBokeh(ctx: CanvasRenderingContext2D, w: number, h: number, dt: number, circles: Circle[], colors: string[]) {
  const ss = Math.pow((w * h) / (1920 * 1080), 0.25);
  const n = Math.min(circles.length, Math.max(1, Math.round(12 * Math.sqrt((w * h) / (1920 * 1080)))));
  const spd = 0.2 * dt * 60;
  ctx.save();
  for (let i = 0; i < n; i++) {
    const c = circles[i];
    c.x += c.vx * spd; c.y += c.vy * spd;
    const r = c.size * ss;
    const ww = w + 2 * r, wh = h + 2 * r;
    c.x = ((c.x + r) % ww + ww) % ww - r;
    c.y = ((c.y + r) % wh + wh) % wh - r;
    const color = colors[c.colorIdx % colors.length];
    ctx.globalAlpha = c.alpha;
    ctx.fillStyle = color;
    ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.fill();
    ctx.globalAlpha = c.alpha + 0.08;
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.stroke();
  }
  ctx.restore();
}

/* ── Waves ── */

interface WaveLayer {
  freq: number; phase: number;
  phaseSpeed: number; colorIdx: number;
}

function initLayers(count: number): WaveLayer[] {
  const out: WaveLayer[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      freq: 1.5 + i * 0.6 + Math.random() * 0.5,
      phase: Math.random() * Math.PI * 2,
      phaseSpeed: 0.5 + i * 0.2 + Math.random() * 0.3,
      colorIdx: i,
    });
  }
  return out;
}

function drawWaves(ctx: CanvasRenderingContext2D, w: number, h: number, time: number, layers: WaveLayer[], colors: string[]) {
  const ss = Math.pow((w * h) / (1920 * 1080), 0.25);
  const amp = 50 * ss;
  const baseY = h * 0.75;
  const steps = Math.max(20, Math.floor(w / 30));
  const dx = w / steps;
  ctx.save();
  for (const layer of layers) {
    const color = colors[layer.colorIdx % colors.length];
    const phase = layer.phase + time * layer.phaseSpeed;
    ctx.beginPath();
    ctx.moveTo(0, h);
    for (let i = 0; i <= steps; i++) {
      const x = i * dx;
      const t = x / w;
      const y = baseY
        + Math.sin(t * layer.freq * Math.PI * 2 + phase) * amp
        + Math.sin(t * layer.freq * 0.7 + phase * 1.3) * amp * 0.3;
      ctx.lineTo(x, y);
    }
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.globalAlpha = 0.15;
    ctx.fillStyle = color;
    ctx.fill();
  }
  ctx.restore();
}

/* ── Component ── */

export function BackgroundCanvas({ accent }: { accent: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const stateRef = useRef({
    circles: initCircles(48, 80),
    layers: initLayers(4),
    time: 0,
    lastFrame: 0,
  });

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let raf: number;
    const state = stateRef.current;

    function resize() {
      const dpr = window.devicePixelRatio || 1;
      canvas!.width = window.innerWidth * dpr;
      canvas!.height = window.innerHeight * dpr;
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    resize();
    window.addEventListener("resize", resize);
    state.lastFrame = performance.now();

    function frame(now: number) {
      const dt = Math.min((now - state.lastFrame) / 1000, 0.1);
      state.lastFrame = now;
      state.time += dt * 0.4;

      const w = window.innerWidth;
      const h = window.innerHeight;
      ctx!.clearRect(0, 0, w, h);

      // Use accent color + shifted variants for the effects
      const colors = [accent, accent + "88", "#ffffff"];

      drawBokeh(ctx!, w, h, dt, state.circles, colors);
      drawWaves(ctx!, w, h, state.time, state.layers, colors);

      raf = requestAnimationFrame(frame);
    }

    raf = requestAnimationFrame(frame);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
    };
  }, [accent]);

  return <canvas ref={canvasRef} className="bg-canvas" />;
}
