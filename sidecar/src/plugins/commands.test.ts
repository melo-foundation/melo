import { describe, it, expect } from "vitest";
import { validateCommands, commandLoadWarnings, GESTURE_IDS } from "./commands";

describe("validateCommands", () => {
  it("empty / omitted is no commands", () => {
    expect(validateCommands(undefined).commands).toEqual([]);
    expect(validateCommands(undefined).error).toBeNull();
  });
  it("accepts Winamp's five", () => {
    const raw = [
      { id: "toggleGroup", label: "Show / hide Winamp", default: "" },
      { id: "toggleMain", label: "Winamp: main window", default: "" },
      { id: "toggleEq", label: "Winamp: equaliser", default: "" },
      { id: "togglePlaylist", label: "Winamp: playlist", default: "" },
      { id: "toggleShade", label: "Winamp: shade", default: "" },
    ];
    const r = validateCommands(raw);
    expect(r.error).toBeNull();
    expect(r.commands).toHaveLength(5);
  });
  it("rejects unknown gesture default", () => {
    const r = validateCommands([
      { id: "x", label: "X", default: "playerBar.wheel" },
    ]);
    expect(r.error).toMatch(/unknown gesture/);
  });
  it("accepts a catalog gesture as an offer", () => {
    const r = validateCommands([
      { id: "toggleGroup", label: "G", default: "playerBar.doubleClick" },
    ]);
    expect(r.error).toBeNull();
    expect(r.commands[0].default).toBe("playerBar.doubleClick");
  });
  it("commandLoadWarnings: Space loses, gesture offer does not", () => {
    const taken = new Set(["Space"]);
    const w = commandLoadWarnings("winamp", [
      { id: "toggleGroup", label: "G", default: "Space" },
      { id: "toggleMain", label: "M", default: "playerBar.doubleClick" },
    ], taken);
    expect(w.join(" ")).toMatch(/toggleGroup/);
    expect(w.join(" ")).not.toMatch(/toggleMain/);
  });
  it("exports the exact gesture catalog", () => {
    expect(GESTURE_IDS).toEqual([
      "playerBar.doubleClick",
      "compact.escape",
      "titleBar.doubleClick",
    ]);
  });
  it("rejects duplicate command ids", () => {
    const r = validateCommands([
      { id: "toggleGroup", label: "First" },
      { id: "toggleGroup", label: "Second" },
    ]);
    expect(r.error).toMatch(/duplicate.*toggleGroup/i);
  });
});
