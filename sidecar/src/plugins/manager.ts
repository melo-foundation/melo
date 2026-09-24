// Plugin manager: one host child process per enabled plugin. Routes source
// calls (search / resolveStream) and player events to them and restarts
// crashes up to 3 per 60s, then parks. A plugin that fails to load or crashes
// never affects the sidecar or other plugins.
import { spawn, type ChildProcess } from "child_process";
import { readdirSync, mkdirSync } from "fs";
import { join, dirname, resolve, sep } from "path";
import { createInterface } from "readline";
import { loadPluginDir, type LoadedPlugin } from "./manifest";
import type { UiBlock, SettingsField } from "./ui-manifest";
import { EMPTY_GRANTS, INTERCEPT_ACTIONS, type PluginGrants, type PluginPermissions } from "./permissions";
import { GESTURE_IDS, type CommandDecl } from "./commands";
import { log } from "../rpc";

const INTERCEPT_SET = new Set<string>(INTERCEPT_ACTIONS);
const GESTURE_SET = new Set<string>(GESTURE_IDS);

interface Runtime {
  loaded: LoadedPlugin;
  enabled: boolean;
  grants: PluginGrants;
  state: "running" | "stopped" | "crashed" | "error";
  error: string | null;
  proc: ChildProcess | null;
  sources: { id: string; name: string }[];
  events: string[];
  restarts: number[];              // timestamps of recent restarts
  nextId: number;
  pending: Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>;
}
let plugins = new Map<string, Runtime>();
let cfg: { pluginsDir: string; pluginDataRoot: string; hostPath: string;
           grants: Record<string, PluginGrants>; onChanged: () => void } | null = null;

export interface PluginInfo {
  id: string; name: string; version: string; description?: string; author?: string;
  capabilities: string[]; permissions: PluginPermissions;
  warnings: string[]; enabled: boolean;
  grants: PluginGrants;
  state: Runtime["state"]; error: string | null;
  sources: { id: string; name: string }[];
  ui: UiBlock | null;
  settings: SettingsField[];
  commands: CommandDecl[];
  dir: string;                  // absolute plugin folder — the shell resolves qml against it
  // The QML half of `entry`, already containment-checked by loadPluginDir. The
  // shell instantiates exactly this file as the plugin's shared-state root, so
  // it has to come from the validator rather than be re-derived from disk.
  entryQml: string | null;
}

function sanitizeGrants(g: unknown, loaded: LoadedPlugin): PluginGrants {
  const r = g && typeof g === "object" && !Array.isArray(g) ? g as Record<string, unknown> : {};
  const capUi = loaded.manifest?.capabilities.includes("ui") === true;
  const declaredRn = loaded.manifest?.permissions?.rawNetwork === true;
  const declaredIc = new Set(loaded.manifest?.permissions?.intercept ?? []);
  const intercept = Array.isArray(r.intercept) ? r.intercept : [];
  return {
    ui: capUi && r.ui === true,
    rawNetwork: declaredRn && r.rawNetwork === true,
    intercept: intercept.filter((a) => INTERCEPT_SET.has(a) && declaredIc.has(a)),
  };
}

// Enable is the ui grant. The Plugins list shows a ⚠, not a nested UI row.
function grantUiOnEnable(id: string, rt: Runtime): void {
  if (rt.loaded.manifest?.capabilities.includes("ui") !== true) return;
  rt.grants = sanitizeGrants({ ...rt.grants, ui: true }, rt.loaded);
  if (cfg) cfg.grants[id] = rt.grants;
}

export function initPlugins(opts: { pluginsDir: string; pluginDataRoot: string; hostPath: string;
                                    enabled: Record<string, boolean>;
                                    grants: Record<string, PluginGrants>; onChanged: () => void }): void {
  cfg = opts;
  mkdirSync(opts.pluginsDir, { recursive: true });
  let dirs: string[] = [];
  try { dirs = readdirSync(opts.pluginsDir, { withFileTypes: true })
          .filter((e) => e.isDirectory()).map((e) => e.name).sort(); } catch {}
  const takenKeys = new Set<string>();
  for (const name of dirs) {
    const loaded = loadPluginDir(join(opts.pluginsDir, name), takenKeys);
    const id = loaded.manifest?.id ?? name;
    // Two directories, one id: the first in sorted order wins (`foo` over
    // `foo.bak`), so the manifest, settings schema and `dir` stay on the copy
    // being edited. The other becomes an error row keyed by directory, since
    // its id is taken.
    if (plugins.has(id)) {
      plugins.set(`dir:${name}`, {
        loaded: { ...loaded, manifest: null },
        enabled: false, grants: EMPTY_GRANTS, state: "error",
        error: `duplicate plugin id "${id}": already loaded from another directory`,
        proc: null, sources: [], events: [], restarts: [], nextId: 1, pending: new Map(),
      });
      continue;
    }
    const rt: Runtime = {
      loaded, enabled: opts.enabled[id] === true,
      grants: sanitizeGrants(opts.grants[id], loaded),
      state: loaded.error ? "error" : "stopped", error: loaded.error,
      proc: null, sources: [], events: [], restarts: [], nextId: 1, pending: new Map(),
    };
    plugins.set(id, rt);
    if (rt.enabled && !loaded.error) {
      grantUiOnEnable(id, rt);
      spawnPlugin(id);
    }
  }
}

