import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { join } from "path";
import { repoRoot } from "./harness";

// Where a plugin's buttons go, read out of the files the shell ships.
const components = join(repoRoot, "src", "qml", "components");
const read = (f: string) => readFileSync(join(components, f), "utf8");
// the player bar draws a plugin's button as a layout cell, "plugin:<pluginId>.<id>"
const player = read("barstyles/BarGroup.qml");
const title = read("TitleBar.qml");
const settings = read("SettingsWindow.qml");
const main = readFileSync(join(repoRoot, "src", "qml", "Main.qml"), "utf8");

describe("the bars show plugin buttons", () => {
  it("asks BarButtons for its own bar", () => {
    expect(title).toMatch(/BarButtons\.forBar\("title"\)/);
    // the player bar's layout names the button, and the cell looks it up
    expect(player).toMatch(/id\.startsWith\("plugin:"\)[\s\S]{0,200}BarButtons\.all\(\)/);
  });

  // forBar() and all() are methods, so a binding that calls one has nothing
  // to re-evaluate on. Same reason SlotMap and MeloUiArchive carry a generation.
  it("depends on generation, or the bars never update", () => {
    for (const [name, src, call] of [["TitleBar", title, "BarButtons.forBar"],
                                     ["BarGroup", player, "BarButtons.all"]] as const) {
      const at = src.indexOf(call);
      const binding = src.slice(Math.max(0, at - 300), at);
      expect(binding, name).toMatch(/BarButtons\.generation/);
    }
  });

  // A button and a keyboard binding to the same command must not diverge.
  it("clicks through CommandMap, not a private path", () => {
    expect(title).toMatch(/CommandMap\.invoke\(modelData\.command\)/);
    expect(player).toMatch(/CommandMap\.invoke\(b\.command\)/);
  });
});

describe("hiding a plugin button", () => {
  it("lists every button, hidden ones included", () => {
    expect(settings).toMatch(/BarButtons\.all\(\)/);
    expect(settings).toMatch(/barButtonRows/);
  });

  // The row sits on the plugin's own page, beside everything else about that
  // plugin, so its label need not name the plugin.
  it("is a row on the plugin that owns the button", () => {
    expect(settings).toMatch(
      /barButtonRows\.filter\([\s\S]{0,80}pluginId === win\.pluginSettingsFor/);
    // ...and drops the plugin's name from the label, because the page is it.
    expect(settings).toMatch(/name:\s*modelData\.ownLabel/);
    expect(settings).toMatch(/ownLabel:[\s\S]{0,120}title bar[\s\S]{0,40}player bar/);
  });

  it("persists to the ui bag and is restored before the bars draw", () => {
    expect(settings).toMatch(/uiSet\("hiddenBarButtons"/);
    expect(main).toMatch(/setHiddenKeys\(Settings\.uiGet\("hiddenBarButtons"/);
  });

  // Two plugins may use the same button id — it is unique within a plugin, not
  // across them — so the row has to carry both halves of the key.
  it("hides by plugin AND button id", () => {
    expect(settings).toMatch(/showBarButton\(modelData\.pluginId,\s*\n?\s*modelData\.id/);
  });
});
