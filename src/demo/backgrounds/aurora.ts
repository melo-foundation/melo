import type { BgRenderer, BgRendererFactory } from "./types";

const TAU = Math.PI * 2;

function parseColors(s: string): string[] {
  return s.split(",").map((c) => c.trim()).filter(Boolean);
}

export const createAurora: BgRendererFactory = (opts): BgRenderer => {
  let bands = opts.bands ?? 4;
  let speed = opts.speed ?? 0.5;
  let colors = parseColors(opts.colors ?? "#00ff88,#4a9eff,#cc3333,#e06088");
  let intensity = opts.intensity ?? 0.6;
  let time = 0;

  let phases: number[] = [];
  let freqs: number[] = [];
  function initBands() {
    phases = [];
    freqs = [];
    for (let i = 0; i < bands; i++) {
      phases.push(i * 1.3 + Math.random() * 0.5);
      freqs.push(0.8 + i * 0.4 + Math.random() * 0.3);
    }
  }
  initBands();

  // Gradient cache — keyed by baseY and bandHeight (change on resize, not per frame)
  let cachedGrads: CanvasGradient[] = [];
  let cachedCtx: CanvasRenderingContext2D | null = null;
  let cachedH = 0;
  let cachedBands = 0;

  function rebuildGradients(ctx: CanvasRenderingContext2D, h: number) {
    cachedGrads = [];
    cachedCtx = ctx;
    cachedH = h;
    cachedBands = bands;
    const bandHeight = h * 0.25;
    for (let b = 0; b < bands; b++) {
      const baseY = h * 0.25 + (b / bands) * h * 0.4;
      const color = colors[b % colors.length];
      const grad = ctx.createLinearGradient(0, baseY - bandHeight, 0, baseY + bandHeight);
      grad.addColorStop(0, "transparent");
      grad.addColorStop(0.4, color);
      grad.addColorStop(0.6, color);
      grad.addColorStop(1, "transparent");
      cachedGrads.push(grad);
    }
  }

  return {
    draw(ctx, w, h, dt) {
      time += dt * speed;

      // Rebuild gradients if canvas height or band count changed
      if (ctx !== cachedCtx || h !== cachedH || bands !== cachedBands) {
        rebuildGradients(ctx, h);
      }

      ctx.save();
      ctx.globalAlpha = intensity;
      ctx.globalCompositeOperation = "lighter";

      const bandHeight = h * 0.25;
      const dpr = window.devicePixelRatio || 1;
      const steps = Math.max(20, Math.floor((w / dpr) / 40));
      const dx = w / steps;

      for (let b = 0; b < bands; b++) {
        const baseY = h * 0.25 + (b / bands) * h * 0.4;
        const phase = phases[b] + time;
        const freq = freqs[b];
        const amp1 = bandHeight * 0.5;
        const amp2 = bandHeight * 0.3;
        const freqTau = freq * TAU;
        const freq17 = freq * 1.7;
        const phase07 = phase * 0.7;

        ctx.beginPath();
        ctx.moveTo(0, h);
        for (let i = 0; i <= steps; i++) {
          const x = i * dx;
          const t = x / w;
          const y = baseY +
            Math.sin(t * freqTau + phase) * amp1 +
            Math.sin(t * freq17 + phase07) * amp2;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(w, h);
        ctx.closePath();

        ctx.fillStyle = cachedGrads[b];
        ctx.fill();
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newBands = o.bands ?? bands;
      speed = o.speed ?? speed;
      intensity = o.intensity ?? intensity;
      if (o.colors != null) {
        colors = parseColors(o.colors);
        // Force gradient rebuild on next frame
        cachedH = 0;
      }
      if (newBands !== bands) {
        bands = newBands;
        initBands();
        cachedH = 0; // Force gradient rebuild
      }
    },
    destroy() {},
  };
};
