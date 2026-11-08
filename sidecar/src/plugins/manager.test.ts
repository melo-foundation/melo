import { describe, it, expect, beforeAll, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, cpSync, rmSync, writeFileSync, mkdirSync, symlinkSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { execSync } from "child_process";
import { initPlugins, listPlugins, setPluginEnabled, setPluginGrants, pluginSearch,
         pluginResolveStream, dispatchPlayerEvent, sourceList, restartPlugin,
         rescanPlugins, restartAll, pluginSettingFiles, _resetForTests, CHANGED_WARNING } from "./manager";
import type { PluginGrants } from "./permissions";

const HOST = resolve(__dirname, "../../dist/melo-plugin-host.mjs");
const FIXTURE = resolve(__dirname, "../../test-fixtures/sample-source");
const BROKEN = resolve(__dirname, "../../test-fixtures/broken-source");
const CRASH = resolve(__dirname, "../../test-fixtures/crash-source");
let root: string;
beforeAll(() => { execSync("npm run build", { cwd: resolve(__dirname, "../..") }); }, 120000);
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "melo-mgr-"));
  mkdirSync(join(root, "plugins"), { recursive: true });
  cpSync(FIXTURE, join(root, "plugins", "sample"), { recursive: true });
});
afterEach(async () => { await _resetForTests(); rmSync(root, { recursive: true, force: true }); });

function boot(enabled: Record<string, boolean> = { sample: true }) {
  initPlugins({ pluginsDir: join(root, "plugins"), pluginDataRoot: join(root, "plugin-data"),
                hostPath: HOST, enabled, grants: {}, onChanged: () => {} });
}
function writeQmlOnly() {
  const qdir = join(root, "plugins", "qmlonly");
  mkdirSync(join(qdir, "ui"), { recursive: true });
  writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
  writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
    id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
    capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
    ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    commands: [{ id: "toggleMain", label: "Toggle main", default: "" }],
  }));
}
function writeCommandPlugin(folder: string, id: string) {
  const dir = join(root, "plugins", folder);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "main.js"), "export default function activate() {}\n");
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    id, name: id, version: "1.0.0", apiVersion: 3,
    capabilities: ["source"], entry: { sidecar: "main.js" },
    commands: [{ id: "doThing", label: "Do thing", default: "KeyX" }],
  }));
}
const until = (pred: () => boolean, ms = 8000) => new Promise<void>((res, rej) => {
  const t0 = Date.now();
  const iv = setInterval(() => {
    if (pred()) { clearInterval(iv); res(); }
    else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error("timeout")); }
  }, 50);
});


// Two directories, one id: neither loads, so a folder named to sort first
// cannot take over the grants the user gave the other.
describe("a duplicate plugin id", () => {
  const writeTwin = (root: string, dir: string) => {
    mkdirSync(join(root, dir), { recursive: true });
    writeFileSync(join(root, dir, "main.js"), "export default function activate() {}\n");
    writeFileSync(join(root, dir, "manifest.json"), JSON.stringify({
      id: "twin", name: dir, version: "1.0.0", apiVersion: 3,
      capabilities: ["source"], entry: { sidecar: "main.js" },
    }));
  };

  it("refuses both directories, even when the id is enabled", () => {
    const root = mkdtempSync(join(tmpdir(), "melo-dup-"));
    writeTwin(root, "twin");
    writeTwin(root, "a-twin");
    initPlugins({ pluginsDir: root, pluginDataRoot: join(root, "data"),
                  hostPath: join(root, "host.mjs"), enabled: { twin: true }, grants: {},
                  onChanged: () => {} });
    const list = listPlugins();
    expect(list.filter((p) => p.id === "twin")).toHaveLength(0);
    for (const dir of ["twin", "a-twin"]) {
      const row = list.find((p) => p.id === `dir:${dir}`)!;
      expect(row.state).toBe("error");
      expect(row.enabled).toBe(false);
      expect(row.error).toMatch(/duplicate plugin id "twin": also in/);
    }
    rmSync(root, { recursive: true, force: true });
  });

  it("a copy dropped in while melo runs stops the running plugin", async () => {
    const root = mkdtempSync(join(tmpdir(), "melo-dup-"));
    writeTwin(root, "twin");
    initPlugins({ pluginsDir: root, pluginDataRoot: mkdtempSync(join(tmpdir(), "melo-dupdata-")),
                  hostPath: HOST, enabled: { twin: true }, grants: {}, onChanged: () => {} });
    await until(() => listPlugins()[0].state === "running");
    writeTwin(root, "a-twin");
    const list = rescanPlugins();
    expect(list.map((p) => p.id).sort()).toEqual(["dir:a-twin", "dir:twin"]);
    rmSync(join(root, "a-twin"), { recursive: true, force: true });
    const healed = rescanPlugins();
    expect(healed.map((p) => [p.id, p.enabled, p.state])).toEqual([["twin", false, "stopped"]]);
    rmSync(root, { recursive: true, force: true });
  });
});

