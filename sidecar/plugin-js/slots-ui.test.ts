import { describe, expect, it } from "vitest";
import { readFileSync } from "fs";
import { join } from "path";
import { loadQmlJsFrom, repoRoot } from "./harness";

// The Appearance page's slot rows, read out of the file the shell ships. A slot
// is a place in melo a plugin has offered to draw; its row shows the name, what
// draws it now, and the alternatives.
const components = join(repoRoot, "src", "qml", "components");
const { globals } = loadQmlJsFrom(components, "slots.js");
const Slots = globals as {
  rows: (e: unknown[], n: Record<string, string>, h: string) => any[];
  label: (id: string) => string;
};
const HIDDEN = "melo:hidden";

describe("slot rows", () => {
  it("skips a slot nothing offers and nothing holds", () => {
    const r = Slots.rows([{ id: "eq", bound: "", offers: [] }], {}, HIDDEN);
    expect(r).toHaveLength(0);
  });

  it("offers melo first and hidden last, with the plugins between", () => {
    const r = Slots.rows([{ id: "eq", bound: "", offers: ["winamp", "other"] }],
                         { winamp: "Winamp", other: "Other" }, HIDDEN);
    expect(r).toHaveLength(1);
    expect(r[0].label).toBe("Equaliser");
    expect(r[0].bound).toBe("");
    expect(r[0].options.map((o: any) => o.value))
      .toEqual(["", "winamp", "other", HIDDEN]);
    expect(r[0].options[0].label).toBe("melo");
    expect(r[0].options[1].label).toBe("Winamp");
  });

  // A disabled plugin keeps its slot (SlotMap.h). The row has to be able to say
  // so, or the select holds a value absent from its own options and reads empty
  // — the user sees "melo" while melo is not what is bound.
  it("keeps a bind whose plugin is no longer offering, and marks it", () => {
    const r = Slots.rows([{ id: "eq", bound: "winamp", offers: [] }],
                         { winamp: "Winamp" }, HIDDEN);
    expect(r).toHaveLength(1);
    expect(r[0].bound).toBe("winamp");
    const opt = r[0].options.find((o: any) => o.value === "winamp");
    expect(opt.label).toMatch(/unavailable/);
  });

  it("does not invent an option for hidden", () => {
    const r = Slots.rows([{ id: "eq", bound: HIDDEN, offers: ["winamp"] }],
                         { winamp: "Winamp" }, HIDDEN);
    expect(r[0].bound).toBe(HIDDEN);
    expect(r[0].options.filter((o: any) => o.value === HIDDEN)).toHaveLength(1);
  });

  // An id the C++ catalog has and this file does not is visible and obviously
  // unfinished, rather than a row that silently disappears.
  it("falls through to the id when there is no label", () => {
    expect(Slots.label("somethingNew")).toBe("somethingNew");
    expect(Slots.label("queuePanel")).toBe("Queue panel");
  });
});

describe("the Appearance page", () => {
  const source = readFileSync(join(components, "SettingsWindow.qml"), "utf8");
  const appearance = (() => {
    const a = source.indexOf("// ============ APPEARANCE ============");
    const b = source.indexOf("// ============ SHORTCUTS ============", a);
    expect(a, "no APPEARANCE section").toBeGreaterThanOrEqual(0);
    expect(b, "no SHORTCUTS section after it").toBeGreaterThan(a);
    return source.slice(a, b);
  })();

  it("binds slots here, and derives the rows from slots.js", () => {
    expect(appearance).toMatch(/slotRows/);
    expect(source).toMatch(/import "slots\.js"/);
  });

  // UI text is not documentation: a row is a label, a value and its options.
  // The other rows on this page carry a `desc`; a slot's options already say
  // what the slot is, so a sentence there would only restate them.
  it("puts no prose under a slot row", () => {
    const rows = appearance.slice(appearance.indexOf("slotRows"));
    const block = rows.slice(0, rows.indexOf("}\n"));
    expect(block).not.toMatch(/desc:/);
  });
});
