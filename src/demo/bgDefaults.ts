import { PROCEDURAL_REGISTRY } from "./backgrounds";

/* ── Colour conversion helpers ── */

export function hexToHsl(hex: string): [number, number, number] {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h = 0, s = 0;
  const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
    else if (max === g) h = ((b - r) / d + 2) / 6;
    else h = ((r - g) / d + 4) / 6;
  }
  return [h * 360, s * 100, l * 100];
}

export function hslToHex(h: number, s: number, l: number): string {
  h = ((h % 360) + 360) % 360;
  s = Math.max(0, Math.min(100, s)) / 100;
  l = Math.max(0, Math.min(100, l)) / 100;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => {
    const k = (n + h / 30) % 12;
    const color = l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1);
    return Math.round(255 * color).toString(16).padStart(2, "0");
  };
  return `#${f(0)}${f(8)}${f(4)}`;
}

/**
 * Generate `count` harmonious colours derived from a base accent hex.
 * Uses analogous + split-complementary distribution for natural palettes.
 */
export function themeColors(accent: string, count: number): string[] {
  const [h, s, l] = hexToHsl(accent);
  if (count <= 1) return [accent];
  if (count === 2) return [
    accent,
    hslToHex(h + 150, s * 0.75, l),
  ];
  if (count === 3) return [
    accent,
    hslToHex(h + 45, s * 0.85, Math.min(l * 1.15, 85)),
    hslToHex(h + 200, s * 0.7, l),
  ];
  // 4 colours: accent, analogous, split-complement pair
  const base: string[] = [
    accent,
    hslToHex(h + 35, s * 0.85, Math.min(l * 1.1, 85)),
    hslToHex(h + 160, s * 0.7, l * 0.95),
    hslToHex(h + 210, s * 0.75, Math.min(l * 1.05, 80)),
  ];
  // Extra colours if needed
  for (let i = 4; i < count; i++) {
    base.push(hslToHex(h + 60 * i, s * 0.7, l));
  }
  return base;
}

/** Hardcoded demo defaults per background type (options + opacity/blur). */
const DEMO_BG_DEFAULTS: Record<string, { options: Record<string, number | string | boolean>; opacity: number; blur: number; colorCount: number }> = {
  bokeh:  { options: { count: 15, speed: 0.3, sizeRange: 140 }, opacity: 1, blur: 2, colorCount: 4 },
  waves:  { options: { layers: 4, speed: 0.4, amplitude: 100, position: 0.8 }, opacity: 0.8, blur: 4, colorCount: 3 },
  mesh:   { options: { speed: 0.1, blobSize: 0.6 }, opacity: 0.4, blur: 0, colorCount: 5 },
};

/** Build default options for a procedural bg type using theme-derived colours. */
export function defaultBgOptions(
  type: string,
  accent: string,
): Record<string, number | string | boolean> {
  const demo = DEMO_BG_DEFAULTS[type];
  if (demo) {
    const opts = { ...demo.options };
    // Inject theme-derived colours
    const entry = PROCEDURAL_REGISTRY[type];
    if (entry) {
      for (const [key, def] of Object.entries(entry.optionDefs)) {
        if (def.type === "colors" || def.type === "color") {
          opts[key] = themeColors(accent, demo.colorCount).join(",");
        }
      }
    }
    return opts;
  }
  const entry = PROCEDURAL_REGISTRY[type];
  if (!entry) return {};
  const opts: Record<string, number | string | boolean> = {};
  for (const [key, def] of Object.entries(entry.optionDefs)) {
    if (def.type === "colors" || def.type === "color") {
      const count = String(def.default).split(",").length;
      opts[key] = themeColors(accent, count).join(",");
    } else {
      opts[key] = def.default;
    }
  }
  return opts;
}

/** Get the default opacity + blur for a bg type. */
export function defaultBgConfig(type: string): { opacity: number; blur: number } {
  const demo = DEMO_BG_DEFAULTS[type];
  return demo ? { opacity: demo.opacity, blur: demo.blur } : { opacity: 1, blur: 0 };
}

/** Rewrite only the colour options in an existing bg options object. */
export function recolorBgOptions(
  type: string,
  existing: Record<string, number | string | boolean>,
  accent: string,
): Record<string, number | string | boolean> {
  const entry = PROCEDURAL_REGISTRY[type];
  if (!entry) return existing;
  const opts = { ...existing };
  for (const [key, def] of Object.entries(entry.optionDefs)) {
    if (def.type === "colors" || def.type === "color") {
      const count = String(def.default).split(",").length;
      opts[key] = themeColors(accent, count).join(",");
    }
  }
  return opts;
}

/** Build a theme-derived default gradient string. */
export function defaultGradient(accent: string, bgBase: string): string {
  return `linear-gradient(135deg, ${bgBase} 0%, ${accent} 100%)`;
}
