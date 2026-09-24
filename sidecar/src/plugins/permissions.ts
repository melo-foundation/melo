// Twin of src/plugins/InterceptMap.cpp kActions; keep both lists identical,
// do not DRY at runtime. The first six are playback and the compact toggle;
// the rest are melo's chrome buttons, whose commands offer here before acting,
// so a granted plugin can answer the EQ button instead of melo. Only
// play/pause/stop/next/prev have call-through (MeloUi.player.*); the others
// are handled or declined, and declining lets melo act.
export const INTERCEPT_ACTIONS = ["play", "pause", "stop", "next", "prev", "toggleCompact",
                                  "toggleQueue", "toggleEq", "toggleVisualizer",
                                  "toggleSearch", "openSettings", "togglePin"] as const;
export type InterceptAction = typeof INTERCEPT_ACTIONS[number];
const INTERCEPT_SET = new Set<string>(INTERCEPT_ACTIONS);

export interface PluginPermissions {
  network?: string[];
  rawNetwork?: boolean;
  intercept?: InterceptAction[];
}
export interface PluginGrants {
  ui: boolean;
  rawNetwork: boolean;
  intercept: InterceptAction[];
}
export const EMPTY_GRANTS: PluginGrants = { ui: false, rawNetwork: false, intercept: [] };

// The keys the schema knows. An unknown key is not an error (a plugin written
// for a newer melo should run on an older one with less) but it is reported,
// because a typo grants nothing while its author believes it did.
const KNOWN_PERMISSIONS = new Set(["network", "rawNetwork", "intercept"]);

export function unknownPermissionKeys(raw: unknown): string[] {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return [];
  return Object.keys(raw as Record<string, unknown>).filter((k) => !KNOWN_PERMISSIONS.has(k));
}

export function validatePermissions(raw: unknown):
    { permissions: PluginPermissions; error: string | null } {
  if (raw === undefined || raw === null) return { permissions: {}, error: null };
  if (typeof raw !== "object" || Array.isArray(raw))
    return { permissions: {}, error: "permissions must be an object" };
  const r = raw as Record<string, unknown>;
  const out: PluginPermissions = {};
  if (r.network !== undefined) {
    if (!Array.isArray(r.network) || r.network.some((h) => typeof h !== "string"))
      return { permissions: {}, error: "permissions.network must be an array of strings" };
    out.network = r.network as string[];
  }
  if (r.rawNetwork === true) out.rawNetwork = true;
  if (r.intercept !== undefined) {
    if (!Array.isArray(r.intercept))
      return { permissions: {}, error: "permissions.intercept must be an array of action ids" };
    const seen = new Set<string>();
    const intercept: InterceptAction[] = [];
    for (const a of r.intercept) {
      if (typeof a !== "string" || !INTERCEPT_SET.has(a))
        return { permissions: {}, error: `permissions.intercept: unknown action: ${String(a)}` };
      if (seen.has(a))
        return { permissions: {}, error: `permissions.intercept: duplicate action: ${a}` };
      seen.add(a);
      intercept.push(a as InterceptAction);
    }
    out.intercept = intercept;
  }
  return { permissions: out, error: null };
}

export function permissionWarnings(p: {
  capabilities: string[]; permissions: PluginPermissions;
}): string[] {
  const w: string[] = [];
  // One sentence each, saying what the user agrees to (details: docs/plugins.md).
  // ui is the one uncontained grant, and its sentence says so. A plugin without
  // ui runs in its own child process under --permission with scoped fs grants
  // and the network allowlist. A ui plugin's QML runs in melo's process and
  // reaches native code: a directory import resolves against the document URL,
  // skips the import allowlist, and dlopens what its qmldir names. The allowlist
  // makes that harder to do by accident and does not prevent it.
  if (p.capabilities.includes("ui"))
    w.push("Runs with melo's full authority: its own code inside melo, "
           + "your files, and the network. Nothing sandboxes this grant.");
  if (p.permissions.rawNetwork)
    w.push("Network access is not limited to the sites it lists.");
  for (const a of p.permissions.intercept ?? [])
    w.push(`Handles ${a} instead of melo.`);
  return w;
}
