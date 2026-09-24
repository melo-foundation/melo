export function hexToRgb(hex: string): string {
  const h = hex.replace("#", "");
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  return `${r}, ${g}, ${b}`;
}

export function applyThemePalette(palette: ThemePalette, root?: HTMLElement): void {
  const r = root || document.documentElement;
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
  r.style.setProperty("--bg-hover-rgb", hexToRgb(palette.bgHover));
  r.style.setProperty("--border", palette.border);
  r.style.setProperty("--border-light", palette.borderLight);
  r.style.setProperty("--success", palette.success);
  // Font — match real app default (Red Hat Display via Google Fonts)
  r.style.setProperty("--font-family", '"Red Hat Display", system-ui, -apple-system, sans-serif');
}

export function applyCustomCSS(css: string): void {
  let el = document.getElementById("theme-custom-css") as HTMLStyleElement | null;
  if (!css) {
    el?.remove();
    return;
  }
  if (!el) {
    el = document.createElement("style");
    el.id = "theme-custom-css";
    document.head.appendChild(el);
  }
  el.textContent = css;
}

const shapePresets: Record<string, [string, string, string]> = {
  sharp:   ["0",   "0",     "2px"],
  rounded: ["2px", "4px",   "8px"],
  pill:    ["4px", "999px", "999px"],
};

export function applyButtonShape(shape?: "sharp" | "rounded" | "pill", root?: HTMLElement): void {
  const [sm, md, lg] = shapePresets[shape || "rounded"];
  const r = root || document.documentElement;
  r.style.setProperty("--radius-sm", sm);
  r.style.setProperty("--radius-md", md);
  r.style.setProperty("--radius-lg", lg);
}
