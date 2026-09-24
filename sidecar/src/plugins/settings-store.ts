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

export function setPluginSetting(id: string, schema: SettingsField[],
                                 key: string, value: unknown): Record<string, unknown> {
  const field = schema.find((f) => f.key === key);
  if (!field || field.type === "action") return pluginSettings(id, schema);
  const s = loadSettings();
  const all = { ...(s.plugins?.settings ?? {}) };
  all[id] = { ...(all[id] ?? {}), [key]: value };
  saveSettings({ plugins: { ...(s.plugins ?? { enabled: {}, grants: {} }), settings: all } });
  return pluginSettings(id, schema);
}
