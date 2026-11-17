// Per-plugin settings values: user-facing preferences, unlike melo.storage
// (private plugin state), so they live in melo's settings file at
// plugins.settings.<id>.<key> and use settings/get + settings/set. The schema
// is the allowlist: a stored key the manifest no longer declares is dropped.
import { loadSettings, saveSettings } from "../settings";
import type { SettingsField } from "./ui-manifest";

function stored(id: string): Record<string, unknown> {
  const s = loadSettings();
  return s.plugins?.settings?.[id] ?? {};
}

export function pluginSettings(id: string, schema: SettingsField[]): Record<string, unknown> {
  const have = stored(id);
  const out: Record<string, unknown> = {};
  for (const f of schema) {
    if (f.type === "action") continue;            // actions carry no value
    if (Object.prototype.hasOwnProperty.call(have, f.key)) out[f.key] = have[f.key];
    else if (f.default !== undefined) out[f.key] = f.default;
  }
  return out;
}

// A value must fit its row: a toggle a boolean, a select one of its options, a
// slider a number in range, text a string of at most 4096 characters, file a
// file name of that length.
const MAX_TEXT = 4096;
export function fitsField(f: SettingsField, v: unknown): boolean {
  switch (f.type) {
    case "toggle": return typeof v === "boolean";
    case "select": return typeof v === "string" && (f.options ?? []).some((o) => o.value === v);
    case "slider": return typeof v === "number" && Number.isFinite(v)
      && (f.from === undefined || v >= f.from) && (f.to === undefined || v <= f.to);
    case "text": return typeof v === "string" && v.length <= MAX_TEXT;
    case "file": return typeof v === "string" && v.length <= MAX_TEXT && !/[\\/]/.test(v);
    default: return false;
  }
}

export function setPluginSetting(id: string, schema: SettingsField[],
                                 key: string, value: unknown): Record<string, unknown> {
  const field = schema.find((f) => f.key === key);
  if (!field || field.type === "action" || !fitsField(field, value)) return pluginSettings(id, schema);
  const s = loadSettings();
  const all = { ...(s.plugins?.settings ?? {}) };
  all[id] = { ...(all[id] ?? {}), [key]: value };
  saveSettings({ plugins: { ...(s.plugins ?? { enabled: {}, grants: {} }), settings: all } });
  return pluginSettings(id, schema);
}
