// Validation for the `ui` capability block and the per-plugin settings schema.
// Two rules hold here:
//   - every qml path is containment-checked like entry.sidecar, so a plugin
//     cannot name a file outside its own folder.
//   - the settings schema has no description field (a row is label, value,
//     options); unknown fields, `desc` included, are dropped by the rebuild.
import { existsSync } from "fs";
import { resolve, join, sep } from "path";

export interface UiWindow {
  id: string; qml: string; width: number; height: number;
  primary?: boolean; snapTo?: string; initial?: "shown" | "hidden";
  shade?: { height: number };
  resize?: { axes: "v" | "h" | "vh"; stepH?: number; stepW?: number;
             minHeight?: number; minWidth?: number };
}
// The shell's named places; twin of kSlots on the C++ side. Keep both lists
// identical and do not DRY at runtime. A plugin does not invent a place; it
// offers to fill one melo has, and the user binds it.
export const SLOT_IDS = ["playerBar", "titleBar", "searchBar", "tabBar",
                         "queuePanel", "home", "library", "search",
                         "visualizer", "background", "eq"] as const;
export type SlotId = typeof SLOT_IDS[number];
const SLOT_SET = new Set<string>(SLOT_IDS);

// Where a plugin's button can go: melo's two bars; not a place a plugin names.
export const BUTTON_BARS = ["player", "title"] as const;
export type ButtonBar = typeof BUTTON_BARS[number];
const BAR_SET = new Set<string>(BUTTON_BARS);

export interface UiButton {
  id: string; bar: ButtonBar; command: string; icon: string; label: string;
}

// A fill: a fragment shader of the plugin's own, drawn through styled.frag's
// uniform block, offered beside melo's fills in the colour picker as
// "<pluginId>.<id>". Additive, like buttons; no cap.
export interface UiFill {
  id: string; name: string; shader: string; colours: 0 | 1 | 2 | 3; base: boolean; palette: boolean; shaped: boolean;
}

export interface UiBlock {
  snap?: { distance: number };
  windows: UiWindow[];
  // Extra controls beside melo's own. ADDITIVE: nothing melo shows is taken
  // away by one, so there is no cap and no opt-in. `command` is one of THIS
  // plugin's commands, cross-checked
  // in manifest.ts, which is the only place that has seen both blocks.
  buttons?: UiButton[];
  fills?: UiFill[];
  // slot id -> in-window QML, relative to the plugin dir. Declaring is not
  // being granted: nothing binds until the user picks this plugin for that slot.
  slots?: Partial<Record<SlotId, string>>;
}
export type SettingsFieldType = "toggle" | "select" | "slider" | "text" | "action" | "file";
export interface SettingsField {
  key: string; type: SettingsFieldType; label: string;
  default?: unknown;
  options?: { label: string; value: string }[];
  from?: number; to?: number; step?: number;
  placeholder?: string;
  dir?: string; extensions?: string[];
}

const FIELD_TYPES: SettingsFieldType[] = ["toggle", "select", "slider", "text", "action", "file"];

// Every number in the ui block is a whole pixel: the shell reads them with
// QJsonValue::toInt(), which silently returns 0 for a non-integral or
// out-of-range double, so `"width": 275.5` would fail in the shell without
// naming the value. Shell geometry is int too (QWindow::resize, snapTo).
// Pinned across the seam by tests/fixtures/skin-plugin, which tst_windowsnap's
// theShippedManifestIsTheOneTheShellReads hands to the real host.
const INT_MAX = 2147483647;
const isPixels = (n: unknown): boolean =>
  typeof n === "number" && Number.isInteger(n) && Math.abs(n) <= INT_MAX;
const pos = (n: unknown): boolean => isPixels(n) && (n as number) > 0;

