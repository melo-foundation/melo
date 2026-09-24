export interface BgRenderer {
  draw(ctx: CanvasRenderingContext2D, w: number, h: number, dt: number): void;
  updateOptions(options: Record<string, any>): void;
  destroy(): void;
  setAnalyser?(node: AnalyserNode): void;
  // Preset control (milkdrop)
  nextPreset?(): void;
  prevPreset?(): void;
  loadPreset?(name: string): void;
  getPresetList?(): string[];
  getCurrentPreset?(): string;
}

export type BgRendererFactory = (options: Record<string, any>) => BgRenderer;

export interface OptionDef {
  type: "number" | "boolean" | "colors" | "color";
  label: string;
  min?: number;
  max?: number;
  step?: number;
  default: any;
}

export interface ProceduralEntry {
  label: string;
  optionDefs: Record<string, OptionDef>;
  create: BgRendererFactory;
}

/* ---- Density-scaling helpers ---- */

/** Reference CSS area (1920×1080). */
const REF_AREA = 1920 * 1080;

/** CSS-pixel area of the canvas (divides out devicePixelRatio). */
function cssArea(w: number, h: number): number {
  const dpr = window.devicePixelRatio || 1;
  return (w / dpr) * (h / dpr);
}

/**
 * Scale factor for 1-D measurements (sizes, distances).
 * Uses fourth-root of area ratio for a gentle curve.
 */
export function sizeScale(w: number, h: number): number {
  return Math.pow(cssArea(w, h) / REF_AREA, 0.25);
}

/**
 * Area-proportional element count (≥ 1).
 * Uses square-root of area ratio so counts don't drop too fast.
 */
export function countForArea(base: number, w: number, h: number): number {
  return Math.max(1, Math.round(base * Math.sqrt(cssArea(w, h) / REF_AREA)));
}

/** Pre-allocate this multiple of base count so the array can serve larger canvases. */
export const BUFFER_MULT = 4;
