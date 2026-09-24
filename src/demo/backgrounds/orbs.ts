import type { BgRenderer, BgRendererFactory } from "./types";
import { sizeScale } from "./types";

const TAU = Math.PI * 2;

interface Orb {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  colorIdx: number;
}

function parseColors(s: string): string[] {
  return s.split(",").map((c) => c.trim()).filter(Boolean);
}

function initOrbs(count: number, minSize: number, maxSize: number, w: number, h: number): Orb[] {
  const orbs: Orb[] = [];
  for (let i = 0; i < count; i++) {
    const angle = Math.random() * TAU;
    orbs.push({
      x: Math.random() * (w || 1920),
      y: Math.random() * (h || 1080),
      vx: Math.cos(angle),
      vy: Math.sin(angle),
      size: minSize + Math.random() * (maxSize - minSize),
      colorIdx: Math.floor(Math.random() * 100),
    });
  }
  return orbs;
}

/** Pre-render a soft radial glow to an offscreen canvas. */
function renderOrbTexture(color: string, texSize: number): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = texSize;
  c.height = texSize;
  const ctx = c.getContext("2d")!;
  const r = texSize / 2;
  const grad = ctx.createRadialGradient(r, r, 0, r, r, r);
  // Soft multi-stop falloff replaces the expensive per-frame ctx.filter blur
  grad.addColorStop(0, color);
  grad.addColorStop(0.3, color);
  grad.addColorStop(0.6, color + "88");
  grad.addColorStop(0.85, color + "22");
  grad.addColorStop(1, "transparent");
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, texSize, texSize);
  return c;
}

export const createOrbs: BgRendererFactory = (opts): BgRenderer => {
  let count = opts.count ?? 8;
  let speed = opts.speed ?? 0.5;
  let minSize = opts.minSize ?? 60;
  let maxSize = opts.maxSize ?? 200;
  let colors = parseColors(opts.colors ?? "#cc3333,#4a9eff,#4daa5c,#e06088");
  let orbs = initOrbs(count, minSize, maxSize, 0, 0);

  // Pre-rendered textures per colour, keyed by colour string
  const TEX_SIZE = 256;
  let textures: Map<string, HTMLCanvasElement> = new Map();
  function ensureTexture(color: string): HTMLCanvasElement {
    let tex = textures.get(color);
    if (!tex) {
      tex = renderOrbTexture(color, TEX_SIZE);
      textures.set(color, tex);
    }
    return tex;
  }
  // Pre-warm
  for (const c of colors) ensureTexture(c);

  return {
    draw(ctx, w, h, dt) {
      const ss = sizeScale(w, h);
      const spd = speed * dt * 60;
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      ctx.globalAlpha = 0.4;
      for (const orb of orbs) {
        const r = orb.size * ss;
        orb.x += orb.vx * spd;
        orb.y += orb.vy * spd;
        const ww = w + 2 * r;
        const wh = h + 2 * r;
        orb.x = ((orb.x + r) % ww + ww) % ww - r;
        orb.y = ((orb.y + r) % wh + wh) % wh - r;
        const color = colors[orb.colorIdx % colors.length];
        const tex = ensureTexture(color);
        const d = r * 2;
        ctx.drawImage(tex, orb.x - r, orb.y - r, d, d);
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newCount = o.count ?? count;
      const newMin = o.minSize ?? minSize;
      const newMax = o.maxSize ?? maxSize;
      speed = o.speed ?? speed;
      if (o.colors != null) {
        colors = parseColors(o.colors);
        textures = new Map();
        for (const c of colors) ensureTexture(c);
      }
      if (newCount !== count || newMin !== minSize || newMax !== maxSize) {
        count = newCount;
        minSize = newMin;
        maxSize = newMax;
        orbs = initOrbs(count, minSize, maxSize, 1920, 1080);
      }
    },
    destroy() {
      orbs.length = 0;
      textures.clear();
    },
  };
};