// Grants hold what the user agreed to: the folder and the permission fields.
describe("plugin consent", () => {
  function bootWith(grants: Record<string, PluginGrants>, saved?: (g: Record<string, PluginGrants>) => void) {
    initPlugins({ pluginsDir: join(root, "plugins"), pluginDataRoot: join(root, "plugin-data"),
                  hostPath: HOST, enabled: { sample: true }, grants, onChanged: () => {}, saveGrants: saved });
  }
  async function agreed(): Promise<PluginGrants> {
    let stored: Record<string, PluginGrants> = {};
    bootWith({}, (g) => { stored = JSON.parse(JSON.stringify(g)); });
    await _resetForTests();
    return stored.sample;
  }
  const sample = () => listPlugins().find((p) => p.id === "sample")!;
  const setNetwork = (dir: string, network: string[]) => {
    const f = join(dir, "manifest.json");
    const m = JSON.parse(readFileSync(f, "utf8"));
    writeFileSync(f, JSON.stringify({ ...m, permissions: { ...(m.permissions ?? {}), network } }));
  };

  it("an enabled plugin with no consent stored adopts and saves its current one", async () => {
    const g = await agreed();
    expect(g.consent).toMatch(/^[0-9a-f]{64}$/);
  });

  it("starts when folder and permissions match what was agreed", async () => {
    const g = await agreed();
    bootWith({ sample: g });
    await until(() => sample().state === "running");
    expect(sample().enabled).toBe(true);
  });

  it("loads turned off, warned, when its permissions changed", async () => {
    const g = await agreed();
    setNetwork(join(root, "plugins", "sample"), ["evil.example"]);
    bootWith({ sample: g });
    expect(sample().enabled).toBe(false);
    expect(sample().state).toBe("stopped");
    expect(sample().warnings[0]).toBe(CHANGED_WARNING);
    await new Promise((r) => setTimeout(r, 300));
    expect(sourceList()).toEqual([]);
    setPluginEnabled("sample", true);
    await until(() => sample().state === "running");
    expect(sample().grants.consent).not.toBe(g.consent);
  });

  it("loads turned off when the same id comes from another folder", async () => {
    const g = await agreed();
    cpSync(join(root, "plugins", "sample"), join(root, "plugins", "elsewhere"), { recursive: true });
    rmSync(join(root, "plugins", "sample"), { recursive: true, force: true });
    bootWith({ sample: g });
    expect(sample().enabled).toBe(false);
    expect(sample().warnings[0]).toBe(CHANGED_WARNING);
  });

  it("a grants patch cannot set the consent", async () => {
    const g = await agreed();
    bootWith({ sample: g });
    setPluginGrants("sample", { consent: "forged" } as Partial<PluginGrants>);
    expect(sample().grants.consent).toBe(g.consent);
  });
});

