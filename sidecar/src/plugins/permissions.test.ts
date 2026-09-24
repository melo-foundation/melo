import { describe, it, expect } from "vitest";
import {
  INTERCEPT_ACTIONS, EMPTY_GRANTS, validatePermissions, permissionWarnings,
} from "./permissions";

describe("validatePermissions", () => {
  it("rebuilds a field-by-field object and drops storage", () => {
    const { permissions, error } = validatePermissions({
      network: ["api.example.com"], storage: true, rawNetwork: true,
      intercept: ["play"], extra: 1,
    });
    expect(error).toBeNull();
    expect(permissions).toEqual({
      network: ["api.example.com"], rawNetwork: true, intercept: ["play"],
    });
    expect((permissions as any).storage).toBeUndefined();
  });
  it("rejects a non-catalog intercept action", () => {
    const { error } = validatePermissions({ intercept: ["play", "queue.add"] });
    expect(error).toMatch(/intercept/);
    expect(error).toMatch(/queue\.add/);
  });
  it("rejects a duplicate intercept action", () => {
    expect(validatePermissions({ intercept: ["play", "play"] }).error).toMatch(/duplicate/);
  });
  it("rejects a non-array intercept", () => {
    expect(validatePermissions({ intercept: "play" }).error).toMatch(/intercept/);
  });
  it("accepts an empty object", () => {
    expect(validatePermissions({}).permissions).toEqual({});
  });
});

describe("permissionWarnings", () => {
  it("names ui as in-process, not as the mini player", () => {
    const w = permissionWarnings({ capabilities: ["ui"], permissions: {} });
    expect(w.join(" ")).toMatch(/inside melo/i);
    expect(w.join(" ")).not.toMatch(/mini/i);
  });
  it("does not warn ui when the capability is absent", () => {
    const w = permissionWarnings({ capabilities: ["source"], permissions: {} });
    expect(w.join(" ")).not.toMatch(/inside melo/i);
  });
  it("names each intercept action on its own line", () => {
    const w = permissionWarnings({
      capabilities: ["ui"],
      permissions: { intercept: ["play", "toggleCompact"] },
    });
    expect(w.some((s) => /play/i.test(s) && /instead of melo/i.test(s))).toBe(true);
    expect(w.some((s) => /toggleCompact/i.test(s))).toBe(true);
    expect(w.join(" ")).not.toMatch(/hijack things/i);
  });
  it("warns rawNetwork only when declared", () => {
    expect(permissionWarnings({ capabilities: [], permissions: {} }).join(" "))
      .not.toMatch(/rawNetwork/);
    expect(permissionWarnings({ capabilities: [], permissions: { rawNetwork: true } }).join(" "))
      .toMatch(/not limited to the sites/i);
  });
  it("never warns about storage", () => {
    const w = permissionWarnings({
      capabilities: ["source"],
      permissions: { network: ["x.com"] } as any,
    });
    expect(w.join(" ")).not.toMatch(/storage/i);
  });
});

describe("catalog", () => {
  // The twin of kActions in src/plugins/InterceptMap.cpp. A change here that
  // is not made there is a manifest the sidecar accepts and the shell ignores.
  it("is the spec's v3 intercept list, plus melo's chrome actions", () => {
    expect([...INTERCEPT_ACTIONS]).toEqual(
      ["play", "pause", "stop", "next", "prev", "toggleCompact",
       "toggleQueue", "toggleEq", "toggleVisualizer", "toggleSearch",
       "openSettings", "togglePin"]);
  });
  it("empty grants grant nothing", () => {
    expect(EMPTY_GRANTS).toEqual({ ui: false, rawNetwork: false, intercept: [] });
  });
});
