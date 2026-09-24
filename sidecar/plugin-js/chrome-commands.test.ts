import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { join } from "path";
import { loadQmlJsFrom, repoRoot } from "./harness";

// Every chrome button is a command. A button that acts inline is a button no
// plugin can take over and no user can bind a key to: `InterceptMap.offer()`
// sits in the command switch, so an action that never reaches the switch is
// invisible to the intercept catalog.
const qmlDir = join(repoRoot, "src", "qml");
const main = readFileSync(join(qmlDir, "Main.qml"), "utf8");
const { globals } = loadQmlJsFrom(join(qmlDir, "components"), "shortcuts.js");
const SC = globals as {
  DEFAULTS: Record<string, string>;
  ORDER: string[];
  LABELS: Record<string, string>;
};

// signal handler -> the command it must invoke
const WIRING: Record<string, string> = {
  onQueueToggle: "toggleQueue",
  onEqToggle: "toggleEq",
  onVisToggle: "toggleVisualizer",
  onSearchToggle: "toggleSearch",
  onSettingsToggle: "openSettings",
  onPinToggle: "togglePin",
};

describe("melo's chrome buttons", () => {
  for (const [handler, command] of Object.entries(WIRING)) {
    it(`${handler} invokes ${command} and does nothing itself`, () => {
      const re = new RegExp(`${handler}\\s*:([^\\n]*)`, "g");
      const bodies = [...main.matchAll(re)].map((m) => m[1]);
      expect(bodies.length, `${handler} is not in Main.qml`).toBeGreaterThan(0);
      for (const body of bodies)
        expect(body, handler).toContain(`CommandMap.invoke("${command}")`);
    });
  }

  // The switch is where an intercept can be offered, so the case has to exist
  // there even for an action only one bar raises.
  for (const command of Object.values(WIRING)) {
    it(`the command switch handles ${command}`, () => {
      expect(main).toContain(`case "${command}":`);
    });
  }
});

// Every chrome action offers before it acts: the command switch is where a
// plugin gets asked, and an action that acts without asking cannot be taken
// over however it is declared.
describe("the chrome commands are interceptable", () => {
  for (const command of Object.values(WIRING)) {
    it(`${command} offers before melo acts`, () => {
      const at = main.indexOf(`case "${command}":`);
      expect(at, `${command} has no case`).toBeGreaterThan(0);
      const body = main.slice(at, main.indexOf("break", at));
      expect(body, command).toContain(`InterceptMap.offer("${command}")`);
    });
  }
});

describe("the shortcut tables", () => {
  const added = ["toggleQueue", "toggleEq", "toggleVisualizer", "openSettings", "togglePin"];

  it("lists the new commands so they can be bound", () => {
    for (const id of added) {
      expect(SC.ORDER, id).toContain(id);
      expect(SC.LABELS[id], id).toBeTruthy();
    }
  });

  // An empty default is intended, as for toggleCompact and toggleMaximize:
  // inventing a shortcut takes a key away from the user.
  it("gives them no default key", () => {
    for (const id of added) expect(SC.DEFAULTS[id], id).toBe("");
  });

  it("does not add a second id for search, which is already a command", () => {
    expect(SC.ORDER.filter((id) => id === "toggleSearch")).toHaveLength(1);
    expect(SC.DEFAULTS.toggleSearch).toBe("ctrl+KeyF");
  });
});
