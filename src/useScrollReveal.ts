export type AnimationStyle =
  | "fade-up"
  | "fade"
  | "scale"
  | "slide-left"
  | "slide-right"
  | "blur"
  | "flip"
  | "drop";

export const animationStyles: { id: AnimationStyle; label: string }[] = [
  { id: "fade-up", label: "Fade Up" },
  { id: "fade", label: "Fade" },
  { id: "scale", label: "Scale" },
  { id: "slide-left", label: "Slide Left" },
  { id: "slide-right", label: "Slide Right" },
  { id: "blur", label: "Blur" },
  { id: "flip", label: "Flip" },
  { id: "drop", label: "Drop" },
];

// Numeric representation of all animated properties — easy to lerp
interface AnimNums {
  opacity: number;
  ty: number;
  tx: number;
  scale: number;
  rotateX: number;
  blur: number;
}

const VIS: AnimNums = { opacity: 1, ty: 0, tx: 0, scale: 1, rotateX: 0, blur: 0 };

// Enter hidden state: where the element starts BEFORE scrolling into view (below viewport)
function getEnterHidden(style: AnimationStyle): AnimNums {
  switch (style) {
    case "fade-up":    return { opacity: 0, ty: 40,  tx: 0,   scale: 1,    rotateX: 0,  blur: 0 };
    case "fade":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: 0,  blur: 0 };
    case "scale":      return { opacity: 0, ty: 0,   tx: 0,   scale: 0.85, rotateX: 0,  blur: 0 };
    case "slide-left": return { opacity: 0, ty: 0,   tx: -120, scale: 1,    rotateX: 0,  blur: 0 };
    case "slide-right":return { opacity: 0, ty: 0,   tx: 120,  scale: 1,    rotateX: 0,  blur: 0 };
    case "blur":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: 0,  blur: 12 };
    case "flip":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: 15, blur: 0 };
    case "drop":       return { opacity: 0, ty: -30, tx: 0,   scale: 0.95, rotateX: 0,  blur: 0 };
  }
}

// Leave hidden state: where the element ends AFTER scrolling out of view (above viewport)
// Directions are flipped — element moves with the scroll direction (upward/away)
function getLeaveHidden(style: AnimationStyle): AnimNums {
  switch (style) {
    case "fade-up":    return { opacity: 0, ty: -40, tx: 0,   scale: 1,    rotateX: 0,   blur: 0 };
    case "fade":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: 0,   blur: 0 };
    case "scale":      return { opacity: 0, ty: 0,   tx: 0,   scale: 1.15, rotateX: 0,   blur: 0 };
    case "slide-left": return { opacity: 0, ty: 0,   tx: -120, scale: 1,    rotateX: 0,   blur: 0 };
    case "slide-right":return { opacity: 0, ty: 0,   tx: 120,  scale: 1,    rotateX: 0,   blur: 0 };
    case "blur":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: 0,   blur: 12 };
    case "flip":       return { opacity: 0, ty: 0,   tx: 0,   scale: 1,    rotateX: -15, blur: 0 };
    case "drop":       return { opacity: 0, ty: -40, tx: 0,   scale: 0.95, rotateX: 0,   blur: 0 };
  }
}

function lerpNum(a: number, b: number, t: number) {
  return a + (b - a) * t;
}

function lerpAnim(from: AnimNums, to: AnimNums, t: number): AnimNums {
  return {
    opacity:  lerpNum(from.opacity, to.opacity, t),
    ty:       lerpNum(from.ty, to.ty, t),
    tx:       lerpNum(from.tx, to.tx, t),
    scale:    lerpNum(from.scale, to.scale, t),
    rotateX:  lerpNum(from.rotateX, to.rotateX, t),
    blur:     lerpNum(from.blur, to.blur, t),
  };
}

function applyToEl(el: HTMLElement, v: AnimNums) {
  // At rest, no transform at all: a leftover perspective/scale keeps the element
  // on its own layer, where its 1px borders are resampled and the right edge smears.
  const atRest = Math.abs(v.opacity - 1) < 0.001 && Math.abs(v.ty) < 0.05 && Math.abs(v.tx) < 0.05
    && Math.abs(v.scale - 1) < 0.0005 && Math.abs(v.rotateX) < 0.01 && v.blur <= 0.01;
  if (atRest) {
    el.style.opacity = "";
    el.style.transform = "";
    el.style.filter = "";
    el.style.willChange = "";
    return;
  }
  el.style.willChange = "opacity, transform, filter";
  el.style.opacity = String(v.opacity);
  el.style.transform =
    `translateY(${v.ty}px) translateX(${v.tx}px) scale(${v.scale}) perspective(800px) rotateX(${v.rotateX}deg)`;
  if (v.blur > 0.01) {
    el.style.filter = `blur(${v.blur}px)`;
  } else {
    el.style.filter = "";
  }
}

