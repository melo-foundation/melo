import { useState, useRef, useEffect, useCallback } from "react";
import { Icon } from "../icons";

export interface SelectOption {
  value: string;
  label: string;
  style?: React.CSSProperties;
}

export default function CustomSelect({
  value,
  onChange,
  options,
  className,
  disabled,
}: {
  value: string;
  onChange: (value: string) => void;
  options: SelectOption[];
  className?: string;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  const selected = options.find((o) => o.value === value);

  const handleToggle = useCallback(() => {
    if (disabled) return;
    setOpen((p) => !p);
  }, [disabled]);

  const handleSelect = useCallback(
    (val: string) => {
      onChange(val);
      setOpen(false);
    },
    [onChange],
  );

  // Close on click outside
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open]);

  // Position: absolute within wrapper, flip up/right-align if needed
  useEffect(() => {
    if (!open || !menuRef.current || !wrapRef.current) return;
    const menu = menuRef.current;
    const wrap = wrapRef.current;
    const scale = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--dpi-scale") || "1");

    // getBoundingClientRect returns viewport pixels; menu.offsetHeight is CSS px
    // In CSS-zoomed container, actual viewport space = CSS px * scale
    const wrapRect = wrap.getBoundingClientRect();
    const menuHViewport = menu.offsetHeight * scale;
    const menuWViewport = menu.offsetWidth * scale;

    const spaceBelow = window.innerHeight - wrapRect.bottom;
    const spaceAbove = wrapRect.top;

    // Vertical: prefer below, flip above only if no room below AND room above
    if (spaceBelow < menuHViewport && spaceAbove > menuHViewport) {
      menu.style.top = "auto";
      menu.style.bottom = "100%";
      menu.style.marginBottom = "2px";
      menu.style.marginTop = "";
    } else {
      menu.style.top = "100%";
      menu.style.bottom = "auto";
      menu.style.marginTop = "2px";
      menu.style.marginBottom = "";
    }

    // Horizontal: prefer left-aligned, shift if overflows right edge
    if (wrapRect.left + menuWViewport > window.innerWidth - 4) {
      menu.style.left = "auto";
      menu.style.right = "0";
    } else {
      menu.style.left = "0";
      menu.style.right = "auto";
    }
  }, [open]);

  return (
    <div className={`custom-select${disabled ? " disabled" : ""}`} ref={wrapRef}>
      <button
        className={`custom-select-trigger ${className || ""}`}
        onClick={handleToggle}
        disabled={disabled}
        type="button"
      >
        <span className="custom-select-label" style={selected?.style}>{selected?.label ?? value}</span>
        <span className="custom-select-arrow"><Icon name="dropdownArrow" size={10} /></span>
      </button>
      {open && (
        <div className="custom-select-menu" ref={menuRef}>
          {options.map((o) => (
            <button
              key={o.value}
              className={`custom-select-option${o.value === value ? " active" : ""}`}
              onClick={() => handleSelect(o.value)}
              type="button"
              style={o.style}
            >
              {o.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