describe("plugin manager", () => {
  it("scans, spawns enabled plugins, reports sources", async () => {
    boot();
    await until(() => listPlugins()[0]?.state === "running");
    expect(sourceList()).toEqual([{ id: "sample", name: "Sample Source", pluginId: "sample" }]);
  });
  it("routes search and resolveStream to the plugin", async () => {
    boot();
    await until(() => listPlugins()[0]?.state === "running");
    const r = await pluginSearch("sample", "dogs");
    expect(r.tracks[0].title).toBe("hit for dogs");
    const s = await pluginResolveStream("sample", "smp:1");
    expect(s.url).toMatch(/smp:1/);
  });
  it("disabled plugins don't run; setPluginEnabled spawns live", async () => {
    boot({ sample: false });
    expect(listPlugins()[0].state).toBe("stopped");
    setPluginEnabled("sample", true);
    await until(() => listPlugins()[0].state === "running");
  });
  it("a link added after load stops the plugin starting", () => {
    boot({});
    symlinkSync(join(root, "plugins"), join(root, "plugins", "sample", "up"));
    setPluginEnabled("sample", true);
    const p = listPlugins().find((x) => x.id === "sample")!;
    expect(p.state).toBe("error");
    expect(p.error).toMatch(/plugin folder contains a link \(up\)/);
    expect(sourceList()).toEqual([]);
  });
  it("a link in the data folder stops the plugin starting", () => {
    mkdirSync(join(root, "plugin-data", "sample"), { recursive: true });
    symlinkSync(root, join(root, "plugin-data", "sample", "out"));
    boot();
    const p = listPlugins().find((x) => x.id === "sample")!;
    expect(p.state).toBe("error");
    expect(p.error).toMatch(/data folder contains a link \(out\)/);
  });
  it("a plugin process sees only locale and time zone in its environment", async () => {
    writeFileSync(join(root, "plugins", "sample", "main.js"),
      "export default function activate() { throw new Error('ENV ' + JSON.stringify(process.env)); }\n");
    const lang = process.env.LANG;
    process.env.MELO_TEST_SECRET = "hunter2";
    process.env.LANG = "C.UTF-8";
    try { boot(); await until(() => listPlugins()[0].state === "error"); }
    finally {
      delete process.env.MELO_TEST_SECRET;
      if (lang === undefined) delete process.env.LANG; else process.env.LANG = lang;
    }
    const env = JSON.parse(listPlugins()[0].error!.replace(/^ENV /, ""));
    expect(env.MELO_TEST_SECRET).toBeUndefined();
    expect(env.HOME).toBeUndefined();
    expect(env.LANG).toBe("C.UTF-8");
  });
  it("invalid manifest reports error state, never throws", () => {
    mkdirSync(join(root, "plugins", "broken"));
    writeFileSync(join(root, "plugins", "broken", "manifest.json"), "{nope");
    boot({});
    const broken = listPlugins().find((p) => p.id === "broken");
    expect(broken!.state).toBe("error");
  });
  it("an error plugin can be turned off, but not back on", () => {
    mkdirSync(join(root, "plugins", "broken"));
    writeFileSync(join(root, "plugins", "broken", "manifest.json"), "{nope");
    boot({ broken: true });
    const before = listPlugins().find((p) => p.id === "broken")!;
    expect(before.state).toBe("error");
    expect(before.enabled).toBe(true);
    setPluginEnabled("broken", false);
    const off = listPlugins().find((p) => p.id === "broken")!;
    expect(off.enabled).toBe(false);
    expect(off.state).toBe("error");
    setPluginEnabled("broken", true);
    const still = listPlugins().find((p) => p.id === "broken")!;
    expect(still.enabled).toBe(false);
    expect(still.state).toBe("error");
  });
  it("rescan reloads an error plugin whose folder was fixed", () => {
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 2,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { kind: "miniMode" },
    }));
    boot({ sample: false, qmlonly: true });
    const before = listPlugins().find((p) => p.id === "qmlonly")!;
    expect(before.state).toBe("error");
    expect(before.enabled).toBe(true);
    expect(before.error).toMatch(/apiVersion 3/);
    writeQmlOnly();
    rescanPlugins();
    const after = listPlugins().find((p) => p.id === "qmlonly")!;
    expect(after.state).toBe("running");
    expect(after.enabled).toBe(true);
    expect(after.error).toBeNull();
  });
  it("the second plugin in stable directory order loses a colliding key default", () => {
    writeCommandPlugin("b-second", "second");
    writeCommandPlugin("a-first", "first");
    boot({ sample: false, first: false, second: false });

    const first = listPlugins().find((p) => p.id === "first")!;
    const second = listPlugins().find((p) => p.id === "second")!;
    expect(first.commands[0].default).toBe("KeyX");
    expect(first.warnings).not.toContain("first.doThing: default key already taken");
    expect(second.commands[0].default).toBe("");
    expect(second.warnings).toContain("second.doThing: default key already taken");
  });
  it("rescan preserves an existing key owner when a new folder sorts first", () => {
    writeCommandPlugin("z-owner", "owner");
    boot({ sample: false, owner: false });
    expect(listPlugins().find((p) => p.id === "owner")!.commands[0].default).toBe("KeyX");

    writeCommandPlugin("a-new", "newcomer");
    rescanPlugins();

    const owner = listPlugins().find((p) => p.id === "owner")!;
    const newcomer = listPlugins().find((p) => p.id === "newcomer")!;
    expect(owner.commands[0].default).toBe("KeyX");
    expect(owner.warnings).not.toContain("owner.doThing: default key already taken");
    expect(newcomer.commands[0].default).toBe("");
    expect(newcomer.warnings).toContain("newcomer.doThing: default key already taken");
  });
  it("dispatchPlayerEvent reaches subscribed plugins without throwing", async () => {
    boot();
    await until(() => listPlugins()[0]?.state === "running");
    dispatchPlayerEvent("trackChanged", { track: { id: "zz" } });
    await new Promise((r) => setTimeout(r, 300));
  });
  it("a plugin whose activate() throws lands in error state (host `fatal`)", async () => {
    cpSync(BROKEN, join(root, "plugins", "broken"), { recursive: true });
    boot({ sample: false, broken: true });
    await until(() => listPlugins().find((p) => p.id === "broken")?.state === "error");
    const b = listPlugins().find((p) => p.id === "broken")!;
    expect(b.error).toMatch(/boom on activate/);
    expect(b.enabled).toBe(false);   // fatal disables, no restart
  });
  it("a load failure is one line; the stack is not in the error", async () => {
    cpSync(BROKEN, join(root, "plugins", "broken"), { recursive: true });
    boot({ sample: false, broken: true });
    await until(() => listPlugins().find((p) => p.id === "broken")?.state === "error");
    expect(listPlugins().find((p) => p.id === "broken")!.error).toBe("boom on activate");
  });
  it("enabling a rawNetwork plugin grants it and starts it; its node:net import is not warned twice", async () => {
    const dir = join(root, "plugins", "rawnet");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "main.js"), 'import net from "node:net";\nexport default function activate(melo) { melo.player.on("stopped", () => net); }\n');
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      id: "rawnet", name: "rawnet", version: "1.0.0", apiVersion: 1,
      capabilities: ["events"], entry: { sidecar: "main.js" }, permissions: { rawNetwork: true },
    }));
    boot({ sample: false });
    const rn = () => listPlugins().find((p) => p.id === "rawnet")!;
    expect(rn().warnings.some((w) => w.includes("low-level network module"))).toBe(false);
    expect(rn().warnings.some((w) => w.includes("not limited"))).toBe(true);
    setPluginEnabled("rawnet", true);
    expect(rn().grants.rawNetwork).toBe(true);
    await until(() => rn().state === "running");
  });
  it("rescan picks up a folder dropped in after boot (as stopped), no restart", async () => {
    rmSync(join(root, "plugins", "sample"), { recursive: true, force: true });
    initPlugins({ pluginsDir: join(root, "plugins"), pluginDataRoot: join(root, "plugin-data"),
                  hostPath: HOST, enabled: {}, grants: {}, onChanged: () => {} });
    expect(listPlugins().length).toBe(0);
    cpSync(FIXTURE, join(root, "plugins", "sample"), { recursive: true });
    rescanPlugins();
    const p = listPlugins().find((x) => x.id === "sample");
    expect(p).toBeTruthy();
    expect(p!.state).toBe("stopped");
    // enable it live — no app/sidecar restart
    setPluginEnabled("sample", true);
    await until(() => listPlugins().find((x) => x.id === "sample")?.state === "running");
  });
  it("rescan drops a plugin whose folder was removed", () => {
    boot({ sample: false });
    expect(listPlugins().length).toBe(1);
    rmSync(join(root, "plugins", "sample"), { recursive: true, force: true });
    rescanPlugins();
    expect(listPlugins().length).toBe(0);
  });
  it("restartPlugin starts a stopped plugin and respawns a running one", async () => {
    boot({ sample: false });
    expect(listPlugins()[0].state).toBe("stopped");
    restartPlugin("sample");
    await until(() => listPlugins()[0].state === "running");
    restartPlugin("sample");   // restart while running -> kill + respawn
    await new Promise((r) => setTimeout(r, 400));
    await until(() => listPlugins()[0].state === "running");
  });
  it("restartAll respawns every enabled plugin (running afterward)", async () => {
    boot({ sample: true });
    await until(() => listPlugins()[0].state === "running");
    restartAll();
    await new Promise((r) => setTimeout(r, 400));
    await until(() => listPlugins()[0].state === "running");
    expect(sourceList().length).toBe(1);   // source re-registered after respawn
  });
  it("a qml-only plugin runs without a node host", async () => {
    // No entry.sidecar at all. Spawning a host for it would hand plugin-host.ts
    // an undefined path to join(), which throws ERR_INVALID_ARG_TYPE, kills the
    // child, and lands the plugin in crashed after the restart budget.
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    const errs: string[] = [];
    const spy = vi.spyOn(process.stderr, "write")
      .mockImplementation((c: any) => { errs.push(String(c)); return true; });
    let synchronousState: string | undefined;
    try {
      boot({ sample: false, qmlonly: true });
      // running immediately: a spawned host only reports `registered` later
      synchronousState = listPlugins().find((p) => p.id === "qmlonly")?.state;
      await new Promise((r) => setTimeout(r, 1500));
    } finally { spy.mockRestore(); }
    const p = listPlugins().find((x) => x.id === "qmlonly")!;
    expect(synchronousState).toBe("running");
    expect(p.state).toBe("running");
    expect(p.error).toBeNull();
    // nothing was spawned, so no host stderr and no exit/restart log for it
    expect(errs.join("")).not.toMatch(/qmlonly/);
    // and it contributes no sources despite being "running"
    expect(sourceList()).toEqual([]);
  });
  it("disabling a qml-only plugin stops it without a process to kill", async () => {
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
    }));
    boot({ sample: false, qmlonly: true });
    expect(listPlugins().find((p) => p.id === "qmlonly")!.state).toBe("running");
    setPluginEnabled("qmlonly", false);
    expect(listPlugins().find((p) => p.id === "qmlonly")!.state).toBe("stopped");
    setPluginEnabled("qmlonly", true);
    expect(listPlugins().find((p) => p.id === "qmlonly")!.state).toBe("running");
  });
  it("listPlugins exposes ui, settings, commands and dir", async () => {
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
      settings: [{ key: "doubleSize", type: "toggle", label: "Double size", default: false }],
      commands: [{ id: "toggleMain", label: "Toggle main", default: "" }],
    }));
    boot({ sample: false, qmlonly: false });
    const p = listPlugins().find((x) => x.id === "qmlonly")!;
    expect(p.ui!.windows[0].qml).toBe("ui/Main.qml");
    expect(p.settings.map((f) => f.key)).toEqual(["doubleSize"]);
    expect(p.commands).toEqual([{ id: "toggleMain", label: "Toggle main", default: "" }]);
    expect(p.dir).toBe(qdir);
    // a sidecar plugin with neither block still reports the empty shapes
    const s = listPlugins().find((x) => x.id === "sample")!;
    expect(s.ui).toBeNull();
    expect(s.settings).toEqual([]);
    expect(s.commands).toEqual([]);
  });
  it("pluginSettingFiles lists the field's own folder, filtered and contained", () => {
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
      settings: [
        { key: "skin", type: "file", label: "Skin", dir: "skins", extensions: ["wsz", ".zip"] },
        { key: "notAFile", type: "toggle", label: "Not a file" },
      ],
    }));
    const skins = join(root, "plugin-data", "qmlonly", "skins");
    mkdirSync(skins, { recursive: true });
    for (const f of ["b.wsz", "a.WSZ", "c.zip", "notes.txt"]) writeFileSync(join(skins, f), "x");
    mkdirSync(join(skins, "adir.wsz"));           // directories are not options
    boot({ sample: false, qmlonly: false });
    expect(pluginSettingFiles("qmlonly", "skin")).toEqual(["a.WSZ", "b.wsz", "c.zip"]);
    expect(pluginSettingFiles("qmlonly", "notAFile")).toEqual([]); // wrong type
    expect(pluginSettingFiles("qmlonly", "nope")).toEqual([]);     // unknown key
    expect(pluginSettingFiles("nosuch", "skin")).toEqual([]);      // unknown plugin
  });
  // validateSettings rejects the whole manifest when a settings `dir`
  // traverses, which also covers melo's Settings page, where the same string
  // is concatenated into a file:// URL and opened with no check at all.
  it("a settings dir that escapes puts the whole plugin in error state", () => {
    const qdir = join(root, "plugins", "qmlonly");
    mkdirSync(join(qdir, "ui"), { recursive: true });
    writeFileSync(join(qdir, "ui", "Main.qml"), "import QtQuick\nItem {}\n");
    writeFileSync(join(qdir, "manifest.json"), JSON.stringify({
      id: "qmlonly", name: "Qml Only", version: "1.0.0", apiVersion: 3,
      capabilities: ["ui"], entry: { qml: "ui/Main.qml" },
      ui: { windows: [{ id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true }] },
      settings: [{ key: "skin", type: "file", label: "Skin",
                   dir: "../../../../../../home/someone/.ssh" }],
    }));
    boot({ sample: false, qmlonly: false });
    const p = listPlugins().find((x) => x.id === "qmlonly")!;
    expect(p.state).toBe("error");
    expect(p.error).toMatch(/\.\. segment/);
    expect(p.settings).toEqual([]);
    expect(pluginSettingFiles("qmlonly", "skin")).toEqual([]);
  });
  it("a repeatedly-crashing plugin is parked after the restart budget", async () => {
    cpSync(CRASH, join(root, "plugins", "crash"), { recursive: true });
    boot({ sample: false, crash: true });
    await until(() => listPlugins().find((p) => p.id === "crash")?.state === "crashed", 12000);
    expect(listPlugins().find((p) => p.id === "crash")!.state).toBe("crashed");
  });
  it("enabling a ui plugin grants ui", () => {
    writeQmlOnly();
    boot({ qmlonly: true });
    const p = listPlugins().find((x) => x.id === "qmlonly")!;
    expect(p.enabled).toBe(true);
    expect(p.grants.ui).toBe(true);
  });
  it("a stopped ui plugin is granted ui when turned on", () => {
    writeQmlOnly();
    boot({ qmlonly: false });
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.ui).toBe(false);
    setPluginEnabled("qmlonly", true);
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.ui).toBe(true);
  });
  it("setPluginGrants ui true on a ui plugin is listed", () => {
    writeQmlOnly();
    boot({ qmlonly: true });
    setPluginGrants("qmlonly", { ui: true });
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.ui).toBe(true);
  });
  it("setPluginGrants writes cfg.grants so a rediscovered folder keeps the grant", () => {
    writeQmlOnly();
    boot({ qmlonly: true });
    setPluginGrants("qmlonly", { ui: true });
    rmSync(join(root, "plugins", "qmlonly"), { recursive: true, force: true });
    rescanPlugins();
    expect(listPlugins().find((x) => x.id === "qmlonly")).toBeUndefined();
    writeQmlOnly();
    rescanPlugins();
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.ui).toBe(true);
  });
  it("cannot grant ui on a source-only plugin", () => {
    boot({ sample: true });
    setPluginGrants("sample", { ui: true });
    expect(listPlugins().find((x) => x.id === "sample")!.grants.ui).toBe(false);
  });
  it("cannot grant an intercept the manifest did not declare", () => {
    writeQmlOnly();
    boot({ qmlonly: true });
    setPluginGrants("qmlonly", { intercept: ["play"] });
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.intercept).toEqual([]);
  });
  it("a non-array intercept grant does not throw and yields []", () => {
    writeQmlOnly();
    // persisted settings JSON / RPC body are unchecked at runtime
    const bad = { intercept: "play" } as any;
    initPlugins({ pluginsDir: join(root, "plugins"), pluginDataRoot: join(root, "plugin-data"),
                  hostPath: HOST, enabled: { qmlonly: true },
                  grants: { qmlonly: bad }, onChanged: () => {} });
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.intercept).toEqual([]);
    expect(() => setPluginGrants("qmlonly", bad)).not.toThrow();
    expect(listPlugins().find((x) => x.id === "qmlonly")!.grants.intercept).toEqual([]);
  });
});
