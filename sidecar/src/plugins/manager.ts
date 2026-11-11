// Plugin manager: one host child process per enabled plugin. Routes source
// calls (search / resolveStream) and player events to them and restarts
// crashes up to 3 per 60s, then parks. A plugin that fails to load or crashes
// never affects the sidecar or other plugins.
import { spawn, type ChildProcess } from "child_process";
import { createHash } from "crypto";
import { readdirSync, mkdirSync, readFileSync, lstatSync } from "fs";
import { join, dirname, resolve, sep, basename } from "path";
import { createInterface } from "readline";
import { loadPluginDir, linkError, type LoadedPlugin } from "./manifest";
import type { UiBlock, SettingsField } from "./ui-manifest";
import { EMPTY_GRANTS, INTERCEPT_ACTIONS, type PluginGrants, type PluginPermissions } from "./permissions";
import { GESTURE_IDS, type CommandDecl } from "./commands";
import { log } from "../rpc";
import { PluginProxy, isPrivateAddress } from "./net-proxy";
import { isIP } from "net";
import { lookup } from "dns/promises";
import { fileURLToPath } from "url";

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
  proxyToken?: string;             // this process's route through the network proxy
  awaitingProxy?: boolean;         // a spawn waits for the proxy to listen
}
let plugins = new Map<string, Runtime>();
let cfg: { pluginsDir: string; pluginDataRoot: string; hostPath: string;
           grants: Record<string, PluginGrants>; onChanged: () => void } | null = null;

// One proxy for every plugin process without rawNetwork, started on first use.
let proxy: PluginProxy | null = null;
let proxyPort = 0;
function startedProxy(): PluginProxy {
  if (!proxy) {
    const p = proxy = new PluginProxy();
    p.ready.then((port) => { if (proxy === p) proxyPort = port; }, (e) => log(`[plugins] network proxy failed: ${e}`));
  }
  return proxy;
}
function dropProxyRoute(rt: Runtime): void {
  if (rt.proxyToken) proxy?.remove(rt.proxyToken);
  rt.proxyToken = undefined;
}

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
    ...(typeof r.consent === "string" ? { consent: r.consent } : {}),
  };
}

// What turning a plugin on agrees to: its folder and every permission field.
// Grants hold this; a plugin whose value differs at launch loads turned off.
export function consentOf(loaded: LoadedPlugin): string {
  const m = loaded.manifest, p = m?.permissions ?? {};
  const sorted = (xs?: readonly string[]) => [...(xs ?? [])].map(String).sort();
  return createHash("sha256").update(JSON.stringify({
    dir: resolve(loaded.dir), ui: m?.capabilities.includes("ui") === true,
    network: sorted(p.network), rawNetwork: p.rawNetwork === true,
    intercept: sorted(p.intercept),
  })).digest("hex");
}

export const CHANGED_WARNING = "Its folder or permissions changed since you turned it on.";

// Enable is the ui and rawNetwork grant: the ⚠ lines on the plugin's row are
// what the user agrees to, with no nested row per grant.
function grantOnEnable(id: string, rt: Runtime): void {
  const m = rt.loaded.manifest;
  if (!m) return;
  const patch: Partial<PluginGrants> = { consent: consentOf(rt.loaded) };
  if (m.capabilities.includes("ui")) patch.ui = true;
  if (m.permissions?.rawNetwork) patch.rawNetwork = true;
  rt.grants = sanitizeGrants({ ...rt.grants, ...patch }, rt.loaded);
  if (cfg) cfg.grants[id] = rt.grants;
}

// An enabled plugin at launch or after its folder was replaced: it starts only
// when its folder and permissions are what the user agreed to. A plugin with no
// consent stored (enabled before melo kept one, or by hand) adopts its current one.
function startEnabled(id: string, rt: Runtime): void {
  const had = rt.grants.consent;
  if (had !== undefined && had !== consentOf(rt.loaded)) {
    rt.enabled = false;
    rt.state = "stopped";
    rt.grants = sanitizeGrants({ intercept: rt.grants.intercept, consent: had }, rt.loaded);
    rt.loaded = { ...rt.loaded, warnings: [CHANGED_WARNING, ...rt.loaded.warnings] };
    log(`[plugins] ${id} turned off: its folder or permissions changed`);
    return;
  }
  grantOnEnable(id, rt);
  spawnPlugin(id);
}

