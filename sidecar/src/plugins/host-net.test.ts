// The plugin host's network rules, against the BUILT host bundle and a local server.
import { describe, it, expect, beforeAll, afterAll, afterEach } from "vitest";
import { spawn, execSync, type ChildProcess } from "child_process";
import { mkdtempSync, writeFileSync } from "fs";
import { createServer, type Server } from "http";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { createInterface } from "readline";
import { fsAllowGlob } from "./permissions";

const HOST = resolve(__dirname, "../../dist/melo-plugin-host.mjs");
let procs: ChildProcess[] = [];
let server: Server, port = 0;
const hits: string[] = [];
beforeAll(async () => {
  execSync("npm run build", { cwd: resolve(__dirname, "../..") });
  server = createServer((q, r) => {
    hits.push(`${q.headers.host?.split(":")[0]}${q.url}`);
    const m = /^\/redirect\?to=(.*)$/.exec(q.url ?? "");
    if (m) { r.writeHead(302, { location: decodeURIComponent(m[1]) }); r.end(); return; }
    if (q.url === "/loop") { r.writeHead(302, { location: "/loop" }); r.end(); return; }
    r.end("ok");
  });
  await new Promise<void>((res) => server.listen(0, "127.0.0.1", res));
  port = (server.address() as any).port;
}, 120000);
afterAll(() => server.close());
afterEach(() => { for (const p of procs) p.kill(); procs = []; hits.length = 0; });

// A plugin whose activate() runs `body` (an async function body returning a
// value) and reports the result through a `fatal` line.
async function probe(body: string, network: string[] = ["127.0.0.1"],
                     grants = { ui: false, rawNetwork: false, intercept: [] as string[] }): Promise<any> {
  const dir = mkdtempSync(join(tmpdir(), "melo-hnet-"));
  const dataDir = mkdtempSync(join(tmpdir(), "melo-hnetdata-"));
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    id: "hnet", name: "hnet", version: "1.0.0", apiVersion: 3,
    capabilities: ["source"], entry: { sidecar: "main.js" },
    permissions: { network, ...(grants.rawNetwork ? { rawNetwork: true } : {}) },
  }));
  writeFileSync(join(dir, "main.js"),
    `const PORT = ${port};\n`
    + "const run = async () => {\n" + body + "\n};\n"
    + "export default async function activate() {\n"
    + "  let out; try { out = { ok: await run() }; } catch (e) { out = { error: String(e?.message ?? e) }; }\n"
    + "  throw new Error('REPORT ' + JSON.stringify(out));\n"
    + "}\n");
  const dist = resolve(__dirname, "../../dist");
  const p = spawn(process.execPath, ["--permission",
    `--allow-fs-read=${fsAllowGlob(dir)}`, `--allow-fs-read=${fsAllowGlob(dataDir)}`,
    `--allow-fs-read=${fsAllowGlob(dist)}`, `--allow-fs-write=${fsAllowGlob(dataDir)}`,
    HOST, dir, dataDir, JSON.stringify(grants)], { stdio: ["pipe", "pipe", "pipe"] });
  procs.push(p);
  p.stdin!.write(JSON.stringify({ jsonrpc: "2.0", method: "settings", params: { values: {} } }) + "\n");
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error("no report")), 15000);
    createInterface({ input: p.stdout! }).on("line", (l) => {
      const m = JSON.parse(l);
      if (m.method !== "fatal") return;
      clearTimeout(t);
      res(JSON.parse(/REPORT (\{.*\})/.exec(m.params.error)![1]));
    });
  });
}

