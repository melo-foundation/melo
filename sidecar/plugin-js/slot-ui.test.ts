import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { join } from "path";
import { repoRoot } from "./harness";
import { SLOT_IDS } from "../src/plugins/ui-manifest";

// The `visualizer` slot. melo's visualiser is an item in melo's window and also
// its default backdrop, so an intercept plus a plugin window cannot replace it:
// hijacking the button and opening a window adds a second visualiser beside
// melo's. The rest of the catalog stays unbound until something wants it.
const main = readFileSync(join(repoRoot, "src", "qml", "Main.qml"), "utf8");

describe("the visualizer slot", () => {
  it("is a place the shell can find by name", () => {
    expect(main).toContain('objectName: "meloSlot:visualizer"');
  });

  // The occupant is created in the PLUGIN's engine and reparented in, so it
  // cannot carry an anchors binding across the seam — the gate sets geometry.
  it("sizes whatever the shell parents into it", () => {
    const at = main.indexOf('objectName: "meloSlot:visualizer"');
    const gate = main.slice(at, at + 1600);
    expect(gate).toContain("function fit()");
    expect(gate).toContain("onWidthChanged: fit()");
    expect(gate).toContain("onHeightChanged: fit()");
    expect(gate).toContain("onChildrenChanged: fit()");
  });

  // A bound slot replaces melo's item. Two visualisers drawing the same
  // audio into the same rectangle is the failure a slot exists to avoid.
  it("hides melo's own visualiser while a plugin fills it", () => {
    expect(main).toMatch(/vizSlotFilled:\s*[\s\S]{0,120}SlotMap\.qmlFor\("visualizer"\)/);
    const viz = main.slice(main.indexOf("sourceComponent: Visualizer"));
    expect(viz.slice(0, 900)).toContain("!root.vizSlotFilled");
  });

  // `generation` is what makes it a binding — qmlFor() is a method, and a
  // binding that only called it would have nothing to re-evaluate on.
  it("re-evaluates when the binding changes", () => {
    expect(main).toMatch(/vizSlotFilled:\s*[\s\S]{0,60}SlotMap\.generation/);
  });

  it("names a slot the catalog actually has", () => {
    expect(SLOT_IDS).toContain("visualizer");
  });

  // The gate is the whole view area and sits under the tabs, so an occupant
  // with no visibility rule would repaint the background of every view:
  // library, search, home.
  it("only draws where melo's own visualiser draws", () => {
    const at = main.indexOf('objectName: "meloSlot:visualizer"');
    const gate = main.slice(at, at + 1200);
    expect(gate).toMatch(/visible:[\s\S]{0,120}PlayerState\.view === 4/);
    expect(gate).toMatch(/visible:[\s\S]{0,120}!root\.miniPlayer/);
  });
});

// The `queuePanel` slot. A backdrop fills whatever rectangle it is given; a
// panel has a width of its own (melo's is 320), so the occupant is asked, and
// melo's content area gives way to what it says.
describe("the queuePanel slot", () => {
  it("is a place the shell can find by name", () => {
    expect(main).toContain('objectName: "meloSlot:queuePanel"');
    expect(SLOT_IDS).toContain("queuePanel");
  });

  it("takes its width from the occupant, falling back to melo's own", () => {
    const at = main.indexOf('objectName: "meloSlot:queuePanel"');
    const gate = main.slice(at, at + 1100);
    expect(gate).toMatch(/kid\.implicitWidth > 0/);
    expect(gate).toContain("queuePanel.width");
  });

  // The gate's width COMES FROM the child, so fit() must not write it back.
  it("does not write width back to the occupant", () => {
    const at = main.indexOf('objectName: "meloSlot:queuePanel"');
    const fit = main.slice(main.indexOf("function fit()", at), at + 1400);
    expect(fit).toContain("children[i].height = height");
    expect(fit).not.toContain("children[i].width");
  });

  // Height is melo's either way: the strip runs top to bottom because the
  // layout around it expects that, and a panel choosing its own height would be
  // a floating window, which is a different surface.
  it("keeps the strip melo's height", () => {
    const at = main.indexOf('objectName: "meloSlot:queuePanel"');
    const gate = main.slice(at, at + 1100);
    expect(gate).toContain("anchors.top: parent.top");
    expect(gate).toContain("anchors.bottom: parent.bottom");
  });

  it("hides melo's own queue while a plugin fills it", () => {
    const at = main.indexOf("id: queuePanel");
    expect(main.slice(at, at + 400)).toContain("!root.queueSlotFilled");
    expect(main).toMatch(/queueSlotFilled:\s*[\s\S]{0,120}SlotMap\.qmlFor\("queuePanel"\)/);
  });
});
