import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { join } from "path";
import { repoRoot } from "./harness";

const source = readFileSync(
  join(repoRoot, "src", "qml", "components", "SettingsWindow.qml"), "utf8");
const grants = readFileSync(
  join(repoRoot, "src", "qml", "components", "plugingrants.js"), "utf8");

function between(from: string, to: string): string {
  const begin = source.indexOf(from);
  const end = source.indexOf(to, begin + from.length);
  expect(begin, `missing section ${from}`).toBeGreaterThanOrEqual(0);
  expect(end, `missing section ${to}`).toBeGreaterThan(begin);
  return source.slice(begin, end);
}

// A plugin's own options belong on ITS page, and the Plugins list stays a list
// of plugins: no provider select in Appearance, and no nested UI grant row that
// reads as a second plugin.
describe("plugin settings placement", () => {
  it("does not expose plugin provider selection in Appearance", () => {
    const appearance = between("// ============ APPEARANCE ============",
                               "// ============ SHORTCUTS ============");
    expect(appearance).not.toMatch(/miniModeProvider/);
    expect(appearance).not.toMatch(/name:\s*"Mini player"/);
  });

  it("keeps no mini-provider concept anywhere in Settings", () => {
    expect(source).not.toMatch(/Use as mini player/);
    expect(source).not.toMatch(/setMiniProvider/);
    expect(source).not.toMatch(/miniProvider/);
  });

  it("grants ui by enabling the plugin, not by a nested row", () => {
    // The warning sits on the plugin's own line, then an explicit button — one
    // decision on one row. `rows()` is what the nested Repeater draws, so a
    // `ui` entry reappearing there is the second-plugin look coming back.
    const plugins = source.slice(source.indexOf("// ============ PLUGINS ============"));
    expect(plugins).toMatch(
      /label: "Enable anyway"[\s\S]*sidecar\.setPluginEnabled\(pluginBlock\.modelData\.id, true\)/);
    expect(grants).not.toMatch(/out\.push\(\{\s*kind:\s*"ui"/);
  });

  it("draws holes a plugin actually asked for, and nothing else", () => {
    // rawNetwork and each declared intercept are real extra holes and keep
    // their own confirmed rows; they are driven off `permissions`, so a plugin
    // that declares neither (Winamp) shows no nested rows at all.
    expect(grants).toMatch(/if \(perms\.rawNetwork\)/);
    expect(grants).toMatch(/const ic = perms\.intercept \|\| \[\]/);
  });
});