// The id a folder's manifest claims, read without validating the rest.
function claimedId(dir: string, name: string): string {
  try {
    const f = join(dir, "manifest.json");
    if (!lstatSync(f).isFile()) return name;
    const id = JSON.parse(readFileSync(f, "utf8"))?.id;
    return typeof id === "string" && id ? id : name;
  } catch { return name; }
}

// Ids claimed by more than one folder: every such folder is refused, so no copy
// inherits the grants the user gave another.
function duplicateIds(root: string, names: string[]): Map<string, string[]> {
  const byId = new Map<string, string[]>();
  for (const name of names) {
    const id = claimedId(join(root, name), name);
    byId.set(id, [...(byId.get(id) ?? []), name]);
  }
  return new Map([...byId].filter(([, dirs]) => dirs.length > 1));
}

function duplicateRow(dir: string, id: string, dirs: string[]): Runtime {
  return {
    loaded: { dir, manifest: null, warnings: [], error: null },
    enabled: false, grants: EMPTY_GRANTS, state: "error",
    error: `duplicate plugin id "${id}": also in ${dirs.filter((d) => d !== basename(dir)).join(", ")}; keep one folder`,
    proc: null, sources: [], events: [], restarts: [], nextId: 1, pending: new Map(),
  };
}

export function initPlugins(opts: { pluginsDir: string; pluginDataRoot: string; hostPath: string;
                                    enabled: Record<string, boolean>;
                                    grants: Record<string, PluginGrants>; onChanged: () => void;
                                    saveGrants?: (grants: Record<string, PluginGrants>) => void }): void {
  cfg = opts;
  mkdirSync(opts.pluginsDir, { recursive: true });
  let dirs: string[] = [];
  try { dirs = readdirSync(opts.pluginsDir, { withFileTypes: true })
          .filter((e) => e.isDirectory()).map((e) => e.name).sort(); } catch {}
  const takenKeys = new Set<string>();
  const dups = duplicateIds(opts.pluginsDir, dirs);
  for (const name of dirs) {
    const dupId = [...dups].find(([, ds]) => ds.includes(name));
    if (dupId) {
      plugins.set(`dir:${name}`, duplicateRow(join(opts.pluginsDir, name), dupId[0], dupId[1]));
      continue;
    }
    const loaded = loadPluginDir(join(opts.pluginsDir, name), takenKeys);
    const id = loaded.manifest?.id ?? name;
    const rt: Runtime = {
      loaded, enabled: opts.enabled[id] === true,
      grants: sanitizeGrants(opts.grants[id], loaded),
      state: loaded.error ? "error" : "stopped", error: loaded.error,
      proc: null, sources: [], events: [], restarts: [], nextId: 1, pending: new Map(),
    };
    plugins.set(id, rt);
    if (rt.enabled && !loaded.error) startEnabled(id, rt);
  }
  opts.saveGrants?.(opts.grants);
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
  // checked again here: a link can be added after load, and the data dir is not walked at load
  const linked = linkError(rt.loaded.dir) ?? linkError(dataDir, "the plugin's data folder");
  if (linked) {
    rt.enabled = false;
    rt.state = "error";
    rt.error = linked;
    log(`[plugins] ${id} not started: ${linked}`);
    cfg.onChanged();
    return;
  }
  // without rawNetwork, fetch goes through the proxy; the first spawn waits for it to listen
  const viaProxy = !rt.grants.rawNetwork;
  if (viaProxy && proxyPort === 0) {
    if (!rt.awaitingProxy) {
      rt.awaitingProxy = true;
      startedProxy().ready.then(() => {
        rt.awaitingProxy = false;
        if (plugins.get(id) === rt && rt.enabled && !rt.proc) spawnPlugin(id);
      }, () => { rt.awaitingProxy = false; });
    }
    return;
  }
  dropProxyRoute(rt);
  const env = pluginEnv();
  let execArgs: string[] = [];
  if (viaProxy) {
    const route = proxy!.add({
      network: rt.loaded.manifest.permissions?.network ?? [],
      onRefuse: (target, why) => log(`[plugin:${id}] network: refused ${target}: ${why}`),
    });
    rt.proxyToken = route.token;
    Object.assign(env, { NODE_USE_ENV_PROXY: "1", HTTP_PROXY: route.url, HTTPS_PROXY: route.url });
    execArgs = ["--disable-warning=UNDICI-EHPA"];
  }
  const distDir = dirname(cfg.hostPath);
  // Node --permission needs the directory-CONTENTS form (trailing /*), one
  // flag per path. fs reach: the plugin's own folder + its data dir + the
  // host bundle dir. Writes: the data dir only.
  const p = spawn(process.execPath,
    ["--permission", ...execArgs,
     `--allow-fs-read=${rt.loaded.dir}/*`,
     `--allow-fs-read=${dataDir}/*`,
     `--allow-fs-read=${distDir}/*`,
     `--allow-fs-write=${dataDir}/*`,
     cfg.hostPath, rt.loaded.dir, dataDir, JSON.stringify(rt.grants)],
    { stdio: ["pipe", "pipe", "pipe"], windowsHide: true, env });
  rt.proc = p;
  rt.error = null;
  // state becomes "running" only when the host reports `registered` (sources
  // ready) — not at spawn, else callers race an empty source list
  createInterface({ input: p.stdout! }).on("line", (line) => onHostLine(id, line));
  // every line carries the prefix, so a plugin cannot write a line that reads as melo's
  createInterface({ input: p.stderr! }).on("line", (line) => process.stderr.write(`[plugin:${id}] ${line}\n`));
  // An 'error' with no listener throws and would take the sidecar down (EMFILE/
  // EACCES in a restart storm); treat it as this plugin's spawn failure. The
  // `rt.proc === p` guard stops error+exit double-counting a restart.
  p.on("error", (e) => { if (rt.proc === p) { log(`[plugins] ${id} spawn error: ${e}`); onExit(id, -1); } });
  p.on("exit", (code) => { if (rt.proc === p) onExit(id, code ?? -1); });
  cfg.onChanged();
}

