import { INTERCEPT_ACTIONS } from "./permissions";
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, readFileSync } from "fs";
import { tmpdir } from "os";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { validateUi, validateSettings, SLOT_IDS } from "./ui-manifest";

// The plugin dir is nested one level inside `root` so that the containment
// test, which writes its escape target to `join(dir, "..")`, lands inside the
// sandbox that afterEach removes — not in the shared system temp dir.
let root: string, dir: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "melo-ui-"));
  dir = join(root, "plugin");
  mkdirSync(join(dir, "ui"), { recursive: true });
  writeFileSync(join(dir, "ui/Main.qml"), "import QtQuick\nItem {}\n");
  writeFileSync(join(dir, "ui/Eq.qml"), "import QtQuick\nItem {}\n");
  writeFileSync(join(dir, "ui/icon.png"), "");
  writeFileSync(join(dir, "ui/wave.frag.qsb"), "");
  writeFileSync(join(dir, "ui/wave.frag"), "");
});
afterEach(() => { rmSync(root, { recursive: true, force: true }); });

const qsb = "ui/wave.frag.qsb", frag = "ui/wave.frag";
const win = { id: "main", qml: "ui/Main.qml", width: 275, height: 116, primary: true };

describe("validateUi", () => {
  it("accepts a minimal single-window block", () => {
    const r = validateUi({ windows: [win] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows).toHaveLength(1);
    expect(r.ui!.windows[0].primary).toBe(true);
    expect((r.ui as any).kind).toBeUndefined();
  });
  it("accepts the three-window rig with snapTo and resize", () => {
    const r = validateUi({
      snap: { distance: 10 },
      windows: [win,
        { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main", initial: "hidden" }],
    }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.snap!.distance).toBe(10);
    expect(r.ui!.windows[1].snapTo).toBe("main");
  });
  it("rejects a ui block on apiVersion 1", () => {
    const r = validateUi({ windows: [win] }, dir, 1);
    expect(r.error).toMatch(/apiVersion 3/);
  });
  it("rejects a ui block on apiVersion 2", () => {
    const r = validateUi({ windows: [win] }, dir, 2);
    expect(r.error).toMatch(/apiVersion 3/);
  });
  it("rejects a v3 ui.kind block", () => {
    expect(validateUi({ kind: "miniMode", windows: [win] }, dir, 3).error).toMatch(/kind/);
  });
  it("rejects zero windows", () => {
    expect(validateUi({ windows: [] }, dir, 3).error).toMatch(/window/);
  });
  it("rejects a window qml path escaping the plugin dir", () => {
    // create the file the traversal points at, so an impl that only ran
    // existsSync — with no containment check — would pass and must not.
    // Without this the assertion could be satisfied by a mere "missing".
    writeFileSync(join(dir, "..", "evil.qml"), "import QtQuick\nItem {}\n");
    const bad = { ...win, qml: "../evil.qml" };
    expect(validateUi({ windows: [bad] }, dir, 3).error).toMatch(/escapes/);
  });
  it("rejects a window qml file that does not exist", () => {
    const bad = { ...win, qml: "ui/Missing.qml" };
    expect(validateUi({ windows: [bad] }, dir, 3).error).toMatch(/not found/);
  });
  it("rejects duplicate window ids", () => {
    const r = validateUi({ windows: [win, { ...win }] }, dir, 3);
    expect(r.error).toMatch(/duplicate/);
  });
  it("rejects snapTo naming a window that does not exist", () => {
    const bad = { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "ghost" };
    expect(validateUi({ windows: [win, bad] }, dir, 3).error).toMatch(/snapTo/);
  });
  // A cycle in the snapTo graph reaches the shell-side window positioner as
  // unbounded recursion or oscillating geometry — the app hangs. Reject it here,
  // at install time, where the offending window can still be named.
  it("rejects a window that snaps to itself", () => {
    const r = validateUi({ windows: [{ ...win, snapTo: "main" }] }, dir, 3);
    expect(r.error).toMatch(/cycle/);
    expect(r.error).toContain("main -> main");
  });
  it("rejects a two-window snapTo cycle", () => {
    const r = validateUi({ windows: [
      { ...win, snapTo: "eq" },
      { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main" },
    ] }, dir, 3);
    expect(r.error).toMatch(/cycle/);
    expect(r.error).toContain("main -> eq -> main");
  });
  it("rejects a three-window snapTo cycle", () => {
    const r = validateUi({ windows: [
      { ...win, snapTo: "eq" },
      { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "pl" },
      { id: "pl", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main" },
    ] }, dir, 3);
    expect(r.error).toMatch(/cycle/);
    expect(r.error).toContain("main -> eq -> pl -> main");
  });
  it("accepts a deep acyclic snapTo chain", () => {
    const r = validateUi({ windows: [
      win,
      { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main" },
      { id: "pl", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "eq" },
    ] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows).toHaveLength(3);
  });
  it("accepts a snapTo naming a window declared later in the array", () => {
    const r = validateUi({ windows: [
      { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main" },
      win,
    ] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows[0].snapTo).toBe("main");
  });
  // The Winamp rig: several windows docked to one main window. The naive form
  // of the acyclic memo — a single visited set marked on ENTRY rather than
  // after a completed walk — reports a false cycle on the second window here.
  it("accepts two windows snapping to the same target", () => {
    const r = validateUi({ windows: [
      win,
      { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, snapTo: "main" },
      { id: "pl", qml: "ui/Eq.qml", width: 275, height: 232, snapTo: "main" },
    ] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows.map((w) => w.snapTo)).toEqual([undefined, "main", "main"]);
  });
  // Geometry numbers reach shell-side window positioning. A zero step in a
  // round-to-nearest-step calculation is NaN geometry, so they are checked the
  // same way width/height are rather than silently dropped.
  it("rejects a negative snap distance", () => {
    const r = validateUi({ snap: { distance: -5 }, windows: [win] }, dir, 3);
    expect(r.error).toMatch(/snap\.distance/);
  });
  it("accepts a zero snap distance", () => {
    const r = validateUi({ snap: { distance: 0 }, windows: [win] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.snap!.distance).toBe(0);
  });
  it("rejects a zero shade height", () => {
    const bad = { ...win, shade: { height: 0 } };
    expect(validateUi({ windows: [bad] }, dir, 3).error).toMatch(/shade\.height/);
  });
  it("rejects a zero resize step", () => {
    const bad = { ...win, resize: { axes: "v", stepH: 0 } };
    expect(validateUi({ windows: [bad] }, dir, 3).error).toMatch(/resize\.stepH/);
  });
  it("rejects a negative resize minimum", () => {
    const bad = { ...win, resize: { axes: "vh", minWidth: -1 } };
    expect(validateUi({ windows: [bad] }, dir, 3).error).toMatch(/resize\.minWidth/);
  });
  it("keeps valid geometry rather than dropping it", () => {
    const w = { ...win, shade: { height: 14 }, resize: { axes: "vh", stepH: 29, minWidth: 275 } };
    const r = validateUi({ snap: { distance: 10 }, windows: [w] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows[0].shade!.height).toBe(14);
    expect(r.ui!.windows[0].resize).toEqual({ axes: "vh", stepH: 29, minWidth: 275 });
  });
  it("requires exactly one primary window", () => {
    const two = { id: "eq", qml: "ui/Eq.qml", width: 275, height: 116, primary: true };
    expect(validateUi({ windows: [win, two] }, dir, 3).error).toMatch(/primary/);
  });
});

describe("ui.buttons", () => {
  const btn = { id: "group", bar: "player", command: "toggleGroup",
                icon: "ui/icon.png", label: "Winamp" };

  it("accepts a button on each bar", () => {
    for (const bar of ["player", "title"]) {
      const r = validateUi({ windows: [win], buttons: [{ ...btn, bar }] }, dir, 3);
      expect(r.error, bar).toBeNull();
      expect(r.ui!.buttons![0].bar).toBe(bar);
    }
  });
  it("is optional", () => {
    const r = validateUi({ windows: [win] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.buttons).toBeUndefined();
  });
  // No cap: a count protects nothing, and every number is wrong for somebody.
  it("takes as many as the plugin declares", () => {
    const many = Array.from({ length: 12 }, (_, i) => ({ ...btn, id: `b${i}` }));
    const r = validateUi({ windows: [win], buttons: many }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.buttons).toHaveLength(12);
  });
  it("names an unknown bar", () => {
    const r = validateUi({ windows: [win], buttons: [{ ...btn, bar: "sidebar" }] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/sidebar/);
  });
  it("rejects a duplicate button id", () => {
    const r = validateUi({ windows: [win], buttons: [btn, btn] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/group/);
  });
  it("rejects an icon that escapes the plugin directory", () => {
    writeFileSync(join(dir, "..", "outside.png"), "");
    const r = validateUi({ windows: [win], buttons: [{ ...btn, icon: "../outside.png" }] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/escapes/);
  });
  it("rejects an icon that is not there", () => {
    const r = validateUi({ windows: [win], buttons: [{ ...btn, icon: "ui/nope.png" }] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/not found/);
  });
  it("requires a label, which is the tooltip and the name in the hide list", () => {
    const r = validateUi({ windows: [win], buttons: [{ ...btn, label: "" }] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/label/);
  });
  it("requires a command", () => {
    const r = validateUi({ windows: [win], buttons: [{ ...btn, command: "" }] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/command/);
  });
});

describe("ui.slots", () => {
  // A slot is a named place the shell already has; a plugin OFFERS to fill one
  // and the user binds it. Declaring is not being granted, exactly as declaring
  // an intercept is not being granted one.
  it("accepts a slot whose qml is inside the plugin", () => {
    const r = validateUi({ windows: [win], slots: { eq: "ui/Eq.qml" } }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.slots!.eq).toBe("ui/Eq.qml");
  });
  it("is optional, and absent means the plugin offers no slot", () => {
    const r = validateUi({ windows: [win] }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.slots).toBeUndefined();
  });
  // An unknown slot id is an error. Dropping it silently leaves a
  // plugin that never appears in any picker and no way to find out why.
  it("names an unknown slot id", () => {
    const r = validateUi({ windows: [win], slots: { eqq: "ui/Eq.qml" } }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/eqq/);
  });
  it("rejects qml that escapes the plugin directory", () => {
    writeFileSync(join(dir, "..", "Outside.qml"), "import QtQuick\nItem {}\n");
    const r = validateUi({ windows: [win], slots: { eq: "../Outside.qml" } }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/escapes/);
  });
  it("rejects qml that is not there", () => {
    const r = validateUi({ windows: [win], slots: { eq: "ui/Nope.qml" } }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/not found/);
  });
  it("rejects a slot whose value is not a path", () => {
    const r = validateUi({ windows: [win], slots: { eq: 7 } }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/eq/);
  });
  it("rejects slots that is not an object", () => {
    const r = validateUi({ windows: [win], slots: ["eq"] }, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/ui\.slots/);
  });
  // The catalog is the shell's, and every id in it is a place that exists
  // because the chrome exists. Kept as one list so the twin on the C++ side has
  // something to be a twin OF.
  it("accepts every id in the catalog", () => {
    for (const id of SLOT_IDS) {
      const r = validateUi({ windows: [win], slots: { [id]: "ui/Eq.qml" } }, dir, 3);
      expect(r.error, id).toBeNull();
    }
  });
});

describe("validateSettings", () => {
  it("accepts the documented field types", () => {
    const r = validateSettings([
      { key: "skin", type: "file", label: "Skin", dir: "skins", extensions: ["wsz"] },
      { key: "doubleSize", type: "toggle", label: "Double size", default: false },
      { key: "scroll", type: "select", label: "Title scrolling",
        options: [{ label: "Always", value: "always" }], default: "always" },
    ]);
    expect(r.error).toBeNull();
    expect(r.settings).toHaveLength(3);
  });
  it("rejects an unknown field type", () => {
    expect(validateSettings([{ key: "x", type: "colorwheel", label: "X" }]).error).toMatch(/type/);
  });
  it("rejects duplicate keys", () => {
    expect(validateSettings([
      { key: "a", type: "toggle", label: "A" },
      { key: "a", type: "toggle", label: "B" },
    ]).error).toMatch(/duplicate/);
  });
  it("rejects a select with no options", () => {
    expect(validateSettings([{ key: "a", type: "select", label: "A" }]).error).toMatch(/options/);
  });
  // loadPluginDir has no try/catch anywhere above it — initPlugins calls it
  // bare — so a throw here aborts sidecar startup instead of reporting one bad
  // plugin. Every malformed option must come back as an error value.
  it("rejects a null option entry without throwing", () => {
    const r = validateSettings([{ key: "a", type: "select", label: "A", options: [null] }]);
    expect(r.error).toMatch(/option/);
  });
  it("rejects options given as bare strings", () => {
    const r = validateSettings([{ key: "a", type: "select", label: "A", options: ["always"] }]);
    expect(r.error).toMatch(/option/);
    expect(r.settings).toHaveLength(0);
  });
  it("rejects an option whose label or value is not a string", () => {
    expect(validateSettings([{ key: "a", type: "select", label: "A",
      options: [{ label: "Always", value: 1 }] }]).error).toMatch(/option/);
    expect(validateSettings([{ key: "a", type: "select", label: "A",
      options: [{ value: "always" }] }]).error).toMatch(/option/);
  });
  // The Settings page concatenates `dir` into a file:// URL and hands it to
  // Qt.openUrlExternally with no check of its own, so a traversal here is one
  // click of "Open folder" away from melo xdg-opening any folder on the machine.
  it("rejects a file dir that escapes the plugin's data folder", () => {
    for (const bad of ["../../../home/someone/.ssh", "skins/../../..", "..",
                       "a/../../b", "..\\..\\windows"]) {
      const r = validateSettings([{ key: "skin", type: "file", label: "Skin", dir: bad }]);
      expect(r.error).toMatch(/\.\. segment/);
      expect(r.settings).toHaveLength(0);
    }
  });
  it("rejects an absolute file dir", () => {
    for (const bad of ["/etc", "\\\\server\\share", "C:\\Users"]) {
      expect(validateSettings([{ key: "skin", type: "file", label: "Skin", dir: bad }]).error)
        .toMatch(/relative/);
    }
  });
  it("rejects a non-string file dir", () => {
    expect(validateSettings([{ key: "skin", type: "file", label: "Skin", dir: 7 }]).error)
      .toMatch(/dir must be a string/);
  });
  it("accepts a nested relative file dir, and an absent one", () => {
    const r = validateSettings([
      { key: "skin", type: "file", label: "Skin", dir: "skins/classic" },
      { key: "other", type: "file", label: "Other" },
    ]);
    expect(r.error).toBeNull();
    expect(r.settings[0].dir).toBe("skins/classic");
    expect(r.settings[1].dir).toBe("");
  });
  // Only a whole segment is a traversal; "..equalizer" is just a folder name.
  it("accepts a name that merely starts with dots", () => {
    const r = validateSettings([{ key: "skin", type: "file", label: "Skin", dir: "..equalizer" }]);
    expect(r.error).toBeNull();
    expect(r.settings[0].dir).toBe("..equalizer");
  });
  it("drops a desc field rather than honouring it", () => {
    const r = validateSettings([{ key: "a", type: "toggle", label: "A", desc: "explanatory prose" }]);
    expect(r.error).toBeNull();
    expect((r.settings[0] as unknown as Record<string, unknown>).desc).toBeUndefined();
  });
});

// A plugin that only fills a slot has no window; that is the ordinary shape
// for a visualiser replacement, which draws where melo's visualiser draws and
// wants nothing of its own.
describe("a ui block without windows", () => {
  it("is fine when it declares slots", () => {
    const r = validateUi({ slots: { visualizer: "ui/Eq.qml" } }, dir, 3);
    expect(r.error).toBeNull();
    expect(r.ui!.windows ?? []).toHaveLength(0);
    expect(r.ui!.slots).toEqual({ visualizer: "ui/Eq.qml" });
  });

  it("is fine when it declares only buttons", () => {
    const r = validateUi({ buttons: [{ id: "b", bar: "player", label: "B",
                                       command: "c", icon: "ui/icon.png" }] }, dir, 3);
    expect(r.error).toBeNull();
  });

  // ...but a ui block that declares NOTHING is a plugin whose QML loads and can
  // never appear. That is the silent drop the slot id check exists to avoid, so
  // it is an error naming what is missing.
  it("is an error when it declares nothing at all", () => {
    const r = validateUi({}, dir, 3);
    expect(r.ui).toBeNull();
    expect(r.error).toMatch(/declares nothing/);
  });

  // The primary rule is about windows that exist, not a demand for one.
  it("needs no primary window when there are no windows", () => {
    const r = validateUi({ slots: { queuePanel: "ui/Eq.qml" } }, dir, 3);
    expect(r.error).toBeNull();
  });

  it("still needs exactly one primary when windows are declared", () => {
    const r = validateUi({ windows: [{ ...win, id: "a", primary: false },
                                     { ...win, id: "b", primary: false }] }, dir, 3);
    expect(r.error).toMatch(/exactly one primary/);
  });
});

// The skin's declaration as a fixture (tests/fixtures/skin-plugin), also read
// by tst_windowsnap: three windows, a snapTo chain, a two-axis resize grid,
// shade heights. Its QML is not instantiated, so a window can still be blank
// or loop. The skin's repository validates it with these same validators.
describe("a real multi-window manifest", () => {
  const winampDir = join(dirname(fileURLToPath(import.meta.url)),
                         "..", "..", "..", "tests", "fixtures", "skin-plugin");
  const shipped = JSON.parse(readFileSync(join(winampDir, "manifest.json"), "utf8"));

  it("is on disk where both readers look for it", () => {
    expect(shipped.id).toBe("skin-fixture");
    expect(shipped.capabilities).toContain("ui");
    expect(shipped.apiVersion).toBe(3);
    expect(shipped.ui.kind).toBeUndefined();
  });

  it("passes validateUi with its own files resolved from its own directory", () => {
    const r = validateUi(shipped.ui, winampDir, shipped.apiVersion);
    expect(r.error).toBeNull();
    // Every declared qml resolved — `within()` returns "missing" for a path
    // that is not there, so this also asserts the seven files exist.
    expect(r.ui!.windows.map((w) => w.id)).toEqual(["main", "eq", "playlist"]);
  });

  // Both halves of the bar surface. The button is additive: it sits beside
  // melo's controls and invokes the skin's own toggleGroup. The intercept is
  // the other half: granted toggleEq, melo's equaliser button opens the skin's
  // instead.
  it("ships a bar button bound to one of its own commands", () => {
    const { ui, error } = validateUi(shipped.ui, winampDir, shipped.apiVersion);
    expect(error).toBeNull();
    const b = ui!.buttons![0];
    expect(b.bar).toBe("player");
    expect(b.label.length).toBeGreaterThan(0);
    expect(shipped.commands.map((c: { id: string }) => c.id)).toContain(b.command);
  });

  // Declaring an intercept and ANSWERING it is a plugin-authoring rule, tested
  // in the skin's repository with the QML it reads. The half melo owns: a
  // declared action has to be one melo's catalog knows.
  it("asks for an intercept melo's catalog has", () => {
    expect(shipped.permissions.intercept).toEqual(["toggleEq"]);
    for (const a of shipped.permissions.intercept)
      expect(INTERCEPT_ACTIONS as readonly string[]).toContain(a);
  });

  it("declares the main <- eq <- playlist chain the shell positions", () => {
    const { ui } = validateUi(shipped.ui, winampDir, shipped.apiVersion);
    const [main, eq, pl] = ui!.windows;
    expect(main.primary).toBe(true);
    expect(main.snapTo).toBeUndefined();
    expect(eq.snapTo).toBe("main");
    expect(pl.snapTo).toBe("eq");
    // Both secondaries start hidden, which is what made the docked chain's
    // behaviour across a show the shipped default rather than an edge case.
    expect(eq.initial).toBe("hidden");
    expect(pl.initial).toBe("hidden");
  });

  it("declares only whole pixels, which is the reading the shell will make", () => {
    const { ui } = validateUi(shipped.ui, winampDir, shipped.apiVersion);
    const nums: number[] = [ui!.snap!.distance];
    for (const w of ui!.windows) {
      nums.push(w.width, w.height);
      if (w.shade) nums.push(w.shade.height);
      if (w.resize)
        for (const k of ["stepH", "stepW", "minHeight", "minWidth"] as const)
          if (w.resize[k] !== undefined) nums.push(w.resize[k]!);
    }
    for (const n of nums) expect(Number.isInteger(n)).toBe(true);
    // The values tst_windowsnap asserts the C++ host reads back, written out
    // here so a change to either file has to be made in both.
    expect(ui!.windows.map((w) => [w.width, w.height]))
      .toEqual([[275, 116], [275, 116], [275, 232]]);
    expect(ui!.windows[0].shade!.height).toBe(14);
    expect(ui!.windows[2].resize).toEqual({ axes: "vh", stepW: 25, stepH: 29,
                                           minWidth: 275, minHeight: 116 });
  });

  it("declares a settings schema melo's Settings page can build", () => {
    const r = validateSettings(shipped.settings);
    expect(r.error).toBeNull();
    expect(r.settings).toHaveLength(7);
    expect(r.settings[0]).toEqual({ key: "skin", type: "file", label: "Skin",
                                    dir: "skins", extensions: ["wsz"] });
    expect(r.settings[1].key).toBe("scale");
    expect(r.settings[1].type).toBe("slider");
    // Off by default. Enabling a plugin must not make melo's window disappear,
    // and someone who wants both windows should not have to find a setting to
    // get the shell back.
    const hide = r.settings!.find((f) => f.key === "hideShell")!;
    expect(hide.type).toBe("toggle");
    expect(hide.default).toBe(false);
    // Likewise: a window that refuses to minimize is a surprise unless asked for.
    const up = r.settings!.find((f) => f.key === "alwaysUp")!;
    expect(up.type).toBe("toggle");
    expect(up.default).toBe(false);
  });
});

// The divergence itself, from both directions. A double that is not a whole
// number reaches the shell as toInt()'s default 0 and fails there with a
// message naming neither the field nor the value, so it has to be refused here.
describe("geometry numbers are whole pixels", () => {
  const w = (over: Record<string, unknown>) =>
    validateUi({ windows: [{ ...win, ...over }] }, dir, 3).error;

  it("rejects a fractional width or height", () => {
    expect(w({ width: 275.5 })).toMatch(/width and height must be positive whole pixels/);
    expect(w({ height: 116.25 })).toMatch(/width and height must be positive whole pixels/);
  });
  it("rejects a size outside the range an int can carry", () => {
    expect(w({ width: 2147483648 })).toMatch(/whole pixels/);
    expect(w({ height: 1e300 })).toMatch(/whole pixels/);
  });
  it("still accepts the sizes a real skin declares", () => {
    expect(w({ width: 275, height: 116 })).toBeNull();
    expect(w({ width: 1, height: 1 })).toBeNull();
  });
  // The one place a fractional number is CORRECT, asserted so that "make the
  // numbers consistent" cannot quietly delete it. A slider's from/to/step go
  // to melo's Settings page as JS numbers and never through toInt().
  it("still accepts a fractional slider range, which is not window geometry", () => {
    const r = validateSettings([
      { key: "gain", type: "slider", label: "Gain", from: 0, to: 1, step: 0.1 }]);
    expect(r.error).toBeNull();
    expect(r.settings[0].step).toBe(0.1);
    expect(r.settings[0].to).toBe(1);
  });
  it("rejects a fractional shade height, step, minimum and snap distance", () => {
    expect(w({ shade: { height: 14.5 } })).toMatch(/shade\.height must be a positive whole/);
    expect(w({ resize: { axes: "v", stepH: 29.5 } })).toMatch(/resize\.stepH must be a positive whole/);
    expect(w({ resize: { axes: "v", minHeight: 116.5 } }))
      .toMatch(/resize\.minHeight must be a positive whole/);
    expect(validateUi({ snap: { distance: 10.5 }, windows: [win] }, dir, 3).error)
      .toMatch(/snap\.distance must be a non-negative whole/);
    // ...and zero is still "no magnetism", not a rejected value.
    expect(validateUi({ snap: { distance: 0 }, windows: [win] }, dir, 3).error)
      .toBeNull();
  });

  describe("fills", () => {
    it("accepts a baked shader inside the plugin dir", () => {
      const r = validateUi({ fills: [{ id: "wave", name: "Wave", shader: qsb, colours: 2, shaped: true }] }, dir, 3);
      expect(r.error).toBeNull();
      expect(r.ui!.fills![0]).toEqual({ id: "wave", name: "Wave", shader: qsb, colours: 2, base: true, palette: true, shaped: true });
    });
    it("is enough on its own", () => {
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: qsb }] }, dir, 3).ui!.fills![0].colours).toBe(1);
    });
    it("wants a .qsb, not a .frag", () => {
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: frag }] }, dir, 3).error).toMatch(/qsb/);
    });
    it("names a missing or escaping shader", () => {
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: "nope.qsb" }] }, dir, 3).error).toMatch(/not found/);
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: "../x.qsb" }] }, dir, 3).error).toMatch(/escapes/);
    });
    it("rejects a bad colour count and a duplicate id", () => {
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: qsb, colours: 4 }] }, dir, 3).error).toMatch(/colours/);
      expect(validateUi({ fills: [{ id: "w", name: "W", shader: qsb }, { id: "w", name: "W2", shader: qsb }] }, dir, 3).error).toMatch(/duplicate/);
    });
  });
});
