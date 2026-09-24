import { Icon } from "../icons";

type LayoutMode = "list" | "grid" | "compact";

export default function LayoutToggle({
  layout,
  onChange,
}: {
  layout: LayoutMode;
  onChange: (mode: LayoutMode) => void;
}) {
  return (
    <div className="library-layout-btns">
      <button
        className={`library-layout-btn${layout === "list" ? " active" : ""}`}
        onClick={() => onChange("list")}
        title="List"
      >
        <Icon name="layoutList" size={14} />
      </button>
      <button
        className={`library-layout-btn${layout === "grid" ? " active" : ""}`}
        onClick={() => onChange("grid")}
        title="Grid"
      >
        <Icon name="layoutGrid" size={14} />
      </button>
      <button
        className={`library-layout-btn${layout === "compact" ? " active" : ""}`}
        onClick={() => onChange("compact")}
        title="Compact"
      >
        <Icon name="layoutCompact" size={14} />
      </button>
    </div>
  );
}
