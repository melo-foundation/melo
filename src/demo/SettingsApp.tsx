import { Icon, GlyphProvider, resolveGlyphs } from "./icons";
import { allThemes } from "../themes";
import { defaultBgOptions, defaultBgConfig } from "./bgDefaults";
import type { DemoSettings, BgType } from "./types";

const BG_TYPE_OPTIONS = [
  { value: "none", label: "None" },
  { value: "bokeh", label: "Bokeh" },
  { value: "waves", label: "Waves" },
  { value: "mesh", label: "Mesh Gradient" },
];

export default function SettingsApp({
  settings,
  onUpdateSettings,
  currentTheme,
  onSetTheme,
  onClose,
  onTitleBarMouseDown,
}: {
  settings: DemoSettings;
  onUpdateSettings: (s: DemoSettings) => void;
  currentTheme: { id: string; name: string; palette: ThemePalette };
  onSetTheme: (theme: { id: string; name: string; palette: ThemePalette }) => void;
  onClose: () => void;
  onTitleBarMouseDown?: (e: React.MouseEvent) => void;
}) {
  const glyphs = resolveGlyphs(settings.glyphPreset);

  const update = (partial: Partial<DemoSettings>) => {
    onUpdateSettings({ ...settings, ...partial });
  };

  const updateBg = (partial: Partial<BackgroundConfig>) => {
    const current: BackgroundConfig = settings.background || {
      type: "none", opacity: 1, blur: 0, options: {},
    };
    update({ background: { ...current, ...partial } });
  };

  const bg = settings.background;
  const bgType = bg?.type || "none";

  const bgTypeOptions = BG_TYPE_OPTIONS;

  return (
    <GlyphProvider value={glyphs}>
        <div className="settings-window">
          <div className="settings-title-bar" onMouseDown={onTitleBarMouseDown}>
            <span className="title-bar-text">Settings</span>
            <div className="title-bar-controls">
              <button className="title-bar-btn title-bar-close" onClick={onClose}><Icon name="close" size={12} /></button>
            </div>
          </div>

          <div className="settings-content" style={{ flex: 1, overflowY: "auto", minHeight: 0 }}>
            {/* Theme selector */}
            <div className="setting-row" style={{ flexDirection: "column", alignItems: "stretch", gap: 4 }}>
              <span className="setting-name">Theme</span>
              {allThemes.map((t) => (
                <button
                  key={t.id}
                  className={`setting-theme-btn${t.id === currentTheme.id ? " active" : ""}`}
                  onClick={() => onSetTheme(t)}
                >
                  <span className="setting-theme-swatch" style={{ background: t.palette.accent, borderColor: t.palette.bgBase, boxShadow: `0 0 0 1px ${t.palette.border}` }} />
                  <span style={{ flex: 1, textAlign: "left" }}>{t.name}</span>
                  <span className="setting-theme-colors">
                    {[t.palette.bgBase, t.palette.bgSurface, t.palette.textPrimary].map((c, i) => (
                      <span key={i} style={{ background: c, borderColor: t.palette.border }} />
                    ))}
                  </span>
                </button>
              ))}
            </div>

            {/* Background type — carousel */}
            <div className="setting-row">
              <span className="setting-name">Background</span>
              <div className="setting-carousel">
                <button
                  className="setting-carousel-arrow"
                  onClick={() => {
                    const idx = bgTypeOptions.findIndex((o) => o.value === bgType);
                    const prev = bgTypeOptions[(idx - 1 + bgTypeOptions.length) % bgTypeOptions.length];
                    if (prev.value === "none") {
                      update({ background: undefined });
                    } else {
                      const cfg = defaultBgConfig(prev.value);
                      updateBg({ type: prev.value as BgType, options: defaultBgOptions(prev.value, currentTheme.palette.accent), ...cfg });
                    }
                  }}
                >
                  <Icon name="dropdownArrow" size={10} />
                </button>
                <span className="setting-carousel-label">
                  {bgTypeOptions.find((o) => o.value === bgType)?.label ?? "None"}
                </span>
                <button
                  className="setting-carousel-arrow setting-carousel-arrow--next"
                  onClick={() => {
                    const idx = bgTypeOptions.findIndex((o) => o.value === bgType);
                    const next = bgTypeOptions[(idx + 1) % bgTypeOptions.length];
                    if (next.value === "none") {
                      update({ background: undefined });
                    } else {
                      const cfg = defaultBgConfig(next.value);
                      updateBg({ type: next.value as BgType, options: defaultBgOptions(next.value, currentTheme.palette.accent), ...cfg });
                    }
                  }}
                >
                  <Icon name="dropdownArrow" size={10} />
                </button>
              </div>
            </div>

          </div>
        </div>
    </GlyphProvider>
  );
}
