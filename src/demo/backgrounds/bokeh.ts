import type { BgRenderer, BgRendererFactory } from "./types";
import { sizeScale, countForArea, BUFFER_MULT } from "./types";

interface Circle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  alpha: number;
  colorIdx: number;
}

function parseColors(s: string): string[] {
  return s.split(",").map((c) => c.trim()).filter(Boolean);
}

function initCircles(count: number, sizeRange: number): Circle[] {
  const out: Circle[] = [];
  for (let i = 0; i < count; i++) {
    const angle = Math.random() * Math.PI * 2;
    const v = 0.2 + Math.random() * 0.8;
    out.push({
      x: Math.random() * 1920,
      y: Math.random() * 1080,
      vx: Math.cos(angle) * v,
      vy: Math.sin(angle) * v,
      size: 20 + Math.random() * sizeRange,
      alpha: 0.1 + Math.random() * 0.2,
      colorIdx: Math.floor(Math.random() * 100),
    });
  }
  return out;
}

export const createBokeh: BgRendererFactory = (opts): BgRenderer => {
  let count = opts.count ?? 15;
  let speed = opts.speed ?? 0.3;
  let sizeRange = opts.sizeRange ?? 60;
  let colors = parseColors(opts.colors ?? "#cc3333,#4a9eff,#e06088,#ffffff");
  let circles = initCircles(count * BUFFER_MULT, sizeRange);

  return {
    draw(ctx, w, h, dt) {
      const ss = sizeScale(w, h);
      const n = Math.min(circles.length, countForArea(count, w, h));
      const spd = speed * dt * 60;
      ctx.save();
      for (let i = 0; i < n; i++) {
        const c = circles[i];
        c.x += c.vx * spd;
        c.y += c.vy * spd;
        const r = c.size * ss;
        const ww = w + 2 * r;
        const wh = h + 2 * r;
        c.x = ((c.x + r) % ww + ww) % ww - r;
        c.y = ((c.y + r) % wh + wh) % wh - r;

        const color = colors[c.colorIdx % colors.length];
        ctx.globalAlpha = c.alpha;

        // Low-opacity fill
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
        ctx.fill();

        // Thin stroke ring
        ctx.globalAlpha = c.alpha + 0.15;
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newCount = o.count ?? count;
      const newSizeRange = o.sizeRange ?? sizeRange;
      speed = o.speed ?? speed;
      if (o.colors != null) colors = parseColors(o.colors);
      if (newCount !== count || newSizeRange !== sizeRange) {
        count = newCount;
        sizeRange = newSizeRange;
        circles = initCircles(count * BUFFER_MULT, sizeRange);
      }
    },
    destroy() {
      circles.length = 0;
    },
  };
};
