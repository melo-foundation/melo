export type BgType = "none" | "gradient" | "orbs" | "aurora" | "particles" | "starfield" | "mesh" | "bokeh" | "waves" | "noise";

export interface BackgroundConfig {
  type: BgType;
  gradient?: string;
  opacity: number;
  blur: number;
  blendMode?: string;
  options: Record<string, number | string | boolean>;
  scale?: number;
  positionX?: number;
  positionY?: number;
}

export interface ThemePalette {
  accent: string;
  accentHover: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  textMuted: string;
  bgBase: string;
  bgSurface: string;
  bgElevated: string;
  bgOverlay: string;
  bgHover: string;
  border: string;
  borderLight: string;
  success: string;
}

export interface DemoSettings {
  bgOpacity: number;
  background?: BackgroundConfig;
  glyphPreset: string;
  buttonShape: "sharp" | "rounded" | "pill";
}