// The plugin process sees only locale and time zone: tokens, proxy credentials,
// SSH_AUTH_SOCK and the D-Bus address stay with melo. Windows needs SystemRoot.
const PLUGIN_ENV_KEYS = ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TZ", "SystemRoot"];
export function pluginEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = {};
  for (const k of PLUGIN_ENV_KEYS) if (env[k] !== undefined) out[k] = env[k];
  return out;
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
    for (const line of String(msg.params?.msg ?? "").split(/\r\n|\r|\n/)) log(`[plugin:${id}]`, line);
  } else if (msg.id !== undefined) {
    const pend = rt.pending.get(msg.id);
    if (!pend) return;
    rt.pending.delete(msg.id);
    clearTimeout(pend.timer);
    if (msg.error) pend.reject(new Error(msg.error.message));
    else pend.resolve(msg.result);
  }
}

// The sidecar exiting ends its plugins too, including one still booting.
process.on("exit", () => { for (const rt of plugins.values()) rt.proc?.kill(); });

function onExit(id: string, code: number): void {
  const rt = plugins.get(id);
  if (!rt) return;
  rt.proc = null;
  dropProxyRoute(rt);
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
  if (on) grantOnEnable(id, rt);
  if (on && !rt.proc) spawnPlugin(id);
  // a ui-only plugin has no rt.proc — it still has to leave "running"
  else if (!on) { rt.proc?.kill(); rt.state = "stopped"; }
  cfg?.onChanged();
  return listPlugins();
}

