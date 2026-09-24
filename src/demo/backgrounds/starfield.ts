import type { BgRenderer, BgRendererFactory } from "./types";
import { sizeScale, countForArea, BUFFER_MULT } from "./types";

interface Star {
  x: number;
  y: number;
  size: number;
  phase: number;
  rate: number;
  r: number;
  g: number;
  b: number;
}

function initStars(count: number, sizeRange: number, colored: boolean): Star[] {
  const out: Star[] = [];
  for (let i = 0; i < count; i++) {
    let r = 255, g = 255, b = 255;
    if (colored) {
      const warm = Math.random() > 0.5;
      if (warm) {
        r = 220 + Math.floor(Math.random() * 35);
        g = 180 + Math.floor(Math.random() * 60);
        b = 150 + Math.floor(Math.random() * 60);
      } else {
        r = 160 + Math.floor(Math.random() * 60);
        g = 190 + Math.floor(Math.random() * 50);
        b = 220 + Math.floor(Math.random() * 35);
      }
    }
    out.push({
      x: Math.random(),
      y: Math.random(),
      size: 0.5 + Math.random() * sizeRange,
      phase: Math.random() * Math.PI * 2,
      rate: 1.5 + Math.random() * 3,
      r, g, b,
    });
  }
  return out;
}

export const createStarfield: BgRendererFactory = (opts): BgRenderer => {
  let count = opts.count ?? 200;
  let twinkle = opts.twinkle ?? true;
  let sizeRange = opts.sizeRange ?? 2;
  let drift = opts.drift ?? 0.1;
  let colored = opts.colored ?? false;
  let stars = initStars(count * BUFFER_MULT, sizeRange, colored);
  let time = 0;

  return {
    draw(ctx, w, h, dt) {
      time += dt;
      const ss = sizeScale(w, h);
      const n = Math.min(stars.length, countForArea(count, w, h));
      ctx.save();
      for (let i = 0; i < n; i++) {
        const s = stars[i];
        if (drift > 0) {
          s.x += drift * 0.0001 * dt * 60;
          if (s.x > 1) s.x -= 1;
        }
        const alpha = twinkle
          ? 0.4 + 0.6 * ((Math.sin(time * s.rate + s.phase) + 1) * 0.5)
          : 0.9;
        ctx.globalAlpha = alpha;
        ctx.fillStyle = `rgb(${s.r},${s.g},${s.b})`;
        ctx.beginPath();
        ctx.arc(s.x * w, s.y * h, s.size * ss, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newCount = o.count ?? count;
      twinkle = o.twinkle ?? twinkle;
      sizeRange = o.sizeRange ?? sizeRange;
      drift = o.drift ?? drift;
      const newColored = o.colored ?? colored;
      if (newCount !== count || newColored !== colored) {
        count = newCount;
        colored = newColored;
        stars = initStars(count * BUFFER_MULT, sizeRange, colored);
      }
    },
    destroy() {
      stars.length = 0;
    },
  };
};
