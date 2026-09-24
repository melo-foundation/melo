import { describe, it, expect, vi } from "vitest";

// The defect: check-then-act on a shared timestamp let two overlapping callers
// see the same "now", wait the same amount, and fire together — which is what
// gets a client blocked by MusicBrainz.
describe("rate limiter", () => {
  it("serialises overlapping callers instead of letting them race", async () => {
    vi.resetModules();
    const at: number[] = [];
    vi.stubGlobal("fetch", async () => { at.push(Date.now()); return new Response("{}"); });
    const { __rateLimitedFetchForTest: rl } = await import("./metadata");
    const t0 = Date.now();
    await Promise.all([rl("https://x/1", 60), rl("https://x/2", 60), rl("https://x/3", 60)]);
    expect(at.length).toBe(3);
    at.sort((a, b) => a - b);
    // each one waits its own interval rather than sharing one
    expect(at[1] - at[0]).toBeGreaterThanOrEqual(45);
    expect(at[2] - at[1]).toBeGreaterThanOrEqual(45);
    expect(at[2] - t0).toBeGreaterThanOrEqual(150);
    vi.unstubAllGlobals();
  });
});