// Containment is checked BEFORE existence: a path that escapes the plugin dir
// reports "escapes" whether or not the file it points at happens to be there.
function within(dir: string, rel: unknown): "ok" | "escapes" | "missing" | "bad" {
  if (typeof rel !== "string" || rel.length === 0) return "bad";
  const root = resolve(dir);
  const abs = resolve(join(dir, rel));
  if (abs !== root && !abs.startsWith(root + sep)) return "escapes";
  return existsSync(abs) ? "ok" : "missing";
}

export function validateUi(raw: unknown, dir: string, apiVersion: number):
    { ui: UiBlock | null; error: string | null } {
  if (raw === undefined) return { ui: null, error: null };
  if (apiVersion < 3)
    return { ui: null, error: "the ui capability requires apiVersion 3 (v2 ui.kind is not supported)" };
  if (typeof raw !== "object" || raw === null)
    return { ui: null, error: "ui must be an object" };
  const u = raw as Record<string, any>;
  if ("kind" in u)
    return { ui: null, error: "ui.kind is not part of apiVersion 3" };
  // Windows are optional when something else draws (a slot fill, or only a
  // button). A `ui` block declaring nothing would load QML that can never
  // appear, so it is an error.
  const hasWindows = Array.isArray(u.windows) && u.windows.length > 0;
  const hasSlots = typeof u.slots === "object" && u.slots !== null
                   && Object.keys(u.slots).length > 0;
  const hasButtons = Array.isArray(u.buttons) && u.buttons.length > 0;
  const hasFills = Array.isArray(u.fills) && u.fills.length > 0;
  if (!hasWindows && !hasSlots && !hasButtons && !hasFills)
    return { ui: null, error: "ui declares nothing: needs windows, slots, buttons or fills" };
  if ("windows" in u && !Array.isArray(u.windows))
    return { ui: null, error: "ui.windows must be an array" };

  const ids = new Set<string>();
  const windows: UiWindow[] = [];
  for (const w of (u.windows ?? [])) {
    if (typeof w !== "object" || w === null) return { ui: null, error: "ui.windows entries must be objects" };
    if (typeof w.id !== "string" || !/^[a-z0-9][a-z0-9_-]*$/i.test(w.id))
      return { ui: null, error: `ui window id must be a slug: ${String(w.id)}` };
    if (ids.has(w.id)) return { ui: null, error: `duplicate ui window id: ${w.id}` };
    ids.add(w.id);
    const chk = within(dir, w.qml);
    if (chk === "bad")     return { ui: null, error: `window ${w.id}: qml must be a non-empty string` };
    if (chk === "escapes") return { ui: null, error: `window ${w.id}: qml escapes the plugin directory: ${w.qml}` };
    if (chk === "missing") return { ui: null, error: `window ${w.id}: qml file not found: ${w.qml}` };
    if (!pos(w.width) || !pos(w.height))
      return { ui: null,
               error: `window ${w.id}: width and height must be positive whole pixels` };
    const out: UiWindow = { id: w.id, qml: w.qml, width: w.width, height: w.height };
    if (w.primary === true) out.primary = true;
    if (typeof w.snapTo === "string") out.snapTo = w.snapTo;
    if (w.initial === "shown" || w.initial === "hidden") out.initial = w.initial;
    // A zero step in shell-side round-to-step positioning is NaN geometry.
    // Reject bad values rather than drop the field, which would leave a
    // declared-resizable window fixed with no reason given. Absent is fine.
    if (w.shade !== undefined) {
      if (typeof w.shade !== "object" || w.shade === null || !pos(w.shade.height))
        return { ui: null, error: `window ${w.id}: shade.height must be a positive whole pixel count` };
      out.shade = { height: w.shade.height };
    }
    if (w.resize !== undefined) {
      if (typeof w.resize !== "object" || w.resize === null || !["v", "h", "vh"].includes(w.resize.axes))
        return { ui: null, error: `window ${w.id}: resize.axes must be one of: v, h, vh` };
      out.resize = { axes: w.resize.axes };
      for (const k of ["stepH", "stepW", "minHeight", "minWidth"] as const) {
        if (w.resize[k] === undefined) continue;
        if (!pos(w.resize[k]))
          return { ui: null, error: `window ${w.id}: resize.${k} must be a positive whole pixel count` };
        out.resize[k] = w.resize[k];
      }
    }
    windows.push(out);
  }
  // Exactly one primary among windows that exist. a plugin with no windows has
  // no primary to name, and demanding one there is the same mistake as
  // demanding a window at all.
  const primaries = windows.filter((w) => w.primary);
  if (hasWindows && primaries.length !== 1)
    return { ui: null, error: `ui.windows needs exactly one primary window (found ${primaries.length})` };
  for (const w of windows)
    if (w.snapTo !== undefined && !ids.has(w.snapTo))
      return { ui: null, error: `window ${w.id}: snapTo names an unknown window: ${w.snapTo}` };
  // snapTo must be a forest: the shell walks the chain to position a docked
  // group, and a cycle hangs it. Rejected here, where the windows can still be
  // named. Any depth and forward references are fine.
  const byId = new Map(windows.map((w) => [w.id, w]));
  const acyclic = new Set<string>();
  for (const start of windows) {
    if (acyclic.has(start.id)) continue;
    const path: string[] = [];
    let cur: UiWindow | undefined = start;
    while (cur?.snapTo !== undefined && !acyclic.has(cur.id)) {
      path.push(cur.id);
      const next: string = cur.snapTo;
      const loop = path.indexOf(next);
      if (loop !== -1)
        return { ui: null, error: `ui.windows: snapTo forms a cycle: ${[...path.slice(loop), next].join(" -> ")}` };
      cur = byId.get(next);
    }
    for (const id of path) acyclic.add(id); // proven to terminate — never rewalk
  }

  const ui: UiBlock = { windows };
  if (u.buttons !== undefined) {
    if (!Array.isArray(u.buttons))
      return { ui: null, error: "ui.buttons must be an array" };
    const seen = new Set<string>();
    const buttons: UiButton[] = [];
    for (const b of u.buttons as unknown[]) {
      if (typeof b !== "object" || b === null)
        return { ui: null, error: "ui.buttons entries must be objects" };
      const e = b as Record<string, unknown>;
      if (typeof e.id !== "string" || !/^[a-z0-9][a-z0-9_-]*$/i.test(e.id))
        return { ui: null, error: `ui button id must be a slug: ${String(e.id)}` };
      if (seen.has(e.id)) return { ui: null, error: `duplicate ui button id: ${e.id}` };
      seen.add(e.id);
      if (typeof e.bar !== "string" || !BAR_SET.has(e.bar))
        return { ui: null, error: `button ${e.id}: unknown bar: ${String(e.bar)}` };
      // Cross-checked against this plugin's `commands` in manifest.ts; here it
      // only has to be a name.
      if (typeof e.command !== "string" || e.command.length === 0)
        return { ui: null, error: `button ${e.id}: command must be a non-empty string` };
      // The tooltip, and what the user hides it by. A button with no name is
      // one nobody can turn off.
      if (typeof e.label !== "string" || e.label.length === 0)
        return { ui: null, error: `button ${e.id}: label must be a non-empty string` };
      const chk = within(dir, e.icon);
      if (chk === "bad")     return { ui: null, error: `button ${e.id}: icon must be a non-empty string` };
      if (chk === "escapes") return { ui: null, error: `button ${e.id}: icon escapes the plugin directory: ${String(e.icon)}` };
      if (chk === "missing") return { ui: null, error: `button ${e.id}: icon file not found: ${String(e.icon)}` };
      buttons.push({ id: e.id, bar: e.bar as ButtonBar, command: e.command,
                     icon: e.icon as string, label: e.label });
    }
    if (buttons.length > 0) ui.buttons = buttons;
  }
  if (u.fills !== undefined) {
    if (!Array.isArray(u.fills))
      return { ui: null, error: "ui.fills must be an array" };
    const seen = new Set<string>();
    const fills: UiFill[] = [];
    for (const f of u.fills as unknown[]) {
      if (typeof f !== "object" || f === null)
        return { ui: null, error: "ui.fills entries must be objects" };
      const e = f as Record<string, unknown>;
      if (typeof e.id !== "string" || !/^[a-z0-9][a-z0-9_-]*$/i.test(e.id))
        return { ui: null, error: `ui fill id must be a slug: ${String(e.id)}` };
      if (seen.has(e.id)) return { ui: null, error: `duplicate ui fill id: ${e.id}` };
      seen.add(e.id);
      if (typeof e.name !== "string" || e.name.length === 0)
        return { ui: null, error: `fill ${e.id}: name must be a non-empty string` };
      // A .qsb, baked by the plugin author with Qt's qsb tool: melo cannot
      // compile GLSL at run time, and a .frag here would load as nothing.
      const chk = within(dir, e.shader);
      if (chk === "bad")     return { ui: null, error: `fill ${e.id}: shader must be a non-empty string` };
      if (chk === "escapes") return { ui: null, error: `fill ${e.id}: shader escapes the plugin directory: ${String(e.shader)}` };
      if (chk === "missing") return { ui: null, error: `fill ${e.id}: shader file not found: ${String(e.shader)}` };
      if (!(e.shader as string).endsWith(".qsb"))
        return { ui: null, error: `fill ${e.id}: shader must be a .qsb (run qsb on your .frag): ${String(e.shader)}` };
      const colours = e.colours === undefined ? 1 : e.colours;
      if (colours !== 0 && colours !== 1 && colours !== 2 && colours !== 3)
        return { ui: null, error: `fill ${e.id}: colours must be 0, 1, 2 or 3` };
      fills.push({ id: e.id, name: e.name, shader: e.shader as string,
                   colours: colours as 0 | 1 | 2 | 3,
                   base: e.base === undefined ? colours >= 1 : e.base === true,
                   palette: e.palette === undefined ? colours >= 2 : e.palette === true,
                   shaped: e.shaped === true });
    }
    if (fills.length > 0) ui.fills = fills;
  }
  if (u.slots !== undefined) {
    if (typeof u.slots !== "object" || u.slots === null || Array.isArray(u.slots))
      return { ui: null, error: "ui.slots must be an object of slot id -> qml path" };
    const slots: Partial<Record<SlotId, string>> = {};
    for (const [id, rel] of Object.entries(u.slots as Record<string, unknown>)) {
      // An unknown id is an error: silently ignoring it leaves a plugin that
      // never appears in any picker and no way for its author to find out why.
      if (!SLOT_SET.has(id))
        return { ui: null, error: `ui.slots: unknown slot id: ${id}` };
      // The same three answers, in the same order, as a window's qml: a path
      // that escapes says so whether or not the file happens to exist.
      const chk = within(dir, rel);
      if (chk === "bad")     return { ui: null, error: `slot ${id}: qml must be a non-empty string` };
      if (chk === "escapes") return { ui: null, error: `slot ${id}: qml escapes the plugin directory: ${String(rel)}` };
      if (chk === "missing") return { ui: null, error: `slot ${id}: qml file not found: ${String(rel)}` };
      slots[id as SlotId] = rel as string;
    }
    if (Object.keys(slots).length > 0) ui.slots = slots;
  }
  if (u.snap !== undefined) {
    // Zero means "no magnetism"; a negative distance inverts the closeness
    // test. Whole pixels because toInt() turns a fractional distance into the
    // default 10, not the author's 0.
    if (typeof u.snap !== "object" || u.snap === null ||
        !isPixels(u.snap.distance) || u.snap.distance < 0)
      return { ui: null, error: "ui.snap.distance must be a non-negative whole pixel count" };
    ui.snap = { distance: u.snap.distance };
  }
  return { ui, error: null };
}

