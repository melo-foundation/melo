import { describe, it, expect } from "vitest";
import { spawn } from "child_process";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// Integration tests against the built bundle (run `pnpm build` first).
const BUNDLE = join(__dirname, "..", "dist", "melo-sidecar.mjs");

// Every test here spawns a node process and waits on the built bundle. Under
// full-suite parallelism that loses the race against vitest's 5s default about
// one run in three.
const SPAWN_TIMEOUT = 20000;

function talk(lines: object[], timeoutMs = 8000): Promise<any[]> {
  return new Promise((resolve, reject) => {
    const proc = spawn("node", [BUNDLE], { stdio: ["pipe", "pipe", "ignore"] });
    const out: any[] = [];
    let buf = "";
    const timer = setTimeout(() => { proc.kill(); resolve(out); }, timeoutMs);
    proc.stdout.on("data", (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) out.push(JSON.parse(line));
      }
      if (out.length >= lines.filter((l: any) => l.id !== undefined).length) {
        clearTimeout(timer);
        proc.kill();
        resolve(out);
      }
    });
    proc.on("error", reject);
    for (const l of lines) proc.stdin.write(JSON.stringify(l) + "\n");
  });
}

const initMsg = () => ({
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: {
    dataDir: mkdtempSync(join(tmpdir(), "melo-test-")),
    musicDir: tmpdir(),
    ytdlpPath: "/nonexistent/yt-dlp",
    osPrefersDark: true,
    appVersion: "test",
  },
});

describe("sidecar rpc", () => {
  it("responds to initialize with version and capabilities", async () => {
    const out = await talk([initMsg()]);
    expect(out[0].id).toBe(1);
    expect(out[0].result.sidecarVersion).toBeTruthy();
    expect(out[0].result.ytdlpAvailable).toBe(false);   // nonexistent path, no seed
  }, SPAWN_TIMEOUT);

  it("answers a registered method and rejects unknown ones", async () => {
    const out = await talk([
      initMsg(),
      { jsonrpc: "2.0", id: 2, method: "settings/get" },
      { jsonrpc: "2.0", id: 3, method: "no/such-method" },
    ]);
    const byId = Object.fromEntries(out.map((m) => [m.id, m]));
    expect(typeof byId[2].result).toBe("object");
    expect(byId[3].error.code).toBe(-32601);
  }, SPAWN_TIMEOUT);

  it("survives garbage input and keeps protocol stdout clean", async () => {
    const proc = spawn("node", [BUNDLE], { stdio: ["pipe", "pipe", "ignore"] });
    proc.stdin.write("this is not json\n");
    proc.stdin.write(JSON.stringify(initMsg()) + "\n");
    const out: any[] = await new Promise((resolve) => {
      const msgs: any[] = [];
      let buf = "";
      proc.stdout.on("data", (d) => {
        buf += d.toString();
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (line.trim()) msgs.push(JSON.parse(line));   // throws on stdout pollution
          if (msgs.length >= 2) { proc.kill(); resolve(msgs); }
        }
      });
      setTimeout(() => { proc.kill(); resolve(msgs); }, 8000);
    });
    expect(out.some((m) => m.error?.code === -32700)).toBe(true);   // parse error reported
    expect(out.some((m) => m.id === 1 && m.result)).toBe(true);     // still initialized after
  }, SPAWN_TIMEOUT);

  it("settings roundtrip persists a patch", async () => {
    const init = initMsg();
    const out = await talk([
      init,
      { jsonrpc: "2.0", id: 2, method: "settings/set", params: { patch: { crossfadeSeconds: 4, ui: { theme: "test" } } } },
      { jsonrpc: "2.0", id: 3, method: "settings/get" },
    ]);
    const byId = Object.fromEntries(out.map((m) => [m.id, m]));
    expect(byId[3].result.crossfadeSeconds).toBe(4);
    expect(byId[3].result.ui.theme).toBe("test");
  }, SPAWN_TIMEOUT);

  it("settings/set removes the ui keys it names", async () => {
    const init = initMsg();
    const out = await talk([
      init,
      { jsonrpc: "2.0", id: 2, method: "settings/set", params: { patch: { ui: { theme: "test", buttonGap: 7 } } } },
      { jsonrpc: "2.0", id: 3, method: "settings/set", params: { patch: {}, removeUi: ["buttonGap"] } },
      { jsonrpc: "2.0", id: 4, method: "settings/get" },
    ]);
    const byId = Object.fromEntries(out.map((m) => [m.id, m]));
    expect(byId[4].result.ui.theme).toBe("test");
    expect("buttonGap" in byId[4].result.ui).toBe(false);
  }, SPAWN_TIMEOUT);
});
