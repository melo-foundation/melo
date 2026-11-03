// melo plugin host: runs one third-party plugin in an isolated Node child
// process. The sidecar launches it with Node's --permission flags, so the
// plugin's filesystem reach is its own folder + data dir, with no child
// processes or native addons. On top of that:
//   1. network reaches the plugin only through an allowlisted fetch (the
//      manifest's `network` domains); socket modules are withheld unless the
//      user grants `rawNetwork` (declaring it is not enough).
//   2. everything the plugin does reaches melo only through the `melo` API
//      object below.
// stdout carries JSON-RPC to the sidecar; plugin logging goes to stderr, which
// the parent forwards prefixed.
import { readFileSync, writeFileSync, existsSync } from "fs";
import { join } from "path";
import { pathToFileURL } from "url";
import { createInterface } from "readline";
import * as moduleApi from "node:module";
import { EMPTY_GRANTS, type PluginGrants } from "./plugins/permissions";

const [pluginDir, dataDir, grantsArg] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(join(pluginDir, "manifest.json"), "utf8"));

function readGrants(raw: string | undefined): PluginGrants {
  if (!raw) return EMPTY_GRANTS;
  try { return { ...EMPTY_GRANTS, ...JSON.parse(raw) }; }
  catch { return EMPTY_GRANTS; }
}
const grants = readGrants(grantsArg);

// --- builtin modules ---
// A plugin may load only these builtins; rawNetwork adds the socket modules.
// Everything else (child_process, module, vm, v8, inspector, worker_threads,
// internals such as _http_client) reaches processes, the network or the
// loader, and is refused.
const SAFE_BUILTINS = new Set(["assert", "assert/strict", "async_hooks", "buffer", "console",
  "constants", "crypto", "diagnostics_channel", "domain", "events", "fs", "fs/promises", "os", "path",
  "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline",
  "readline/promises", "stream", "stream/consumers", "stream/promises", "stream/web",
  "string_decoder", "sys", "timers", "timers/promises", "tty", "url", "util", "util/types", "zlib"]);
const NET_BUILTINS = new Set(["net", "tls", "dgram", "http", "https", "http2", "dns", "dns/promises"]);
const isBuiltin: (s: string) => boolean = (moduleApi as any).isBuiltin;
function builtinRefusal(specifier: string): string | null {
  if (!isBuiltin(specifier)) return null;
  const name = specifier.replace(/^node:/, "");
  if (SAFE_BUILTINS.has(name)) return null;
  if (NET_BUILTINS.has(name))
    return grants.rawNetwork ? null : `melo: ${specifier} is not available to this plugin (rawNetwork is not granted)`;
  return `melo: ${specifier} is not available to this plugin`;
}
if (typeof (moduleApi as any).registerHooks === "function") {
  (moduleApi as any).registerHooks({
    resolve(specifier: string, context: unknown, nextResolve: (s: string, c: unknown) => unknown) {
      const refused = builtinRefusal(specifier);
      if (refused) throw new Error(refused);
      return nextResolve(specifier, context);
    },
  });
} else {
  // module.registerHooks landed in Node 22.15/23; without it the builtin
  // allowlist can't install. Log so it's visible.
  process.stderr.write("melo: node:module.registerHooks unavailable — builtin module allowlist not installed (Node too old)\n");
}
// process.getBuiltinModule() skips resolve hooks, so it gets the same allowlist.
const hostGetBuiltin = (process as any).getBuiltinModule?.bind(process);
if (hostGetBuiltin) {
  (process as any).getBuiltinModule = (id: string) => {
    const refused = builtinRefusal(String(id));
    if (refused) throw new Error(refused);
    return hostGetBuiltin(id);
  };
}
// os is allowed for its constants and platform facts; setPriority reaches other processes.
{
  const os = (moduleApi as any).createRequire(import.meta.url)("os");
  os.setPriority = () => { throw new Error("melo: os.setPriority is not available to this plugin"); };
  (moduleApi as any).syncBuiltinESMExports();
}