export function setPluginGrants(id: string, patch: Partial<PluginGrants>): PluginInfo[] {
  const rt = plugins.get(id);
  if (rt && !rt.loaded.error) {
    const before = JSON.stringify(rt.grants);
    const { consent: _ignored, ...asked } = patch;
    rt.grants = sanitizeGrants({ ...rt.grants, ...asked }, rt.loaded);
    if (cfg) cfg.grants[id] = rt.grants;
    // grants are fixed at spawn: an enabled plugin restarts to get the new ones
    if (rt.enabled && JSON.stringify(rt.grants) !== before) doRestart(id);
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
  // duplicate rows are worked out afresh on every scan
  for (const k of [...plugins.keys()]) if (k.startsWith("dir:")) plugins.delete(k);
  const dups = duplicateIds(cfg.pluginsDir, entries);
  for (const [id, dirs] of dups) {
    const rt = plugins.get(id);
    if (rt) { rt.enabled = false; rt.proc?.kill(); plugins.delete(id); }
    for (const name of dirs) {
      plugins.set(`dir:${name}`, duplicateRow(join(cfg.pluginsDir, name), id, dirs));
      seen.add(`dir:${name}`);
    }
  }
  const dupDirs = new Set([...dups.values()].flat());
  const existingByDir = new Map<string, string>();
  for (const [id, rt] of plugins) {
    if (id.startsWith("dir:")) continue;
    existingByDir.set(resolve(rt.loaded.dir), id);
    for (const command of rt.loaded.manifest?.commands ?? []) {
      const key = command.default ?? "";
      if (key !== "" && !GESTURE_SET.has(key)) takenKeys.add(key);
    }
  }
  for (const name of entries) {
    if (dupDirs.has(name)) continue;
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
          if (rt.enabled) startEnabled(existingId, rt);
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
  grantOnEnable(id, rt);
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
export async function pluginResolveStream(sourceId: string, trackId: string): Promise<any> {
  const rt = bySource(sourceId);
  if (!rt) throw new Error(`no source ${sourceId}`);
  const r = await callPlugin(rt, "source/resolveStream", { sourceId, trackId }, 30000);
  const roots = [rt.loaded.dir, ...(cfg ? [join(cfg.pluginDataRoot, rt.loaded.manifest?.id ?? "")] : [])];
  const url = await checkStreamUrl(r?.url, roots);
  const out: Record<string, unknown> = { url };
  for (const k of ["duration", "title", "channel", "video"]) if (r?.[k] !== undefined) out[k] = r[k];
  return out;
}

const within = (path: string, root: string) => {
  const p = resolve(path), r = resolve(root);
  return p === r || p.startsWith(r + sep);
};
async function publicHost(host: string): Promise<boolean> {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost")) return false;
  if (isIP(h)) return !isPrivateAddress(h);
  // a name that does not resolve cannot be played either
  try { return (await lookup(h, { all: true })).every((a) => !isPrivateAddress(a.address)); }
  catch { return true; }
}

// A plugin's stream URL: https or http to a public host, or a file in the
// plugin's own folder or data dir. Anything else would hand GStreamer or ffmpeg
// another URI handler, or a request to this machine or the local network.
export async function checkStreamUrl(raw: unknown, roots: string[]): Promise<string> {
  let u: URL;
  try { u = new URL(String(raw ?? "")); } catch { throw new Error("melo: resolveStream returned no valid url"); }
  if (u.protocol === "https:" || u.protocol === "http:") {
    if (!(await publicHost(u.hostname)))
      throw new Error(`melo: resolveStream returned a local or private address: ${u.hostname}`);
    return u.href;
  }
  if (u.protocol === "file:") {
    let path: string;
    try { path = fileURLToPath(u); } catch { throw new Error("melo: resolveStream returned a file url melo cannot open"); }
    if (!roots.some((r) => within(path, r)))
      throw new Error("melo: resolveStream returned a file outside the plugin's folder and data dir");
    return u.href;
  }
  throw new Error(`melo: resolveStream returned a ${u.protocol} url; use https`);
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
  proxy?.close();
  proxy = null;
  proxyPort = 0;
  await new Promise((r) => setTimeout(r, 100));
}