// A `file` field's `dir` is a path into the plugin's own data folder. It
// reaches pluginSettingFiles() (manager.ts), which containment-checks it, and
// melo's Settings page, which builds a file:// URL for Qt.openUrlExternally
// unchecked, so `"dir": "../../../../home/<user>/.ssh"` would make "Open
// folder" open the user's ssh directory. Rejected here, where both pass.
// Returns the tail of an error sentence, or null when the value is fine.
function badDataDir(v: string): string | null {
  if (v === "") return null;
  if (v.startsWith("/") || v.startsWith("\\") || /^[a-zA-Z]:/.test(v))
    return "must be a relative path, not an absolute one";
  // split on BOTH separators: manifests are written on Windows too, and Qt
  // resolves a backslash segment on Linux as part of the file name rather than
  // as a separator — checking only "/" would let "..\\.." through on Windows.
  if (v.split(/[\\/]/).some((seg) => seg === ".."))
    return "must not contain a .. segment";
  return null;
}

export function validateSettings(raw: unknown):
    { settings: SettingsField[]; error: string | null } {
  if (raw === undefined) return { settings: [], error: null };
  if (!Array.isArray(raw)) return { settings: [], error: "settings must be an array" };
  const keys = new Set<string>();
  const out: SettingsField[] = [];
  for (const f of raw) {
    if (typeof f !== "object" || f === null) return { settings: [], error: "settings entries must be objects" };
    if (typeof f.key !== "string" || !/^[a-z0-9][a-z0-9_-]*$/i.test(f.key))
      return { settings: [], error: `settings key must be a slug: ${String(f.key)}` };
    if (keys.has(f.key)) return { settings: [], error: `duplicate settings key: ${f.key}` };
    keys.add(f.key);
    if (!FIELD_TYPES.includes(f.type))
      return { settings: [], error: `settings ${f.key}: type must be one of ${FIELD_TYPES.join(", ")}` };
    if (typeof f.label !== "string" || f.label.length === 0)
      return { settings: [], error: `settings ${f.key}: label is required` };
    // rebuilt field-by-field: unknown keys (notably `desc`) never survive
    const g: SettingsField = { key: f.key, type: f.type, label: f.label };
    if (f.default !== undefined) g.default = f.default;
    if (f.type === "select") {
      if (!Array.isArray(f.options) || f.options.length === 0)
        return { settings: [], error: `settings ${f.key}: select needs a non-empty options array` };
      // Checked before read: initPlugins calls loadPluginDir with no catch, so
      // a malformed option must be an error value, not a throw at startup.
      // String() coercion would show `options: ["always"]` as "undefined" rows.
      for (const o of f.options)
        if (typeof o !== "object" || o === null ||
            typeof o.label !== "string" || typeof o.value !== "string")
          return { settings: [], error: `settings ${f.key}: each select option needs a string label and value` };
      g.options = f.options.map((o: any) => ({ label: o.label, value: o.value }));
    }
    if (f.type === "slider") {
      // Finite, not whole, unlike the ui block: slider from/to/step reach
      // Settings as JS numbers, never through toInt(), so `from: 0, to: 1,
      // step: 0.1` is a legitimate slider.
      for (const k of ["from", "to", "step"] as const)
        if (Number.isFinite(f[k])) g[k] = f[k];
    }
    if (f.type === "text" && typeof f.placeholder === "string") g.placeholder = f.placeholder;
    if (f.type === "file") {
      if (f.dir !== undefined && typeof f.dir !== "string")
        return { settings: [], error: `settings ${f.key}: dir must be a string` };
      const bad = badDataDir(f.dir ?? "");
      if (bad) return { settings: [], error: `settings ${f.key}: dir ${bad}` };
      g.dir = f.dir ?? "";
      g.extensions = Array.isArray(f.extensions) ? f.extensions.map(String) : [];
    }
    out.push(g);
  }
  return { settings: out, error: null };
}
