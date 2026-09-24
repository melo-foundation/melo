import type { BgRenderer, BgRendererFactory } from "./types";

const TAU = Math.PI * 2;

interface Blob {
  cx: number;
  cy: number;
  phaseX: number;
  phaseY: number;
  freqX: number;
  freqY: number;
  color: string;
}

function parseColors(s: string): string[] {
  return s.split(",").map((c) => c.trim()).filter(Boolean);
}

function initBlobs(colors: string[]): Blob[] {
  const count = Math.max(4, colors.length);
  const out: Blob[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      cx: 0.2 + Math.random() * 0.6,
      cy: 0.2 + Math.random() * 0.6,
      phaseX: Math.random() * TAU,
      phaseY: Math.random() * TAU,
      freqX: 0.3 + Math.random() * 0.5,
      freqY: 0.2 + Math.random() * 0.4,
      color: colors[i % colors.length],
    });
  }
  return out;
}

/** Pre-render a soft radial blob to an offscreen canvas. */
function renderBlobTexture(color: string, texSize: number): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = texSize;
  c.height = texSize;
  const ctx = c.getContext("2d")!;
  const r = texSize / 2;
  const grad = ctx.createRadialGradient(r, r, 0, r, r, r);
  grad.addColorStop(0, color);
  grad.addColorStop(0.5, color + "88");
  grad.addColorStop(1, "transparent");
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, texSize, texSize);
  return c;
}

export const createMesh: BgRendererFactory = (opts): BgRenderer => {
  let speed = opts.speed ?? 0.3;
  let blobSize = opts.blobSize ?? 0.6;
  let colors = parseColors(opts.colors ?? "#cc3333,#4a9eff,#4daa5c,#e06088");
  let blobs = initBlobs(colors);
  let time = 0;

  // Pre-rendered textures per colour
  const TEX_SIZE = 256;
  let textures: Map<string, HTMLCanvasElement> = new Map();
  function ensureTexture(color: string): HTMLCanvasElement {
    let tex = textures.get(color);
    if (!tex) {
      tex = renderBlobTexture(color, TEX_SIZE);
      textures.set(color, tex);
    }
    return tex;
  }
  for (const c of colors) ensureTexture(c);

  return {
    draw(ctx, w, h, dt) {
      time += dt * speed;
      const radius = Math.max(w, h) * blobSize * 0.5;
      const d = radius * 2;
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      ctx.globalAlpha = 0.5;
      for (const b of blobs) {
        const x = (b.cx + Math.sin(time * b.freqX + b.phaseX) * 0.3) * w;
        const y = (b.cy + Math.cos(time * b.freqY + b.phaseY) * 0.3) * h;
        const tex = ensureTexture(b.color);
        ctx.drawImage(tex, x - radius, y - radius, d, d);
      }
      ctx.restore();
    },
    updateOptions(o) {
      speed = o.speed ?? speed;
      blobSize = o.blobSize ?? blobSize;
      if (o.colors != null) {
        colors = parseColors(o.colors);
        textures = new Map();
        for (const c of colors) ensureTexture(c);
        blobs = initBlobs(colors);
      }
    },
    destroy() {
      blobs.length = 0;
      textures.clear();
    },
  };
};
