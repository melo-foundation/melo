import { describe, it, expect, beforeAll, afterAll, afterEach } from "vitest";
import { request, createServer, type Server } from "http";
import { execSync } from "child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { PluginProxy, isPrivateAddress } from "./net-proxy";
import { initPlugins, listPlugins, _resetForTests } from "./manager";

let server: Server, port = 0;
const hits: string[] = [];
beforeAll(async () => {
  execSync("npm run build", { cwd: resolve(__dirname, "../..") });
  server = createServer((q, r) => { hits.push(q.url ?? ""); r.end("ok"); });
  await new Promise<void>((res) => server.listen(0, "127.0.0.1", res));
  port = (server.address() as any).port;
}, 120000);
afterAll(() => server.close());
afterEach(() => { hits.length = 0; });

describe("isPrivateAddress", () => {
  it.each(["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1",
           "0.0.0.0", "224.0.0.1", "::1", "::", "fe80::1", "fd00::1", "::ffff:127.0.0.1",
           "::ffff:7f00:1", "64:ff9b::10.0.0.1", "not an ip"])
    ("%s is private", (ip) => expect(isPrivateAddress(ip)).toBe(true));
  it.each(["93.184.216.34", "8.8.8.8", "172.32.0.1", "2606:4700::6810:84e5", "::ffff:8.8.8.8"])
    ("%s is public", (ip) => expect(isPrivateAddress(ip)).toBe(false));
});

function connectVia(p: PluginProxy, target: string, token?: string): Promise<{ status: number; body: string }> {
  return new Promise((res, rej) => {
    const headers: Record<string, string> = {};
    if (token) headers["proxy-authorization"] = "Basic " + Buffer.from(`melo:${token}`).toString("base64");
    const req = request({ host: "127.0.0.1", port: p.port, method: "CONNECT", path: target, headers });
    req.on("connect", (resp, sock) => {
      if (resp.statusCode !== 200) { sock.destroy(); return res({ status: resp.statusCode!, body: "" }); }
      let body = "";
      sock.on("data", (d) => { body += d; });
      sock.on("end", () => res({ status: 200, body }));
      sock.write(`GET /through HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
    });
    req.on("error", rej);
    req.end();
  });
}

describe("the plugin network proxy", () => {
  let proxy: PluginProxy;
  const refused: string[] = [];
  beforeAll(async () => {
    proxy = new PluginProxy(async (host) => (host === "rebind.example" ? ["127.0.0.1"] : ["93.184.216.34"]));
    await proxy.ready;
  });
  afterAll(() => proxy.close());

  it("refuses a tunnel without the plugin's token", async () => {
    expect((await connectVia(proxy, `127.0.0.1:${port}`)).status).toBe(407);
    expect((await connectVia(proxy, `127.0.0.1:${port}`, "wrong")).status).toBe(407);
  });

  it("refuses a host the manifest does not list", async () => {
    const { token } = proxy.add({ network: ["api.example.com"], onRefuse: (t, why) => refused.push(`${t} ${why}`) });
    expect((await connectVia(proxy, `localhost:${port}`, token)).status).toBe(403);
    expect(refused.pop()).toMatch(/localhost:\d+ not in the manifest network allowlist/);
  });

  it("refuses a listed host that resolves to a local address", async () => {
    const { token } = proxy.add({ network: ["*.example"], onRefuse: (t, why) => refused.push(`${t} ${why}`) });
    expect((await connectVia(proxy, `rebind.example:${port}`, token)).status).toBe(403);
    expect(refused.pop()).toMatch(/local or private address/);
    expect(hits).toEqual([]);
  });

  it("tunnels to a local address the manifest names exactly", async () => {
    const { token } = proxy.add({ network: ["127.0.0.1"] });
    const r = await connectVia(proxy, `127.0.0.1:${port}`, token);
    expect(r.status).toBe(200);
    expect(r.body).toMatch(/ok$/);
    expect(hits).toEqual(["/through"]);
  });

  it("stops serving a route once it is removed", async () => {
    const { token } = proxy.add({ network: ["127.0.0.1"] });
    proxy.remove(token);
    expect((await connectVia(proxy, `127.0.0.1:${port}`, token)).status).toBe(407);
  });
});

// A plugin that skips the fetch wrapper and drives Node's own HTTP dispatcher
// still reaches the network only through the proxy.
describe("a plugin process", () => {
  let root: string;
  afterEach(async () => { await _resetForTests(); rmSync(root, { recursive: true, force: true }); });

  it("cannot reach an unlisted host through Node's dispatcher", async () => {
    root = mkdtempSync(join(tmpdir(), "melo-proxy-"));
    const dir = join(root, "plugins", "sneak");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      id: "sneak", name: "sneak", version: "1.0.0", apiVersion: 3,
      capabilities: ["source"], entry: { sidecar: "main.js" },
      permissions: { network: ["127.0.0.1"] },
    }));
    writeFileSync(join(dir, "main.js"),
      "export default async function activate() {\n"
      + "  await fetch('http://127.0.0.1:" + port + "/warm').then((r) => r.text());\n"
      + "  const d = globalThis[Symbol.for('undici.globalDispatcher.1')];\n"
      + "  let out;\n"
      + "  try { const r = await d.request({ origin: 'http://localhost:" + port + "', path: '/evil', method: 'GET' });\n"
      + "        out = 'reached ' + r.statusCode; }\n"
      + "  catch (e) { out = 'refused ' + (e.code ?? e.message); }\n"
      + "  throw new Error('REPORT ' + out);\n"
      + "}\n");
    initPlugins({ pluginsDir: join(root, "plugins"), pluginDataRoot: join(root, "plugin-data"),
                  hostPath: resolve(__dirname, "../../dist/melo-plugin-host.mjs"),
                  enabled: { sneak: true }, grants: {}, onChanged: () => {} });
    const t0 = Date.now();
    while (listPlugins()[0].state !== "error" && Date.now() - t0 < 10000) await new Promise((r) => setTimeout(r, 50));
    expect(listPlugins()[0].error).toMatch(/^REPORT refused/);
    expect(hits).toEqual(["/warm"]);
  }, 20000);
});
