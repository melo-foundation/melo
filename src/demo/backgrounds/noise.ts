import type { BgRenderer, BgRendererFactory } from "./types";

export const createNoise: BgRendererFactory = (opts): BgRenderer => {
  let scale = opts.scale ?? 4;
  let speed = opts.speed ?? 2;
  let intensity = opts.intensity ?? 0.05;
  let monochrome = opts.monochrome ?? true;

  let offCanvas: OffscreenCanvas | null = null;
  let offCtx: OffscreenCanvasRenderingContext2D | null = null;
  let imgData: ImageData | null = null;
  let noiseW = 0;
  let noiseH = 0;
  let timer = 0;

  function ensureBuffer(w: number, h: number) {
    const nw = Math.ceil(w / scale);
    const nh = Math.ceil(h / scale);
    if (nw === noiseW && nh === noiseH && offCanvas) return;
    noiseW = nw;
    noiseH = nh;
    offCanvas = new OffscreenCanvas(nw, nh);
    offCtx = offCanvas.getContext("2d")!;
    imgData = offCtx.createImageData(nw, nh);
  }

  function randomize() {
    if (!imgData) return;
    const d = imgData.data;
    if (monochrome) {
      for (let i = 0; i < d.length; i += 4) {
        const v = Math.floor(Math.random() * 256);
        d[i] = v;
        d[i + 1] = v;
        d[i + 2] = v;
        d[i + 3] = 255;
      }
    } else {
      for (let i = 0; i < d.length; i += 4) {
        d[i] = Math.floor(Math.random() * 256);
        d[i + 1] = Math.floor(Math.random() * 256);
        d[i + 2] = Math.floor(Math.random() * 256);
        d[i + 3] = 255;
      }
    }
  }

  return {
    draw(ctx, w, h, dt) {
      ensureBuffer(w, h);
      if (!offCanvas || !offCtx || !imgData) return;

      timer += dt * speed;
      if (timer >= 0.03) {
        timer = 0;
        randomize();
        offCtx.putImageData(imgData, 0, 0);
      }

      ctx.save();
      ctx.globalAlpha = intensity;
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(offCanvas, 0, 0, w, h);
      ctx.restore();
    },
    updateOptions(o) {
      const newScale = o.scale ?? scale;
      speed = o.speed ?? speed;
      intensity = o.intensity ?? intensity;
      monochrome = o.monochrome ?? monochrome;
      if (newScale !== scale) {
        scale = newScale;
        noiseW = 0;
        noiseH = 0;
      }
    },
    destroy() {
      offCanvas = null;
      offCtx = null;
      imgData = null;
    },
  };
};