// allowlisted fetch: the manifest's `network` domains are the only hosts a
// plugin may reach through fetch (subdomain wildcards supported).
const allow: string[] = manifest.permissions?.network ?? [];
function hostAllowed(host: string): boolean {
  host = host.toLowerCase();
  return allow.map((p) => p.toLowerCase()).some((pat) => pat.startsWith("*.")
    ? host === pat.slice(2) || host.endsWith(pat.slice(1))
    : host === pat);
}
// One Request is built from the caller's arguments and that same object is
// fetched, so the URL checked is the URL fetched. The constructors are held
// from before the plugin loads, which could replace the globals.
const HostRequest = globalThis.Request, HostURL = globalThis.URL;
function checkedRequest(input: any, init?: any): Request {
  const req = new HostRequest(input, init);
  const u = new HostURL(req.url);
  if (u.protocol !== "https:" && u.protocol !== "http:")
    throw new Error(`melo: ${u.protocol} URLs are not available to this plugin`);
  if (!hostAllowed(u.hostname))
    throw new Error(`melo: ${u.hostname} is not in this plugin's manifest network allowlist`);
  return req;
}
const realFetch = globalThis.fetch;
// Redirects are followed here, one checked hop at a time, at most 20 as in fetch.
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
async function allowlistedFetch(input: any, init?: any): Promise<Response> {
  let req = checkedRequest(input, init);
  const mode = req.redirect;
  for (let hop = 0; ; hop++) {
    const spare = req.body ? req.clone() : req;
    const res = await realFetch(req, { redirect: "manual" });
    if (!REDIRECTS.has(res.status) || mode === "manual") return res;
    const loc = res.headers.get("location");
    if (loc === null) return res;
    if (mode === "error") throw new TypeError(`melo: ${req.url} redirects, and redirect is "error"`);
    if (hop >= 20) throw new TypeError("melo: too many redirects");
    const next = new HostURL(loc, req.url);
    const headers = new Headers(spare.headers);
    let method = spare.method, body: ReadableStream | null = spare.body;
    if ((res.status === 303 && method !== "GET" && method !== "HEAD")
        || ((res.status === 301 || res.status === 302) && method === "POST")) {
      method = "GET";
      body = null;
      for (const h of ["content-type", "content-length", "content-encoding", "content-language", "content-location"])
        headers.delete(h);
    }
    if (next.origin !== new HostURL(req.url).origin)
      for (const h of ["authorization", "cookie", "proxy-authorization"]) headers.delete(h);
    req = checkedRequest(next.href, { method, headers, body, signal: spare.signal,
                                      ...(body ? { duplex: "half" } : {}) });
  }
}
globalThis.fetch = ((input: any, init?: any) => allowlistedFetch(input, init)) as typeof fetch;
// WebSocket bypasses the fetch allowlist, so withhold the global unless the
// plugin granted rawNetwork (same policy as the low-level socket modules).
if (!grants.rawNetwork) {
  (globalThis as any).WebSocket = function () {
    throw new Error("melo: WebSocket is not available to this plugin (rawNetwork is not granted)");
  };
  // In-realm patching like this and the fetch wrapper only stops honest
  // mistakes: the plugin can reach anything this realm can. The --permission
  // flags on the child are what stop fs, child_process and process.binding;
  // anything that must hold belongs behind a flag or in the parent process.
}

// --- NDJSON JSON-RPC bridge to the sidecar parent ---
function send(msg: object) { process.stdout.write(JSON.stringify(msg) + "\n"); }
function notifyParent(method: string, params: unknown) { send({ jsonrpc: "2.0", method, params }); }