// Ease-out cubic for smoother scroll-position mapping
function ease(t: number) {
  return 1 - Math.pow(1 - t, 3);
}

// ─── Scroll reveal config ───
// All values are fractions of viewport height (0 = top of viewport, 1 = bottom)
// "edge" is which edge of the element to track against the viewport line

const ENTER = {
  edge: 0.6,     // 0 = top of element, 1 = bottom of element
  begin: 1,  // viewport line where animation starts (hidden → transitioning)
  end: 0.8,    // viewport line where animation ends (transitioning → fully visible)
};

const LEAVE = {
  edge: 0.2,     // 0 = top of element, 1 = bottom of element
  begin: 0.2,  // viewport line where animation starts (visible → transitioning)
  end: 0.1,    // viewport line where animation ends (transitioning → fully hidden)
};

function computeTarget(
  rect: DOMRect,
  vh: number,
  enterHidden: AnimNums,
  leaveHidden: AnimNums,
): AnimNums {
  const enterEdge = rect.top + rect.height * ENTER.edge;
  const enterBegin = vh * ENTER.begin;
  const enterEnd = vh * ENTER.end;

  // Element is fully hidden (beyond the begin line)
  if (enterEdge >= enterBegin) return enterHidden;
  // Element is transitioning in
  if (enterEdge > enterEnd) {
    const t = ease(1 - (enterEdge - enterEnd) / (enterBegin - enterEnd));
    return lerpAnim(enterHidden, VIS, t);
  }

  const leaveEdge = rect.top + rect.height * LEAVE.edge;
  const leaveBegin = vh * LEAVE.begin;
  const leaveEnd = vh * LEAVE.end;

  // Element is fully visible (above the leave begin line)
  if (leaveEdge >= leaveBegin) return VIS;
  // Element is transitioning out
  if (leaveEdge > leaveEnd) {
    const t = ease((leaveEdge - leaveEnd) / (leaveBegin - leaveEnd));
    return lerpAnim(leaveHidden, VIS, t);
  }

  // Element is fully hidden (beyond the leave end line)
  return leaveHidden;
}

const LERP_FACTOR = 0.45; // Smoothing: 0 = frozen, 1 = instant
const THRESHOLD = 0.001;

// Manages all scroll-reveal elements from a single scroll listener + RAF loop
class ScrollRevealManager {
  private entries = new Map<HTMLElement, {
    enterStyle: AnimationStyle;
    leaveStyle: AnimationStyle;
    current: AnimNums;
    target: AnimNums;
    debugMarkers?: { enter: HTMLElement; leave: HTMLElement };
  }>();
  private raf: number | null = null;
  private running = false;

  constructor() {
    this.onScroll = this.onScroll.bind(this);
    this.tick = this.tick.bind(this);
    window.addEventListener("scroll", this.onScroll, { passive: true });
    window.addEventListener("resize", this.onScroll, { passive: true });
  }

  register(el: HTMLElement, enterStyle: AnimationStyle, leaveStyle: AnimationStyle) {
    const target = this.computeForEl(el, null, enterStyle, leaveStyle);
    const entry: (typeof this.entries extends Map<any, infer V> ? V : never) = {
      enterStyle,
      leaveStyle,
      current: { ...target },
      target,
    };
    if (DEBUG_GUIDES) {
      el.style.position = el.style.position || "relative";
      entry.debugMarkers = {
        enter: this.createEdgeMarker(el, "enter", "#ff4444"),
        leave: this.createEdgeMarker(el, "leave", "#4488ff"),
      };
    }
    this.entries.set(el, entry);
    el.style.willChange = "opacity, transform, filter";
    applyToEl(el, target);
  }

  update(el: HTMLElement, enterStyle: AnimationStyle, leaveStyle: AnimationStyle) {
    const entry = this.entries.get(el);
    if (entry) {
      entry.enterStyle = enterStyle;
      entry.leaveStyle = leaveStyle;
      this.onScroll();
    }
  }

  unregister(el: HTMLElement) {
    const entry = this.entries.get(el);
    if (entry?.debugMarkers) {
      entry.debugMarkers.enter.remove();
      entry.debugMarkers.leave.remove();
    }
    this.entries.delete(el);
    el.style.willChange = "";
    el.style.opacity = "";
    el.style.transform = "";
    el.style.filter = "";
  }

