import type { BgRenderer, BgRendererFactory } from "./types";
import { sizeScale } from "./types";

function parseColors(s: string): string[] {
  return s.split(",").map((c) => c.trim()).filter(Boolean);
}

interface Layer {
  freq: number;
  phase: number;
  phaseSpeed: number;
  colorIdx: number;
}

function initLayers(count: number): Layer[] {
  const out: Layer[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      freq: 1.5 + i * 0.6 + Math.random() * 0.5,
      phase: Math.random() * Math.PI * 2,
      phaseSpeed: 0.8 + i * 0.3 + Math.random() * 0.4,
      colorIdx: i,
    });
  }
  return out;
}

export const createWaves: BgRendererFactory = (opts): BgRenderer => {
  let layerCount = opts.layers ?? 4;
  let speed = opts.speed ?? 0.5;
  let amplitude = opts.amplitude ?? 60;
  let colors = parseColors(opts.colors ?? "#cc3333,#4a9eff,#4daa5c");
  let position = opts.position ?? 0.7;
  let layers = initLayers(layerCount);
  let time = 0;

  return {
    draw(ctx, w, h, dt) {
      time += dt * speed;
      const ss = sizeScale(w, h);
      const amp = amplitude * ss;
      const baseY = h * position;
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
          const y =
            baseY +
            Math.sin(t * layer.freq * Math.PI * 2 + phase) * amp +
            Math.sin(t * layer.freq * 0.7 + phase * 1.3) * amp * 0.3;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(w, h);
        ctx.closePath();

        ctx.globalAlpha = 0.25;
        ctx.fillStyle = color;
        ctx.fill();
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newCount = o.layers ?? layerCount;
      speed = o.speed ?? speed;
      amplitude = o.amplitude ?? amplitude;
      position = o.position ?? position;
      if (o.colors != null) colors = parseColors(o.colors);
      if (newCount !== layerCount) {
        layerCount = newCount;
        layers = initLayers(layerCount);
      }
    },
    destroy() {
      layers.length = 0;
    },
  };
};
