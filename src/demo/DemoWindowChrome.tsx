import { Icon } from "./icons";
import { allThemes } from "../themes";
import type { LandingTheme } from "../themes";

type View = "home" | "search" | "library";

export default function DemoWindowChrome({
  view,
  onSetView,
  onOpenSettings,
  currentTheme,
  onSetTheme,
}: {
  view: View;
  onSetView: (v: View) => void;
  onOpenSettings: () => void;
  currentTheme: LandingTheme;
  onSetTheme: (theme: LandingTheme) => void;
}) {
  return (
    <>
      <div className="title-bar">
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <div className="title-bar-dots">
            <span className="dot dot-red" />
            <span className="dot dot-yellow" />
            <span className="dot dot-green" />
          </div>
          <span className="title-bar-text">melo</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <div className="theme-dots">
            {allThemes.map((t) => (
              <button
                key={t.id}
                className={`theme-dot${t.id === currentTheme.id ? " active" : ""}`}
                style={{ background: t.palette.accent }}
                onClick={() => onSetTheme(t)}
                title={t.name}
              />
            ))}
          </div>
          <button className="title-bar-btn" onClick={onOpenSettings} title="Settings">
            <Icon name="settings" size={12} />
          </button>
        </div>
      </div>

      <div className="tab-bar">
        <button
          className={`tab${view === "home" ? " active" : ""}`}
          onClick={() => onSetView("home")}
        >
          Home
        </button>
        <button
          className={`tab${view === "search" ? " active" : ""}`}
          onClick={() => onSetView("search")}
        >
          Search
        </button>
        <button
          className={`tab${view === "library" ? " active" : ""}`}
          onClick={() => onSetView("library")}
        >
          Library
        </button>
      </div>
    </>
  );
}
