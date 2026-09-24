// Spawns the BUILT plugin host bundle against the sample fixture plugin.
import { describe, it, expect, beforeAll, afterEach } from "vitest";
import { spawn, execSync, type ChildProcess } from "child_process";
import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { createInterface } from "readline";

const HOST = resolve(__dirname, "../../dist/melo-plugin-host.mjs");
const FIXTURE = resolve(__dirname, "../../test-fixtures/sample-source");
const BROKEN = resolve(__dirname, "../../test-fixtures/broken-source");
let procs: ChildProcess[] = [];
afterEach(() => { for (const p of procs) p.kill(); procs = []; });
// npm and pnpm read the same package.json build script.
beforeAll(() => { execSync("npm run build", { cwd: resolve(__dirname, "../..") }); }, 120000);

function startHost(dir = FIXTURE, grantsJson?: string) {
  const FX = dir;
  const dataDir = mkdtempSync(join(tmpdir(), "melo-plugdata-"));
  // Node --permission needs a directory-contents form (trailing /*) to grant
  // access to files inside a dir, not just the dir entry itself.
  const dist = resolve(__dirname, "../../dist");
  const argv = ["--permission",
     `--allow-fs-read=${FX}/*`, `--allow-fs-read=${dataDir}/*`, `--allow-fs-read=${dist}/*`,
     `--allow-fs-write=${dataDir}/*`, HOST, FX, dataDir];
  if (grantsJson !== undefined) argv.push(grantsJson);
  const p = spawn(process.execPath, argv,
    { stdio: ["pipe", "pipe", "pipe"] });
  procs.push(p);
  const lines: any[] = [];
  const waiters: ((m: any) => void)[] = [];
  createInterface({ input: p.stdout! }).on("line", (l) => {
    const m = JSON.parse(l);
    const w = waiters.shift();
    if (w) w(m); else lines.push(m);
  });
  const next = () => new Promise<any>((res) => {
    if (lines.length) res(lines.shift()); else waiters.push(res);
  });
  const send = (m: object) => p.stdin!.write(JSON.stringify(m) + "\n");
  return { p, next, send };
}

describe("plugin host", () => {
  it("registers the fixture source and answers search + resolveStream", async () => {
    const h = startHost();
    const reg = await h.next();
    expect(reg.method).toBe("registered");
    expect(reg.params.sources).toEqual([{ id: "sample", name: "Sample Source" }]);
    expect(reg.params.events).toContain("trackChanged");

    h.send({ jsonrpc: "2.0", id: 1, method: "source/search",
             params: { sourceId: "sample", query: "cats" } });
    const r1 = await h.next();
    expect(r1.id).toBe(1);
    expect(r1.result.tracks[0].title).toBe("hit for cats");

    h.send({ jsonrpc: "2.0", id: 2, method: "source/resolveStream",
             params: { sourceId: "sample", trackId: "smp:1" } });
    const r2 = await h.next();
    expect(r2.result.url).toMatch(/smp:1/);
  }, 20000);

  it("delivers player events and forwards melo.log to the parent", async () => {
    const h = startHost();
    await h.next();  // registered
    h.send({ jsonrpc: "2.0", id: 3, method: "event",
             params: { type: "trackChanged", payload: { track: { id: "t1" } } } });
    const msgs = [await h.next(), await h.next()];
    const log = msgs.find((m) => m.method === "log");
    const resp = msgs.find((m) => m.id === 3);
    expect(log.params.msg).toMatch(/saw trackChanged t1/);
    expect(resp.result).toEqual({});
  }, 20000);

  it("reports a load failure as a structured `fatal`, not a bare crash", async () => {
    const h = startHost(BROKEN);
    const m = await h.next();
    expect(m.method).toBe("fatal");
    expect(m.params.error).toMatch(/boom on activate/);
  }, 20000);

  it("withholds net when the manifest declares rawNetwork but the grant is false", async () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-rawnet-"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      id: "rawnet", name: "Raw Net", version: "1.0.0", apiVersion: 3,
      capabilities: ["source"],
      entry: { sidecar: "main.js" },
      permissions: { rawNetwork: true },
    }));
    writeFileSync(join(dir, "main.js"),
      "export default async function activate() { await import('net'); }\n");
    const h = startHost(dir, JSON.stringify({ ui: false, rawNetwork: false, intercept: [] }));
    const m = await h.next();
    expect(m.method).toBe("fatal");
    expect(m.params.error).toMatch(/net is not available/);
  }, 20000);

  // The resolve hook above only sees imports. process.getBuiltinModule() is
  // documented to skip it, so left in place it hands node:http to a plugin
  // that declared no rawNetwork at all.
  it("withholds process.getBuiltinModule without rawNetwork", async () => {
    const dir = mkdtempSync(join(tmpdir(), "melo-gbm-"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      id: "gbm", name: "GBM", version: "1.0.0", apiVersion: 3,
      capabilities: ["source"],
      entry: { sidecar: "main.js" },
      permissions: { network: ["example.com"] },
    }));
    writeFileSync(join(dir, "main.js"),
      "export default async function activate() {\n"
      + "  const http = process.getBuiltinModule('node:http');\n"
      + "  throw new Error('REACHED node:http: ' + typeof http.request);\n"
      + "}\n");
    const h = startHost(dir, JSON.stringify({ ui: false, rawNetwork: false, intercept: [] }));
    const m = await h.next();
    expect(m.method).toBe("fatal");
    expect(m.params.error).not.toMatch(/REACHED/);
    expect(m.params.error).toMatch(/getBuiltinModule is not a function/);
  }, 20000);
});
