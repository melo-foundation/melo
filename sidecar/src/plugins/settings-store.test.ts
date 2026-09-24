import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import type { SettingsField } from "./ui-manifest";

// dataDir is INJECTED via setEnv (there is no MELO_CONFIG_DIR); loadSettings
// also memoises, so each case gets a fresh module registry plus a fresh dir.
let root: string, dir: string;
beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "melo-set-"));
  dir = join(root, "data");
  const music = join(root, "music");
  mkdirSync(dir, { recursive: true });
  mkdirSync(music, { recursive: true });
  vi.resetModules();
  const { setEnv } = await import("../env");
  setEnv({ dataDir: dir, musicDir: music, ytdlpPath: "", osPrefersDark: true, appVersion: "test" });
});
afterEach(() => { rmSync(root, { recursive: true, force: true }); });

const schema: SettingsField[] = [
  { key: "skin", type: "file", label: "Skin", dir: "skins", extensions: ["wsz"] },
  { key: "doubleSize", type: "toggle", label: "Double size", default: false },
  { key: "scroll", type: "select", label: "Scrolling", default: "always",
    options: [{ label: "Always", value: "always" }, { label: "Never", value: "never" }] },
];

describe("plugin settings", () => {
  it("returns manifest defaults when nothing is stored", async () => {
    const { pluginSettings } = await import("./settings-store");
    const v = pluginSettings("winamp", schema);
    expect(v.doubleSize).toBe(false);
    expect(v.scroll).toBe("always");
  });
  it("persists a set value and reads it back", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    expect(pluginSettings("winamp", schema).doubleSize).toBe(true);
  });
  it("survives a fresh read of the settings file (values reach disk)", async () => {
    const { setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    // drop the memoised settings + module registry, re-inject the same dataDir:
    // the value has to come back off disk, not out of the in-process cache.
    vi.resetModules();
    const { setEnv } = await import("../env");
    setEnv({ dataDir: dir, musicDir: join(root, "music"), ytdlpPath: "", osPrefersDark: true, appVersion: "test" });
    const { pluginSettings } = await import("./settings-store");
    expect(pluginSettings("winamp", schema).doubleSize).toBe(true);
  });
  it("refuses to store a key that is not in the schema", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    const { loadSettings } = await import("../settings");
    setPluginSetting("winamp", schema, "notARealKey", 1);
    expect(pluginSettings("winamp", schema)).not.toHaveProperty("notARealKey");
    // the read filter would hide it either way — the point is that it never
    // reaches disk, so undeclared keys can't accumulate in the settings file
    expect(loadSettings().plugins.settings?.winamp ?? {}).not.toHaveProperty("notARealKey");
  });
  it("drops a stored key the schema no longer declares", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    const shrunk = schema.filter((f) => f.key !== "doubleSize");
    expect(pluginSettings("winamp", shrunk)).not.toHaveProperty("doubleSize");
  });
  it("carries no value for an action field", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    const { loadSettings } = await import("../settings");
    const withAction: SettingsField[] = [...schema, { key: "reset", type: "action", label: "Reset", default: "x" }];
    expect(pluginSettings("winamp", withAction)).not.toHaveProperty("reset");
    setPluginSetting("winamp", withAction, "reset", true);
    expect(pluginSettings("winamp", withAction)).not.toHaveProperty("reset");
    expect(loadSettings().plugins.settings?.winamp ?? {}).not.toHaveProperty("reset");
  });
  it("keeps two plugins' values apart", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    setPluginSetting("other", schema, "doubleSize", false);
    expect(pluginSettings("winamp", schema).doubleSize).toBe(true);
    expect(pluginSettings("other", schema).doubleSize).toBe(false);
  });
  it("survives a schema that gained a field after values were stored", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    const grown: SettingsField[] = [...schema, { key: "newThing", type: "toggle", label: "New", default: true }];
    const v = pluginSettings("winamp", grown);
    expect(v.doubleSize).toBe(true);
    expect(v.newThing).toBe(true);
  });
  it("setting one key leaves the other keys of the same plugin alone", async () => {
    const { pluginSettings, setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    setPluginSetting("winamp", schema, "scroll", "never");
    const v = pluginSettings("winamp", schema);
    expect(v.doubleSize).toBe(true);
    expect(v.scroll).toBe("never");
  });
  it("does not clobber the plugin enable map", async () => {
    const { saveSettings, loadSettings } = await import("../settings");
    saveSettings({ plugins: { enabled: { winamp: true } } });
    const { setPluginSetting } = await import("./settings-store");
    setPluginSetting("winamp", schema, "doubleSize", true);
    expect(loadSettings().plugins.enabled.winamp).toBe(true);
  });
  it("round-trips plugin grants", async () => {
    const { saveSettings, loadSettings } = await import("../settings");
    saveSettings({ plugins: { enabled: { winamp: true },
      grants: { winamp: { ui: true, rawNetwork: false, intercept: ["play"] } } } });
    expect(loadSettings().plugins.grants?.winamp).toEqual(
      { ui: true, rawNetwork: false, intercept: ["play"] });
  });
});
