// Plugin manifest loading, validation, and the static source scan.
// A LoadedPlugin with error != null is REPORTED (Plugins tab) but never run.
import { readFileSync, existsSync, readdirSync } from "fs";
import { join, relative, resolve, sep } from "path";
import { validateUi, validateSettings, type UiBlock, type SettingsField } from "./ui-manifest";
import { validatePermissions, permissionWarnings, unknownPermissionKeys,
         type PluginPermissions } from "./permissions";
import { validateCommands, commandLoadWarnings, type CommandDecl } from "./commands";

export const API_VERSION = 3;
// Manifests declaring any version in this range load. NEVER narrow this to an
// equality check: a hard bump breaks every shipped plugin at once.
export const SUPPORTED_API_VERSIONS = [1, 2, 3];

export interface PluginManifest {
  id: string; name: string; version: string; apiVersion: number;
  author?: string; description?: string;
  capabilities: string[];
  entry: { sidecar?: string; qml?: string };
  ui?: UiBlock;
  settings: SettingsField[];
  permissions?: PluginPermissions;
  commands: CommandDecl[];
}
export interface LoadedPlugin {
  dir: string;
  manifest: PluginManifest | null;
  warnings: string[];
  error: string | null;
}

const RAW_NET = /(require\(\s*["']|from\s*["']|import\(\s*["']|import\s*["'])(node:)?(net|tls|dgram|http2?|https)["']/g;
// getBuiltinModule sits here rather than with RAW_NET because it reaches every
// builtin, not just the network ones, and it does so without going through a
// resolve hook.
const EVALISH = /\beval\s*\(|new\s+Function\s*\(|process\.binding|process\.dlopen|process\.getBuiltinModule/;
// QML-side equivalents of EVALISH. Qt.createQmlObject builds an object from a
// runtime string, so its contents can't be statically reviewed — same category
// as eval() on the JS side.
const QML_EVALISH = /Qt\.createQmlObject\s*\(|Qt\.createComponent\s*\(\s*["']file:/;

function scanSource(dir: string): string[] {
  const warnings: string[] = [];
  const walk = (d: string, depth: number) => {
    if (depth > 6) return;      // a shallow walk lets files hide below it
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) { walk(join(d, e.name), depth + 1); continue; }
      const isJs = /\.(mjs|cjs|js)$/.test(e.name);
      const isQml = /\.qml$/.test(e.name);
      if (!isJs && !isQml) continue;
      const abs = join(d, e.name);
      // Named relative to the plugin root, not as a bare filename: the walk goes
      // six deep over two file types, so ui/Main.qml and vendor/x/Main.qml would
      // otherwise produce identical warnings and the user could not tell which
      // file to open.
      const rel = relative(dir, abs);
      const src = readFileSync(abs, "utf8");
      if (isJs) {
        const seenModules = new Set<string>();
        for (const m of src.matchAll(RAW_NET)) {
          const mod = m[3];
          if (seenModules.has(mod)) continue;
          seenModules.add(mod);
          warnings.push(`${rel}: imports low-level network module (node:${mod}) — the network allowlist can't be enforced`);
        }
        if (EVALISH.test(src)) warnings.push(`${rel}: uses eval/new Function/process.binding/process.getBuiltinModule — code can't be statically reviewed`);
      }
      if (isQml && QML_EVALISH.test(src))
        warnings.push(`${rel}: uses Qt.createQmlObject or loads QML from a file path — code can't be statically reviewed`);
    }
  };
  try { walk(dir, 0); } catch { /* unreadable files are the host's problem later */ }
  return warnings;
}

export function loadPluginDir(dir: string, takenKeys: Set<string> = new Set()): LoadedPlugin {
  const out: LoadedPlugin = { dir, manifest: null, warnings: [], error: null };
  let raw: string;
  try { raw = readFileSync(join(dir, "manifest.json"), "utf8"); }
  catch { out.error = "manifest.json missing"; return out; }
  let m: any;
  try { m = JSON.parse(raw); } catch (e) { out.error = `manifest.json parse error: ${e}`; return out; }

  for (const k of ["id", "name", "version", "apiVersion", "entry"])
    if (m[k] === undefined) { out.error = `manifest missing required field: ${k} (need id/name/version/apiVersion/entry)`; return out; }
  if (typeof m.id !== "string" || !/^[a-z0-9][a-z0-9_-]*$/i.test(m.id)) {
    out.error = "manifest id must be a path-safe slug ([a-z0-9_-])"; return out;
  }
  if (!SUPPORTED_API_VERSIONS.includes(m.apiVersion)) {
    out.error = `apiVersion ${m.apiVersion} unsupported (this melo speaks ${SUPPORTED_API_VERSIONS.join(", ")})`;
    return out;
  }
  const resolvedDir = resolve(dir);
  // A path is acceptable only if it stays inside the plugin dir AND exists.
  // Same containment rule for every entry point, not just entry.sidecar.
  const checkRel = (rel: string | undefined, what: string): string | null => {
    if (rel === undefined) return null;
    if (typeof rel !== "string" || rel.length === 0) return `${what} must be a non-empty string`;
    const abs = resolve(join(dir, rel));
    const within = abs === resolvedDir || abs.startsWith(resolvedDir + sep);
    if (!within) return `${what} escapes the plugin directory: ${rel}`;
    if (!existsSync(abs)) return `${what} file not found: ${rel}`;
    return null;
  };
  const entrySidecar: string | undefined = m.entry?.sidecar;
  const entryQml: string | undefined = m.entry?.qml;
  if (entrySidecar === undefined && entryQml === undefined) {
    out.error = "entry needs at least one of: sidecar, qml"; return out;
  }
  for (const [rel, what] of [[entrySidecar, "entry.sidecar"], [entryQml, "entry.qml"]] as const) {
    const err = checkRel(rel, what);
    if (err) { out.error = err; return out; }
  }
  const uiRes = validateUi(m.ui, dir, m.apiVersion);
  if (uiRes.error) { out.error = uiRes.error; return out; }
  const setRes = validateSettings(m.settings);
  if (setRes.error) { out.error = setRes.error; return out; }
  const permRes = validatePermissions(m.permissions);
  if (permRes.error) { out.error = permRes.error; return out; }
  const commandRes = validateCommands(m.commands);
  if (commandRes.error) { out.error = commandRes.error; return out; }
  // A button invokes its own plugin's command. Only here are both blocks seen
  // (validateUi and validateCommands each see one); an undeclared command would
  // be a button that silently does nothing.
  const declared = new Set(commandRes.commands.map((c) => c.id));
  for (const b of uiRes.ui?.buttons ?? []) {
    if (declared.has(b.command)) continue;
    out.error = `button ${b.id}: command is not one this plugin declares: ${b.command}`;
    return out;
  }
  const caps: string[] = Array.isArray(m.capabilities) ? m.capabilities : [];
  // What melo implements, and nothing else: an unknown capability ("uii") would
  // load, declare nothing melo acts on, and give its author no reason why.
  // `dsp` and `vis` are refused so no plugin takes a name a later surface will
  // want; this is not a promise to build either.
  const KNOWN_CAPS = ["source", "events", "ui"];
  const RESERVED_CAPS = ["dsp", "vis"];
  for (const c of caps) {
    if (KNOWN_CAPS.includes(c)) continue;
    out.error = RESERVED_CAPS.includes(c)
      ? `capabilities: "${c}" is reserved and not implemented`
      : `capabilities: unknown capability: ${String(c)}`;
    return out;
  }
  if (caps.includes("ui") && !uiRes.ui) {
    out.error = 'capabilities includes "ui" but there is no ui block'; return out;
  }
  if (uiRes.ui && !caps.includes("ui")) {
    out.error = 'a ui block requires "ui" in capabilities'; return out;
  }
  // entry.qml is the shared-state root for the declared windows, so without a
  // ui block nothing mounts it. It is also the file the QML host loads
  // in-process, and without a ui block there is no apiVersion floor and no
  // "draws its own interface" warning; requiring the block keeps that warning
  // firing for every plugin that ships QML.
  if (entryQml !== undefined && !uiRes.ui) {
    out.error = "entry.qml requires a ui block (the qml entry is the root for the declared windows)"; return out;
  }
  out.manifest = {
    id: m.id, name: String(m.name), version: String(m.version), apiVersion: m.apiVersion,
    author: m.author, description: m.description,
    capabilities: caps,
    entry: { sidecar: entrySidecar, qml: entryQml },
    ui: uiRes.ui ?? undefined,
    settings: setRes.settings,
    permissions: permRes.permissions,
    commands: commandRes.commands,
  };
  // Every warning below is melo's own finding: the scan reads the plugin's
  // source, the rest key off the rebuilt out.manifest, so no manifest can
  // author or suppress one. Permission warnings first; ui matters most.
  // unknownPerms is not a permissionWarning: those are what the user agrees to
  // at install, and this one is for the manifest's author.
  const unknownPerms = unknownPermissionKeys(m.permissions).map((k) =>
    `manifest.json: unknown permission "${k}" — ignored, and grants nothing`);
  out.warnings = [...permissionWarnings({
    capabilities: caps, permissions: permRes.permissions,
  }), ...unknownPerms,
     ...commandLoadWarnings(m.id, commandRes.commands, takenKeys), ...scanSource(dir)];
  return out;
}