  private createEdgeMarker(el: HTMLElement, type: "enter" | "leave", color: string): HTMLElement {
    const marker = document.createElement("div");
    const edgeFrac = type === "enter" ? ENTER.edge : LEAVE.edge;
    marker.style.cssText = `
      position: absolute; left: 0; right: 0; height: 0;
      border-top: 2px solid ${color};
      top: ${edgeFrac * 100}%;
      z-index: 99999; pointer-events: none;
    `;
    const tag = document.createElement("span");
    tag.textContent = `${type} edge (${(edgeFrac * 100).toFixed(0)}%)`;
    tag.style.cssText = `
      position: absolute; top: 2px; right: 4px;
      font: 10px/1 monospace; color: ${color};
      background: rgba(0,0,0,0.8); padding: 2px 4px; border-radius: 2px;
    `;
    marker.appendChild(tag);
    el.appendChild(marker);
    return marker;
  }

  private computeForEl(el: HTMLElement, entry: { current: AnimNums } | null, enterStyle: AnimationStyle, leaveStyle: AnimationStyle): AnimNums {
    const rect = el.getBoundingClientRect();
    // Undo the current animation transform so we get the true layout position
    const cur = entry?.current;
    let corrected: DOMRect | { top: number; bottom: number; height: number } = rect;
    if (cur) {
      // Undo translateY and scale to recover true layout position
      const s = cur.scale || 1;
      const layoutHeight = rect.height / s;
      const scaleShift = (layoutHeight - rect.height) / 2;
      corrected = {
        top: rect.top - cur.ty + scaleShift,
        bottom: rect.bottom - cur.ty - scaleShift,
        height: layoutHeight,
      };
    }
    return computeTarget(corrected as DOMRect, window.innerHeight, getEnterHidden(enterStyle), getLeaveHidden(leaveStyle));
  }

  private onScroll() {
    // Update all targets
    for (const [el, entry] of this.entries) {
      entry.target = this.computeForEl(el, entry, entry.enterStyle, entry.leaveStyle);
    }
    this.startTick();
  }

  private startTick() {
    if (!this.running) {
      this.running = true;
      this.raf = requestAnimationFrame(this.tick);
    }
  }

  private tick() {
    let needsMore = false;

    for (const [el, entry] of this.entries) {
      const { current, target } = entry;
      let changed = false;

      for (const key of Object.keys(current) as (keyof AnimNums)[]) {
        const diff = target[key] - current[key];
        if (Math.abs(diff) > THRESHOLD) {
          current[key] += diff * LERP_FACTOR;
          needsMore = true;
          changed = true;
        } else if (current[key] !== target[key]) {
          current[key] = target[key];
          changed = true;
        }
      }

      if (changed) applyToEl(el, current);
    }

    if (needsMore) {
      this.raf = requestAnimationFrame(this.tick);
    } else {
      this.running = false;
    }
  }

  destroy() {
    window.removeEventListener("scroll", this.onScroll);
    window.removeEventListener("resize", this.onScroll);
    if (this.raf) cancelAnimationFrame(this.raf);
  }
}

// ─── Debug guide lines ───
const DEBUG_GUIDES = false;

function createGuide(label: string, color: string, _vh: number, fraction: number): HTMLElement {
  const el = document.createElement("div");
  el.style.cssText = `
    position: fixed; left: 0; right: 0; height: 0;
    border-top: 2px dashed ${color};
    top: ${fraction * 100}vh;
    z-index: 99999; pointer-events: none;
  `;
  const tag = document.createElement("span");
  tag.textContent = `${label} (${(fraction * 100).toFixed(0)}%)`;
  tag.style.cssText = `
    position: absolute; top: 2px; left: 8px;
    font: 11px/1 monospace; color: ${color};
    background: rgba(0,0,0,0.7); padding: 2px 6px; border-radius: 3px;
  `;
  el.appendChild(tag);
  document.body.appendChild(el);
  return el;
}

let guidesCreated = false;
function ensureGuides() {
  if (guidesCreated || !DEBUG_GUIDES) return;
  guidesCreated = true;
  createGuide("ENTER begin", "#ff4444", window.innerHeight, ENTER.begin);
  createGuide("ENTER end", "#ff8888", window.innerHeight, ENTER.end);
  createGuide("LEAVE begin", "#4488ff", window.innerHeight, LEAVE.begin);
  createGuide("LEAVE end", "#88bbff", window.innerHeight, LEAVE.end);
}

// Singleton manager — one scroll listener for all elements
let manager: ScrollRevealManager | null = null;

export function getManager() {
  if (!manager) {
    manager = new ScrollRevealManager();
    ensureGuides();
  }
  return manager;
}
