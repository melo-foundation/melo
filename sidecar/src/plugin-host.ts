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

// --- network scoping ---
// Socket modules are withheld unless the user granted rawNetwork, so the
// manifest's network domains are the effective scope. A plugin needing raw
// sockets declares it; the install-time static scan warns about it.
const LOWLEVEL_NET = new Set(["net", "tls", "dgram", "http", "https", "http2",
  "node:net", "node:tls", "node:dgram", "node:http", "node:https", "node:http2"]);
if (!grants.rawNetwork) {
  if (typeof (moduleApi as any).registerHooks === "function") {
    (moduleApi as any).registerHooks({
      resolve(specifier: string, context: unknown, nextResolve: (s: string, c: unknown) => unknown) {
        if (LOWLEVEL_NET.has(specifier))
          throw new Error(`melo: ${specifier} is not available to this plugin (rawNetwork is not granted)`);
        return nextResolve(specifier, context);
      },
    });
  } else {
    // module.registerHooks landed in Node 22.15/23; on older runtimes the
    // socket-module tripwire can't install. The WebSocket withhold + fetch
    // allowlist + install-time static scan still apply; log so it's visible.
    process.stderr.write("melo: node:module.registerHooks unavailable — low-level socket import block not installed (Node too old)\n");
  }
}

// allowlisted fetch: the manifest's `network` domains are the only hosts a
// plugin may reach through fetch (subdomain wildcards supported).
const allow: string[] = manifest.permissions?.network ?? [];
function hostAllowed(host: string): boolean {
  return allow.some((pat) => pat.startsWith("*.")
    ? host === pat.slice(2) || host.endsWith(pat.slice(1))
    : host === pat);
}
function urlOf(input: any): URL {
  if (input instanceof URL) return input;
  return new URL(typeof input === "string" ? input : input.url);
}
const realFetch = globalThis.fetch;
globalThis.fetch = ((input: any, init?: any) => {
  let u: URL;
  try { u = urlOf(input); } catch (e) { return Promise.reject(e); }
  if (!hostAllowed(u.hostname))
    return Promise.reject(new Error(`melo: ${u.hostname} is not in this plugin's manifest network allowlist`));
  return realFetch(input, init);
}) as typeof fetch;
// WebSocket bypasses the fetch allowlist, so withhold the global unless the
// plugin granted rawNetwork (same policy as the low-level socket modules).
if (!grants.rawNetwork) {
  (globalThis as any).WebSocket = function () {
    throw new Error("melo: WebSocket is not available to this plugin (rawNetwork is not granted)");
  };
  // process.getBuiltinModule() returns builtins without consulting resolve
  // hooks, so it bypasses the tripwire above; the plugin API does not need it.
  // In-realm patching like this and the fetch wrapper only stops honest
  // mistakes: the plugin can reach anything this realm can. The --permission
  // flags on the child are what stop fs, child_process and process.binding;
  // anything that must hold belongs behind a flag or in the parent process.
  delete (process as any).getBuiltinModule;
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
  notifyParent("fatal", { error: String((e as Error)?.stack || e) });
  process.exit(1);
}
notifyParent("registered", {
  sources: [...sources.values()].map((s) => ({ id: s.id, name: s.name })),
  events: [...listeners.keys()],
});

createInterface({ input: process.stdin }).on("line", async (line) => {
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