describe("plugin fetch", () => {
  it("fetches an allowed host", async () => {
    expect(await probe("return (await fetch(`http://127.0.0.1:${PORT}/a`)).text();")).toEqual({ ok: "ok" });
    expect(hits).toEqual(["127.0.0.1/a"]);
  }, 20000);

  it("fetches the URL it checked, not another string form of the input", async () => {
    const r = await probe(
      "const input = { url: `http://127.0.0.1:${PORT}/checked`, toString() { return `http://localhost:${PORT}/fetched`; } };\n"
      + "return (await fetch(input)).text();");
    expect(r.error).toMatch(/localhost is not in this plugin's manifest network allowlist/);
    expect(hits).toEqual([]);
  }, 20000);

  it("fetches the URL it checked when given a URL subclass", async () => {
    const r = await probe(
      "class U extends URL { toString() { return `http://localhost:${PORT}/fetched`; } }\n"
      + "return (await fetch(new U(`http://127.0.0.1:${PORT}/checked`))).text();");
    expect(r.error).toMatch(/localhost is not in this plugin's manifest network allowlist/);
    expect(hits).toEqual([]);
  }, 20000);

  it("checks with the host's Request even when the plugin replaces the global", async () => {
    const r = await probe(
      "const R = Request;\n"
      + "globalThis.Request = class extends R { get url() { return `http://127.0.0.1:${PORT}/checked`; } };\n"
      + "return (await fetch(`http://localhost:${PORT}/fetched`)).text();");
    expect(r.error).toMatch(/localhost is not in this plugin's manifest network allowlist/);
    expect(hits).toEqual([]);
  }, 20000);

  it("refuses a scheme other than http and https", async () => {
    const r = await probe("return (await fetch('data:text/plain,hi')).text();");
    expect(r.error).toMatch(/data: URLs are not available/);
  }, 20000);
});

describe("plugin fetch redirects", () => {
  const to = (u: string) => "`http://127.0.0.1:${PORT}/redirect?to=` + encodeURIComponent(" + u + ")";

  it("refuses a redirect to a host the manifest does not list", async () => {
    const r = await probe("return (await fetch(" + to("`http://localhost:${PORT}/evil`") + ")).text();");
    expect(r.error).toMatch(/localhost is not in this plugin's manifest network allowlist/);
    expect(hits).toEqual([`127.0.0.1/redirect?to=${encodeURIComponent(`http://localhost:${port}/evil`)}`]);
  }, 20000);

  it("follows a redirect to an allowed host", async () => {
    expect(await probe("return (await fetch(" + to("'/b'") + ")).text();")).toEqual({ ok: "ok" });
    expect(hits[1]).toBe("127.0.0.1/b");
  }, 20000);

  it("hands back the redirect itself when the plugin asks for manual", async () => {
    const r = await probe("const res = await fetch(" + to("`http://localhost:${PORT}/evil`")
      + ", { redirect: 'manual' }); return res.status;");
    expect(r).toEqual({ ok: 302 });
    expect(hits).toHaveLength(1);
  }, 20000);

  it("rejects a redirect when the plugin asks for error", async () => {
    const r = await probe("return (await fetch(" + to("'/b'") + ", { redirect: 'error' })).text();");
    expect(r.error).toMatch(/redirects/);
    expect(hits).toHaveLength(1);
  }, 20000);

  it("stops after 20 redirects", async () => {
    const r = await probe("return (await fetch(`http://127.0.0.1:${PORT}/loop`)).text();");
    expect(r.error).toMatch(/too many redirects/);
    expect(hits).toHaveLength(21);
  }, 20000);

  it("turns a POST into a GET on a 302", async () => {
    const r = await probe("return (await fetch(" + to("'/b'") + ", { method: 'POST', body: 'x' })).text();");
    expect(r).toEqual({ ok: "ok" });
    expect(hits[1]).toBe("127.0.0.1/b");
  }, 20000);
});

describe("plugin builtins", () => {
  const tryImport = (m: string) =>
    `try { await import(${JSON.stringify(m)}); return 'loaded'; } catch (e) { return String(e.message); }`;

  it.each(["_http_client", "_http_agent", "_tls_wrap", "node:dns", "dns/promises", "child_process",
           "node:module", "vm", "v8", "inspector", "worker_threads", "node:cluster", "repl", "wasi"])
    ("refuses %s", async (m) => {
      const r = await probe(tryImport(m));
      expect(r.ok).toMatch(/is not available to this plugin/);
    }, 20000);

  it.each(["node:fs", "path", "node:crypto", "events", "zlib", "os", "stream/promises", "util"])
    ("allows %s", async (m) => {
      expect(await probe(tryImport(m))).toEqual({ ok: "loaded" });
    }, 20000);

  it("refuses _http_client through process.getBuiltinModule", async () => {
    const r = await probe("return typeof process.getBuiltinModule('_http_client').ClientRequest;");
    expect(r.error).toMatch(/_http_client is not available to this plugin/);
  }, 20000);

  it("lets a rawNetwork plugin load net and dns, but still not child_process", async () => {
    const grants = { ui: false, rawNetwork: true, intercept: [] };
    expect(await probe(tryImport("net"), [], grants)).toEqual({ ok: "loaded" });
    expect(await probe(tryImport("dns"), [], grants)).toEqual({ ok: "loaded" });
    expect((await probe(tryImport("child_process"), [], grants)).ok).toMatch(/not available/);
  }, 30000);

  it("refuses os.setPriority", async () => {
    const r = await probe("const os = await import('os'); os.setPriority(1, 19); return 'set';");
    expect(r.error).toMatch(/setPriority is not available/);
  }, 20000);
});

describe("plugin process signals", () => {
  it("refuses to signal another process", async () => {
    const r = await probe("return process.kill(process.ppid, 0);");
    expect(r.error).toMatch(/may signal only its own process/);
  }, 20000);
});