function spawnPlugin(id: string): void {
  const rt = plugins.get(id);
  if (!rt || !cfg || !rt.loaded.manifest) return;
  // A ui-only plugin has no sidecar entry: nothing to spawn, and the host would
  // die on join(undefined). Mark it running so the shell loads its QML. Gated
  // here so initPlugins, setPluginEnabled, doRestart and crash-restart obey it.
  if (!rt.loaded.manifest.entry.sidecar) {
    rt.state = "running";
    rt.error = null;
    rt.sources = [];
    rt.events = [];
    cfg.onChanged();
    return;
  }
  const dataDir = join(cfg.pluginDataRoot, id);
  mkdirSync(dataDir, { recursive: true });
  const distDir = dirname(cfg.hostPath);
  // Node --permission needs the directory-CONTENTS form (trailing /*), one
  // flag per path. fs reach: the plugin's own folder + its data dir + the
  // host bundle dir. Writes: the data dir only.
  const p = spawn(process.execPath,
    ["--permission",
     `--allow-fs-read=${rt.loaded.dir}/*`,
     `--allow-fs-read=${dataDir}/*`,
     `--allow-fs-read=${distDir}/*`,
     `--allow-fs-write=${dataDir}/*`,
     cfg.hostPath, rt.loaded.dir, dataDir, JSON.stringify(rt.grants)],
    { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  rt.proc = p;
  rt.error = null;
  // state becomes "running" only when the host reports `registered` (sources
  // ready) — not at spawn, else callers race an empty source list
  createInterface({ input: p.stdout! }).on("line", (line) => onHostLine(id, line));
  p.stderr!.on("data", (d) => process.stderr.write(`[plugin:${id}] ${d}`));
  // An 'error' with no listener throws and would take the sidecar down (EMFILE/
  // EACCES in a restart storm); treat it as this plugin's spawn failure. The
  // `rt.proc === p` guard stops error+exit double-counting a restart.
  p.on("error", (e) => { if (rt.proc === p) { log(`[plugins] ${id} spawn error: ${e}`); onExit(id, -1); } });
  p.on("exit", (code) => { if (rt.proc === p) onExit(id, code ?? -1); });
  cfg.onChanged();
}

function onHostLine(id: string, line: string): void {
  const rt = plugins.get(id);
  if (!rt || !line.trim()) return;
  let msg: any;
  try { msg = JSON.parse(line); } catch { return; }   // ignore non-protocol stdout
  if (msg.method === "registered") {
    rt.sources = msg.params.sources ?? [];
    rt.events = msg.params.events ?? [];
    rt.state = "running";
    cfg?.onChanged();
  } else if (msg.method === "fatal") {
    // host reported a load failure — treat like an invalid plugin, don't restart
    rt.enabled = false;
    rt.state = "error";
    rt.error = String(msg.params?.error ?? "plugin failed to load");
    log(`[plugins] ${id} failed to load: ${rt.error}`);
    cfg?.onChanged();
  } else if (msg.method === "log") {
    log(`[plugin:${id}]`, msg.params.msg);
  } else if (msg.id !== undefined) {
    const pend = rt.pending.get(msg.id);
    if (!pend) return;
    rt.pending.delete(msg.id);
    clearTimeout(pend.timer);
    if (msg.error) pend.reject(new Error(msg.error.message));
    else pend.resolve(msg.result);
  }
}

function onExit(id: string, code: number): void {
  const rt = plugins.get(id);
  if (!rt) return;
  rt.proc = null;
  for (const [, pend] of rt.pending) { clearTimeout(pend.timer); pend.reject(new Error("plugin exited")); }
  rt.pending.clear();
  if (!rt.enabled) { rt.state = rt.state === "error" ? "error" : "stopped"; cfg?.onChanged(); return; }
  const now = Date.now();
  rt.restarts = rt.restarts.filter((t) => now - t < 60000);
  if (rt.restarts.length >= 3) {
    rt.state = "crashed";
    rt.error = `exited (code ${code}) too often; parked`;
    log(`[plugins] ${id} crashed too often; parked`);
  } else {
    rt.restarts.push(now);
    log(`[plugins] ${id} exited (code ${code}); restarting`);
    spawnPlugin(id);
    return;
  }
  cfg?.onChanged();
}

function callPlugin(rt: Runtime, method: string, params: object, timeoutMs: number): Promise<any> {
  if (!rt.proc || rt.state !== "running") return Promise.reject(new Error("plugin not running"));
  const id = rt.nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { rt.pending.delete(id); reject(new Error(`${method} timed out`)); }, timeoutMs);
    rt.pending.set(id, { resolve, reject, timer });
    rt.proc!.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

function bySource(sourceId: string): Runtime | undefined {
  for (const rt of plugins.values())
    if (rt.sources.some((s) => s.id === sourceId)) return rt;
  return undefined;
}

export function listPlugins(): PluginInfo[] {
  return [...plugins.entries()].map(([id, rt]) => ({
    id, name: rt.loaded.manifest?.name ?? id,
    version: rt.loaded.manifest?.version ?? "",
    description: rt.loaded.manifest?.description, author: rt.loaded.manifest?.author,
    capabilities: rt.loaded.manifest?.capabilities ?? [],
    permissions: rt.loaded.manifest?.permissions ?? {},
    warnings: rt.loaded.warnings, enabled: rt.enabled, grants: rt.grants,
    state: rt.state, error: rt.error, sources: rt.sources,
    ui: rt.loaded.manifest?.ui ?? null,
    settings: rt.loaded.manifest?.settings ?? [],
    commands: rt.loaded.manifest?.commands ?? [],
    dir: rt.loaded.dir,
    entryQml: rt.loaded.manifest?.entry?.qml ?? null,
  }));
}

// Options for a `file` settings field: the files in the plugin's data subdir.
// Dir and extension filter come from the loaded manifest, never the caller, so
// an unknown id or key lists nothing. `dir` gets the same containment check as
// every manifest path; a traversal lists nothing.
export function pluginSettingFiles(id: string, key: string): string[] {
  const rt = plugins.get(id);
  const field = rt?.loaded.manifest?.settings.find((f) => f.key === key && f.type === "file");
  if (!cfg || !field) return [];
  const root = resolve(join(cfg.pluginDataRoot, id));
  const abs = resolve(join(root, field.dir ?? ""));
  if (abs !== root && !abs.startsWith(root + sep)) return [];
  const exts = (field.extensions ?? []).map((e) => e.toLowerCase().replace(/^\./, ""));
  try {
    return readdirSync(abs, { withFileTypes: true })
      .filter((e) => e.isFile())
      .map((e) => e.name)
      .filter((n) => exts.length === 0
                     || exts.includes((n.split(".").pop() ?? "").toLowerCase()))
      .sort();
  } catch { return []; }        // no such folder yet is an empty list, not an error
}

export function setPluginEnabled(id: string, on: boolean): PluginInfo[] {
  const rt = plugins.get(id);
  if (!rt) return listPlugins();
  // An invalid plugin can still be turned off — otherwise the Plugins tab
  // shows a live toggle that cannot move. Turning one on is refused until
  // rescan (or a restart) reloads a valid manifest.
  if (rt.loaded.error) {
    if (!on && rt.enabled) {
      rt.enabled = false;
      cfg?.onChanged();
    }
    return listPlugins();
  }
  rt.enabled = on;
  rt.restarts = [];
  if (on) grantUiOnEnable(id, rt);
  if (on && !rt.proc) spawnPlugin(id);
  // a ui-only plugin has no rt.proc — it still has to leave "running"
  else if (!on) { rt.proc?.kill(); rt.state = "stopped"; }
  cfg?.onChanged();
  return listPlugins();
}

export function setPluginGrants(id: string, patch: Partial<PluginGrants>): PluginInfo[] {
  const rt = plugins.get(id);
  if (rt && !rt.loaded.error) {
    rt.grants = sanitizeGrants({ ...rt.grants, ...patch }, rt.loaded);
    if (cfg) cfg.grants[id] = rt.grants;
    cfg?.onChanged();
  }
  return listPlugins();
}

// Re-scan the plugins dir: register new folders (disabled) without touching
// loaded plugins, retry plugins in error so a replaced folder loads, and drop
// entries whose folder is gone. No app restart needed.
export function rescanPlugins(): PluginInfo[] {
  if (!cfg) return listPlugins();
  let entries: string[] = [];
  try { entries = readdirSync(cfg.pluginsDir, { withFileTypes: true })
          .filter((e) => e.isDirectory()).map((e) => e.name).sort(); } catch {}
  const seen = new Set<string>();
  let takenKeys = new Set<string>();
  const existingByDir = new Map<string, string>();
  for (const [id, rt] of plugins) {
    existingByDir.set(resolve(rt.loaded.dir), id);
    for (const command of rt.loaded.manifest?.commands ?? []) {
      const key = command.default ?? "";
      if (key !== "" && !GESTURE_SET.has(key)) takenKeys.add(key);
    }
  }
  for (const name of entries) {
    const pluginDir = resolve(join(cfg.pluginsDir, name));
    const existingId = existingByDir.get(pluginDir);
    if (existingId !== undefined) {
      seen.add(existingId);
      const rt = plugins.get(existingId);
      // Reopen-tab path: a plugin already in error is retried so replacing
      // the folder heals without an app restart. Healthy runtimes stay put.
      if (rt?.loaded.error) {
        const candidateTakenKeys = new Set(takenKeys);
        const loaded = loadPluginDir(pluginDir, candidateTakenKeys);
        rt.loaded = loaded;
        rt.error = loaded.error;
        if (loaded.error) {
          rt.state = "error";
        } else {
          takenKeys = candidateTakenKeys;
          rt.grants = sanitizeGrants(rt.grants, loaded);
          if (rt.enabled) {
            grantUiOnEnable(existingId, rt);
            spawnPlugin(existingId);
          }
          else { rt.state = "stopped"; rt.error = null; }
        }
      }
      continue;
    }
    const candidateTakenKeys = new Set(takenKeys);
    const loaded = loadPluginDir(pluginDir, candidateTakenKeys);
    const id = loaded.manifest?.id ?? name;
    seen.add(id);
    if (plugins.has(id)) continue;   // keep existing runtime intact
    takenKeys = candidateTakenKeys;
    plugins.set(id, {
      loaded, enabled: false,
      grants: sanitizeGrants(cfg.grants[id], loaded),
      state: loaded.error ? "error" : "stopped", error: loaded.error,
      proc: null, sources: [], events: [], restarts: [], nextId: 1, pending: new Map(),
    });
  }
  // forget plugins whose folder was removed (kill if somehow still running)
  for (const [id, rt] of [...plugins]) {
    if (!seen.has(id)) { rt.enabled = false; rt.proc?.kill(); plugins.delete(id); }
  }
  cfg.onChanged();
  return listPlugins();
}

function doRestart(id: string): void {
  const rt = plugins.get(id);
  if (!rt || rt.loaded.error) return;
  rt.enabled = true;
  rt.restarts = [];              // clear the park counter
  if (rt.proc) rt.proc.kill();   // onExit respawns it (enabled, counter reset)
  else spawnPlugin(id);          // crashed/stopped: spawn directly
}
export function restartPlugin(id: string): PluginInfo[] {
  doRestart(id);
  cfg?.onChanged();
  return listPlugins();
}
// restart every enabled (or crashed) plugin — the single "Restart plugins"
// action in the settings header
export function restartAll(): PluginInfo[] {
  for (const [id, rt] of plugins)
    if (!rt.loaded.error && (rt.enabled || rt.state === "crashed")) doRestart(id);
  cfg?.onChanged();
  return listPlugins();
}

export function sourceList(): { id: string; name: string; pluginId: string }[] {
  const out: { id: string; name: string; pluginId: string }[] = [];
  for (const [pid, rt] of plugins)
    if (rt.state === "running")
      for (const s of rt.sources) out.push({ ...s, pluginId: pid });
  return out;
}

export function pluginSearch(sourceId: string, query: string, continuation?: string): Promise<any> {
  const rt = bySource(sourceId);
  if (!rt) return Promise.reject(new Error(`no source ${sourceId}`));
  return callPlugin(rt, "source/search", { sourceId, query, continuation }, 10000);
}
export function pluginResolveStream(sourceId: string, trackId: string): Promise<any> {
  const rt = bySource(sourceId);
  if (!rt) return Promise.reject(new Error(`no source ${sourceId}`));
  return callPlugin(rt, "source/resolveStream", { sourceId, trackId }, 30000);
}
export function dispatchPlayerEvent(type: string, payload: unknown): void {
  for (const rt of plugins.values())
    if (rt.state === "running" && rt.events.includes(type))
      callPlugin(rt, "event", { type, payload }, 5000).catch(() => {});
}

// tests: kill children + clear registry between cases
export async function _resetForTests(): Promise<void> {
  for (const rt of plugins.values()) rt.enabled = false;
  for (const rt of plugins.values()) rt.proc?.kill();
  plugins = new Map();
  cfg = null;
  await new Promise((r) => setTimeout(r, 100));
}
