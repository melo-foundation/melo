import type { BgRenderer, BgRendererFactory } from "./types";
import { sizeScale, countForArea, BUFFER_MULT } from "./types";

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
}

function initParticles(count: number, w: number, h: number): Particle[] {
  const out: Particle[] = [];
  for (let i = 0; i < count; i++) {
    const angle = Math.random() * Math.PI * 2;
    const v = 0.2 + Math.random() * 0.8;
    out.push({
      x: Math.random() * (w || 1920),
      y: Math.random() * (h || 1080),
      vx: Math.cos(angle) * v,
      vy: Math.sin(angle) * v,
    });
  }
  return out;
}

export const createParticles: BgRendererFactory = (opts): BgRenderer => {
  let count = opts.count ?? 80;
  let speed = opts.speed ?? 0.5;
  let size = opts.size ?? 2;
  let color = opts.color ?? "#ffffff";
  let lines = opts.lines ?? true;
  let lineDistance = opts.lineDistance ?? 120;
  let particles = initParticles(count * BUFFER_MULT, 0, 0);

  return {
    draw(ctx, w, h, dt) {
      const ss = sizeScale(w, h);
      const n = Math.min(particles.length, countForArea(count, w, h));
      const spd = speed * dt * 60;
      for (let i = 0; i < n; i++) {
        const p = particles[i];
        p.x += p.vx * spd;
        p.y += p.vy * spd;
        p.x = ((p.x % w) + w) % w;
        p.y = ((p.y % h) + h) % h;
      }

      const sz = size * ss;
      ctx.save();
      ctx.fillStyle = color;
      for (let i = 0; i < n; i++) {
        const p = particles[i];
        ctx.beginPath();
        ctx.arc(p.x, p.y, sz, 0, Math.PI * 2);
        ctx.fill();
      }

      if (lines) {
        const ld = lineDistance * ss;
        const dist2 = ld * ld;
        ctx.strokeStyle = color;
        ctx.lineWidth = 0.5;
        for (let i = 0; i < n; i++) {
          const a = particles[i];
          for (let j = i + 1; j < n; j++) {
            const b = particles[j];
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < dist2) {
              ctx.globalAlpha = 1 - Math.sqrt(d2) / ld;
              ctx.beginPath();
              ctx.moveTo(a.x, a.y);
              ctx.lineTo(b.x, b.y);
              ctx.stroke();
            }
          }
        }
      }
      ctx.restore();
    },
    updateOptions(o) {
      const newCount = o.count ?? count;
      speed = o.speed ?? speed;
      size = o.size ?? size;
      color = o.color ?? color;
      lines = o.lines ?? lines;
      lineDistance = o.lineDistance ?? lineDistance;
      if (newCount !== count) {
        count = newCount;
        particles = initParticles(count * BUFFER_MULT, 1920, 1080);
      }
    },
    destroy() {
      particles.length = 0;
    },
  };
};
