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

export interface LandingTheme {
  id: string;
  name: string;
  palette: ThemePalette;
  family: "dark" | "light";
}

// ── Dark themes ──

const darkGlass: LandingTheme = {
  id: "dark-default",
  name: "Dark Glass",
  family: "dark",
  palette: {
    accent: "#cc3333",
    accentHover: "#dd4444",
    textPrimary: "#e0e0e0",
    textSecondary: "#888888",
    textTertiary: "#666666",
    textMuted: "#aaaaaa",
    bgBase: "#0f0f0f",
    bgSurface: "#151515",
    bgElevated: "#1a1a1a",
    bgOverlay: "#222222",
    bgHover: "#333333",
    border: "#2a2a2a",
    borderLight: "#444444",
    success: "#4caf50",
  },
};

const midnightBlue: LandingTheme = {
  id: "midnight-blue",
  name: "Midnight Blue",
  family: "dark",
  palette: {
    accent: "#4a9eff",
    accentHover: "#6ab0ff",
    textPrimary: "#d8e0ec",
    textSecondary: "#7a8899",
    textTertiary: "#566070",
    textMuted: "#99a5b4",
    bgBase: "#0a1018",
    bgSurface: "#0e1520",
    bgElevated: "#131c28",
    bgOverlay: "#1a2535",
    bgHover: "#283848",
    border: "#1e2a3a",
    borderLight: "#334466",
    success: "#4caf50",
  },
};

const rose: LandingTheme = {
  id: "rose",
  name: "Rose",
  family: "dark",
  palette: {
    accent: "#e06088",
    accentHover: "#e880a0",
    textPrimary: "#ece0e4",
    textSecondary: "#99808a",
    textTertiary: "#705060",
    textMuted: "#b4909a",
    bgBase: "#150a10",
    bgSurface: "#1c0e15",
    bgElevated: "#22141c",
    bgOverlay: "#2e1a24",
    bgHover: "#402838",
    border: "#301a24",
    borderLight: "#503040",
    success: "#4caf50",
  },
};

const charcoal: LandingTheme = {
  id: "charcoal",
  name: "Charcoal",
  family: "dark",
  palette: {
    accent: "#e07838",
    accentHover: "#e89050",
    textPrimary: "#d8d0c8",
    textSecondary: "#908880",
    textTertiary: "#686058",
    textMuted: "#a89888",
    bgBase: "#1c1a18",
    bgSurface: "#222018",
    bgElevated: "#2a2820",
    bgOverlay: "#343028",
    bgHover: "#443e34",
    border: "#302c24",
    borderLight: "#504838",
    success: "#6aad3a",
  },
};

const forest: LandingTheme = {
  id: "forest",
  name: "Forest",
  family: "dark",
  palette: {
    accent: "#4daa5c",
    accentHover: "#60c070",
    textPrimary: "#d8e4d8",
    textSecondary: "#80987a",
    textTertiary: "#58705a",
    textMuted: "#98b090",
    bgBase: "#0c120c",
    bgSurface: "#101810",
    bgElevated: "#162016",
    bgOverlay: "#1e2a1e",
    bgHover: "#2c3c2c",
    border: "#1e2c1e",
    borderLight: "#385038",
    success: "#4caf50",
  },
};

const oledBlack: LandingTheme = {
  id: "oled-black",
  name: "OLED Black",
  family: "dark",
  palette: {
    accent: "#cc3333",
    accentHover: "#dd4444",
    textPrimary: "#e0e0e0",
    textSecondary: "#777777",
    textTertiary: "#555555",
    textMuted: "#999999",
    bgBase: "#000000",
    bgSurface: "#080808",
    bgElevated: "#0e0e0e",
    bgOverlay: "#161616",
    bgHover: "#222222",
    border: "#1a1a1a",
    borderLight: "#333333",
    success: "#4caf50",
  },
};

// ── Light themes ──

const light: LandingTheme = {
  id: "light",
  name: "Light",
  family: "light",
  palette: {
    accent: "#2870cc",
    accentHover: "#1e5caa",
    textPrimary: "#1a1a1a",
    textSecondary: "#555555",
    textTertiary: "#888888",
    textMuted: "#666666",
    bgBase: "#f5f5f5",
    bgSurface: "#ebebeb",
    bgElevated: "#e0e0e0",
    bgOverlay: "#d6d6d6",
    bgHover: "#c8c8c8",
    border: "#d0d0d0",
    borderLight: "#b0b0b0",
    success: "#2e8b37",
  },
};

const lightBlue: LandingTheme = {
  id: "light-blue",
  name: "Light Blue",
  family: "light",
  palette: {
    accent: "#2870cc",
    accentHover: "#1e5caa",
    textPrimary: "#1a2030",
    textSecondary: "#506070",
    textTertiary: "#8090a0",
    textMuted: "#607080",
    bgBase: "#eef2f8",
    bgSurface: "#e4eaf2",
    bgElevated: "#d8e0ec",
    bgOverlay: "#ccd6e4",
    bgHover: "#b8c8dc",
    border: "#c0cce0",
    borderLight: "#a0b4cc",
    success: "#2e8b37",
  },
};

export const darkThemes: LandingTheme[] = [
  midnightBlue,
  darkGlass,
  rose,
  charcoal,
  forest,
  oledBlack,
];

export const lightThemes: LandingTheme[] = [light, lightBlue];

export const allThemes: LandingTheme[] = [...darkThemes, ...lightThemes];

export function hexToRgb(hex: string): string {
  const h = hex.replace("#", "");
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  return `${r}, ${g}, ${b}`;
}

export function applyTheme(theme: LandingTheme): void {
  const { palette } = theme;
  const r = document.documentElement;
  r.style.setProperty("--accent", palette.accent);
  r.style.setProperty("--accent-hover", palette.accentHover);
  r.style.setProperty("--accent-rgb", hexToRgb(palette.accent));
  r.style.setProperty("--text-primary", palette.textPrimary);
  r.style.setProperty("--text-secondary", palette.textSecondary);
  r.style.setProperty("--text-tertiary", palette.textTertiary);
  r.style.setProperty("--text-muted", palette.textMuted);
  r.style.setProperty("--bg-base", palette.bgBase);
  r.style.setProperty("--bg-base-rgb", hexToRgb(palette.bgBase));
  r.style.setProperty("--bg-surface", palette.bgSurface);
  r.style.setProperty("--bg-surface-rgb", hexToRgb(palette.bgSurface));
  r.style.setProperty("--bg-elevated", palette.bgElevated);
  r.style.setProperty("--bg-elevated-rgb", hexToRgb(palette.bgElevated));
  r.style.setProperty("--bg-overlay", palette.bgOverlay);
  r.style.setProperty("--bg-overlay-rgb", hexToRgb(palette.bgOverlay));
  r.style.setProperty("--bg-hover", palette.bgHover);
  r.style.setProperty("--border", palette.border);
  r.style.setProperty("--border-light", palette.borderLight);
  r.style.setProperty("--success", palette.success);
  // the demo's blurred preview draws its shapes in this ink, and darkens on dark themes only
  const light = theme.family === "light";
  r.style.setProperty("--ink-rgb", light ? "0, 0, 0" : "255, 255, 255");
  r.style.setProperty("--preview-filter", light ? "blur(4px)" : "blur(4px) brightness(0.6)");
}