// A plugin that console.log()s (well-meant debugging) would otherwise corrupt
// the NDJSON protocol on stdout — route all console output to the parent as a
// log message. (The parent also ignores any non-JSON stdout line defensively.)
for (const k of ["log", "info", "warn", "error", "debug"] as const)
  (console as any)[k] = (...a: unknown[]) => notifyParent("log", { msg: a.map(String).join(" ") });

// One misbehaving async listener must not take down the whole plugin host —
// forward the failure to the parent instead of letting Node abort the process.
process.on("unhandledRejection", (reason) =>
  notifyParent("log", { msg: "unhandled rejection: " + String(reason) }));

// --- the `melo` API handed to the plugin's activate() ---
type SourceDef = {
  id: string; name: string;
  search: (q: string, o: { continuation?: string }) => Promise<unknown>;
  resolveStream: (trackId: string) => Promise<unknown>;
};
const sources = new Map<string, SourceDef>();
const listeners = new Map<string, ((p: unknown) => void)[]>();
const storagePath = join(dataDir, "storage.json");
let storage: Record<string, unknown> = {};
try { if (existsSync(storagePath)) storage = JSON.parse(readFileSync(storagePath, "utf8")); } catch {}

const melo = {
  registerSource(def: SourceDef) { sources.set(def.id, def); },
  player: {
    on(type: string, cb: (p: unknown) => void) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type)!.push(cb);
    },
  },
  storage: {
    get: (k: string) => storage[k],
    set: (k: string, v: unknown) => {
      storage[k] = v;
      writeFileSync(storagePath, JSON.stringify(storage));
    },
  },
  log: (...a: unknown[]) => notifyParent("log", { msg: a.map(String).join(" ") }),
};

// --- boot the plugin, then serve requests from the parent ---
// A load failure (bad entry, syntax error, throwing activate()) is reported
// as a structured `fatal` message so the parent can mark the plugin failed,
// rather than dying with a bare stack trace.
const entry = pathToFileURL(join(pluginDir, manifest.entry.sidecar)).href;
try {
  const mod = await import(entry);
  if (typeof mod.default !== "function")
    throw new Error("plugin has no default-exported activate(melo) function");
  await mod.default(melo);
} catch (e) {
  // the settings row shows one line; the stack goes to the log
  const err = e as Error;
  if (err?.stack) notifyParent("log", { msg: err.stack });
  notifyParent("fatal", { error: String(err?.message || e).split("\n")[0] });
  process.exit(1);
}
notifyParent("registered", {
  sources: [...sources.values()].map((s) => ({ id: s.id, name: s.name })),
  events: [...listeners.keys()],
});

// Exit with the sidecar: a plugin holding a timer would keep this running.
const input = createInterface({ input: process.stdin });
input.on("close", () => process.exit(0));
input.on("line", async (line) => {
  if (!line.trim()) return;
  let msg: any;
  try { msg = JSON.parse(line); } catch { return; }
  const reply = (body: object) => send({ jsonrpc: "2.0", id: msg.id, ...body });
  try {
    if (msg.method === "source/search") {
      const s = sources.get(msg.params.sourceId);
      if (!s) throw new Error(`unknown source ${msg.params.sourceId}`);
      reply({ result: await s.search(msg.params.query, { continuation: msg.params.continuation }) });
    } else if (msg.method === "source/resolveStream") {
      const s = sources.get(msg.params.sourceId);
      if (!s) throw new Error(`unknown source ${msg.params.sourceId}`);
      reply({ result: await s.resolveStream(msg.params.trackId) });
    } else if (msg.method === "event") {
      // await each handler so an async throw is caught here, not as a
      // process-killing unhandled rejection
      for (const cb of listeners.get(msg.params.type) ?? []) {
        try { await cb(msg.params.payload); } catch (e) { melo.log("event handler error:", String(e)); }
      }
      reply({ result: {} });
    } else {
      reply({ error: { code: -32601, message: `unknown method ${msg.method}` } });
    }
  } catch (e) {
    reply({ error: { code: -32000, message: String(e) } });
  }
});
