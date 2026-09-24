import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { loadPluginDir, API_VERSION } from "./manifest";

// The plugin dir is nested one level inside `root` so that the containment
// tests, which write their escape target to `join(dir, "..")`, land inside the
// sandbox that afterEach removes — not in the shared system temp dir.
let root: string, dir: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "melo-plug-"));
  dir = join(root, "plugin");
  mkdirSync(dir);
});
afterEach(() => { rmSync(root, { recursive: true, force: true }); });

function write(manifest: unknown, main = "export default function activate() {}") {
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  writeFileSync(join(dir, "main.js"), main);
}

const good = {
  id: "demo", name: "Demo", version: "0.1.0", apiVersion: API_VERSION,
  capabilities: ["source"], entry: { sidecar: "main.js" },
  permissions: { network: ["example.com"] },
};

describe("loadPluginDir", () => {
  it("loads a valid manifest with no warnings", () => {
    write(good);
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.manifest!.id).toBe("demo");
    expect(p.warnings).toEqual([]);
  });
  it("rejects apiVersion mismatch", () => {
    write({ ...good, apiVersion: 99 });
    const p = loadPluginDir(dir);
    expect(p.error).toMatch(/apiVersion/);
    expect(p.manifest).toBeNull();
  });
  it("rejects missing required fields", () => {
    write({ id: "x" });
    expect(loadPluginDir(dir).error).toMatch(/name|version|entry/);
  });
  it("rejects malformed JSON without throwing", () => {
    writeFileSync(join(dir, "manifest.json"), "{nope");
    expect(loadPluginDir(dir).error).toMatch(/parse/i);
  });
  it("rejects missing entry file", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(good));
    expect(loadPluginDir(dir).error).toMatch(/entry/);
  });
  it("flags raw-net imports and eval in the static scan", () => {
    write(good, `import net from "node:net";\nexport default function activate(){ eval("1") }`);
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).toMatch(/node:net/);
    expect(p.warnings.join(" ")).toMatch(/eval/);
  });
  it("rejects ids unsafe for paths", () => {
    write({ ...good, id: "../evil" });
    expect(loadPluginDir(dir).error).toMatch(/id/);
  });
  it("flags every raw-net import in a file, not just the first", () => {
    write(good, `require("dgram");\nrequire("https");\n`);
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    const joined = p.warnings.join(" ");
    expect(joined).toMatch(/node:dgram/);
    expect(joined).toMatch(/node:https/);
  });
  it("flags bare side-effect raw-net imports", () => {
    write(good, `import "node:net";\n`);
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).toMatch(/node:net/);
  });
  it("rejects entry.sidecar paths that escape the plugin dir", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ ...good, entry: { sidecar: "../evil.js" } }));
    // create the file the traversal points at, so an unpatched impl would pass existsSync
    writeFileSync(join(dir, "..", "evil.js"), "export default function activate(){}");
    const p = loadPluginDir(dir);
    expect(p.error).toMatch(/entry/);
  });
  it("accepts apiVersion 1 (already-shipped plugins keep working)", () => {
    write({ ...good, apiVersion: 1 });
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.manifest!.apiVersion).toBe(1);
  });
  it("accepts apiVersion 2", () => {
    write({ ...good, apiVersion: 2 });
    expect(loadPluginDir(dir).error).toBeNull();
  });
  it("rejects apiVersion outside the supported range", () => {
    write({ ...good, apiVersion: 3 });
    expect(loadPluginDir(dir).error).toBeNull();
    write({ ...good, apiVersion: 4 });
    expect(loadPluginDir(dir).error).toMatch(/apiVersion/);
  });
  it("rejects a v2 ui.kind block rather than translating it", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    write({
      ...good, apiVersion: 2, capabilities: ["ui"], entry: { qml: "ui/Plugin.qml" },
      ui: { kind: "miniMode", windows: [
        { id: "main", qml: "ui/Plugin.qml", width: 275, height: 116, primary: true },
      ]},
    });
    const p = loadPluginDir(dir);
    expect(p.error).toMatch(/apiVersion 3/);
    expect(p.error).toMatch(/kind|ui/i);
  });
  it("accepts a v3 ui block with no kind", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    write({
      ...good, apiVersion: 3, capabilities: ["ui"], entry: { qml: "ui/Plugin.qml" },
      ui: { windows: [
        { id: "main", qml: "ui/Plugin.qml", width: 275, height: 116, primary: true },
      ]},
    });
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.manifest!.apiVersion).toBe(3);
    expect((p.manifest!.ui as any).kind).toBeUndefined();
    expect(p.warnings.join(" ")).toMatch(/inside melo/i);
    expect(p.warnings.join(" ")).not.toMatch(/mini/i);
  });
  it("still accepts apiVersion 1 source plugins", () => {
    write({ ...good, apiVersion: 1 });
    expect(loadPluginDir(dir).error).toBeNull();
  });
  // An unknown key grants nothing and does not stop the plugin loading — a
  // manifest written against a newer melo runs on an older one with less. It
  // does not pass in silence either: the other thing that produces an unknown
  // key is a typo, which grants nothing while its author believes otherwise.
  it("drops an unknown permission and says so, without failing the load", () => {
    write({ ...good, apiVersion: 1, permissions: { network: ["x.com"], storage: true } });
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.manifest!.permissions).toEqual({ network: ["x.com"] });
    expect(p.warnings.join(" ")).toMatch(/unknown permission "storage"/);
  });
  it("errors on an unknown intercept action", () => {
    write({ ...good, apiVersion: 1, permissions: { intercept: ["queue.add"] } });
    expect(loadPluginDir(dir).error).toMatch(/intercept/);
  });
  it("accepts a plugin with only entry.qml and no sidecar half", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 3, capabilities: ["ui"],
      entry: { qml: "ui/Plugin.qml" },
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.manifest!.entry.qml).toBe("ui/Plugin.qml");
    expect(p.manifest!.entry.sidecar).toBeUndefined();
  });
  // A button invokes its own plugin's command. Checked in loadPluginDir, not
  // validateUi, because only loadPluginDir has seen both blocks.
  const withButton = (command: string) => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 3, capabilities: ["ui"],
      entry: { qml: "ui/Entry.qml" },
      commands: [{ id: "toggleGroup", label: "Toggle" }],
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116,
                        primary: true }],
            buttons: [{ id: "b", bar: "player", command,
                        icon: "ui/icon.png", label: "B" }] },
    }));
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Entry.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(dir, "ui/icon.png"), "");
    return loadPluginDir(dir);
  };
  it("rejects a button whose command the plugin never declared", () => {
    expect(withButton("nope").error).toMatch(/nope/);
  });
  it("accepts a button whose command it did declare", () => {
    expect(withButton("toggleGroup").error).toBeNull();
  });
  it("rejects an unknown capability", () => {
    write({ ...good, capabilities: ["source", "uii"] });
    const p = loadPluginDir(dir);
    expect(p.error).toMatch(/uii/);
  });
  // Reserved rather than unknown: named so a plugin cannot take a word a later
  // transform or visualiser surface will want. GStreamer stays first-party, so
  // refusing these is not a promise to build them.
  it("rejects the reserved audio capabilities by name", () => {
    for (const c of ["dsp", "vis"]) {
      write({ ...good, capabilities: [c] });
      const p = loadPluginDir(dir);
      expect(p.error, c).toMatch(/reserved/);
    }
  });
  it("rejects capabilities declaring ui with no ui block", () => {
    write({ ...good, apiVersion: 3, capabilities: ["ui"] });
    expect(loadPluginDir(dir).error).toMatch(/no ui block/);
  });
  it("rejects a ui block without ui in capabilities", () => {
    write({
      ...good, apiVersion: 3, capabilities: ["source"],
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    });
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
    expect(loadPluginDir(dir).error).toMatch(/requires "ui" in capabilities/);
  });
  it("rejects an entry with neither sidecar nor qml", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ ...good, entry: {} }));
    expect(loadPluginDir(dir).error).toMatch(/entry/);
  });
  it("rejects entry.qml escaping the plugin directory", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 2, entry: { qml: "../evil.qml" } }));
    // create the file the traversal points at, so an impl that only ran
    // existsSync — with no containment check — would pass and must not
    writeFileSync(join(dir, "..", "evil.qml"), "import QtQuick\nItem {}\n");
    expect(loadPluginDir(dir).error).toMatch(/escapes/);
  });
  it("warns that a ui plugin runs with melo's full authority", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 3, capabilities: ["ui"], entry: { qml: "ui/Plugin.qml" },
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).toMatch(/inside melo/i);
  });
  // Warnings are melo's own finding (source scan, field-by-field rebuild); a
  // plugin shipping its own `warnings` must not author, replace, or silence
  // one. One test per route, so a failure on one does not hide the others.
  function writeForgedWarnings() {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Main.qml"),
      "import QtQuick\nItem { Component.onCompleted: Qt.createQmlObject('import QtQuick; Item{}', this) }\n");
    write({
      ...good, apiVersion: 3, capabilities: ["source", "ui"],
      warnings: ["reviewed and found totally safe"],
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    });
  }
  it("never adds a manifest-supplied warning to its own findings", () => {
    writeForgedWarnings();
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).not.toMatch(/totally safe/);
  });
  it("never lets a manifest-supplied warning replace the source scan", () => {
    writeForgedWarnings();
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).toMatch(/createQmlObject/);
  });
  it("drops a warnings field from the rebuilt manifest", () => {
    writeForgedWarnings();
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect((p.manifest as any).warnings).toBeUndefined();
  });
  it("scans .qml files for eval-like constructs", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "ui/Main.qml"),
      "import QtQuick\nItem { Component.onCompleted: Qt.createQmlObject('import QtQuick; Item{}', this) }\n");
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 3, capabilities: ["ui"], entry: { qml: "ui/Plugin.qml" },
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    expect(loadPluginDir(dir).warnings.join(" ")).toMatch(/createQmlObject/);
  });
  it("finds files deeper than three directories", () => {
    mkdirSync(join(dir, "a/b/c/d"), { recursive: true });
    writeFileSync(join(dir, "a/b/c/d/deep.js"), "eval('x')");
    write(good);
    expect(loadPluginDir(dir).warnings.join(" ")).toMatch(/eval/);
  });
  // Two files with the same basename in different folders must be
  // distinguishable, or the warning names nothing the user can open.
  it("names the offending file relative to the plugin root", () => {
    mkdirSync(join(dir, "vendor/deep"), { recursive: true });
    mkdirSync(join(dir, "other"), { recursive: true });
    writeFileSync(join(dir, "vendor/deep/shared.js"), "eval('x')");
    writeFileSync(join(dir, "other/shared.js"), "eval('y')");
    write(good);
    const joined = loadPluginDir(dir).warnings.join(" ");
    expect(joined).toMatch(/vendor\/deep\/shared\.js: uses eval/);
    expect(joined).toMatch(/other\/shared\.js: uses eval/);
  });
  // entry.qml is the root of the declared windows, so with no ui block it names
  // QML nothing would mount — and the QML host would load it in-process with no
  // apiVersion floor and no "draws its own interface" warning. Illegal, so that
  // warning stays the only trigger it needs to be.
  it("rejects entry.qml with no ui block", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 1, capabilities: ["source"], entry: { qml: "ui/Plugin.qml" },
    }));
    expect(loadPluginDir(dir).error).toMatch(/ui block/);
  });
  it("accepts entry.qml when a ui block is present", () => {
    mkdirSync(join(dir, "ui"), { recursive: true });
    writeFileSync(join(dir, "ui/Plugin.qml"), "import QtQuick\nQtObject {}\n");
    writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      ...good, apiVersion: 3, capabilities: ["ui"], entry: { qml: "ui/Plugin.qml" },
      ui: { windows: [
        { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    expect(loadPluginDir(dir).error).toBeNull();
  });
  it("accepts entry.sidecar alone with no ui block", () => {
    write(good);
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).not.toMatch(/inside melo/i);
  });
  it("rejects invalid command declarations through the manifest loader", () => {
    write({
      ...good,
      commands: [{ id: "toggleGroup", label: "G", default: "playerBar.wheel" }],
    });
    expect(loadPluginDir(dir).error).toMatch(/unknown gesture/);
  });
  it("appends command key collision warnings and clears the default", () => {
    write({
      ...good,
      commands: [{ id: "playSample", label: "Play sample", default: "Space" }],
    });
    const p = loadPluginDir(dir);
    expect(p.error).toBeNull();
    expect(p.warnings.join(" ")).toMatch(/demo\.playSample: default key already taken/);
    expect(p.manifest!.commands[0].default).toBe("");
  });
});
