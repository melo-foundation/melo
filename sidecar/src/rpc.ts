// Newline-delimited JSON-RPC 2.0 over stdio.
// HARD RULE: stdout carries protocol only; all logging goes to stderr.

import { createInterface } from "readline";

type Handler = (params: any) => Promise<unknown> | unknown;

const handlers = new Map<string, Handler>();

export function method(name: string, fn: Handler): void {
  handlers.set(name, fn);
}

export function notify(methodName: string, params: unknown): void {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: methodName, params }) + "\n");
}

export function log(...args: unknown[]): void {
  process.stderr.write(args.map(String).join(" ") + "\n");
}

// Error code bands: -32010 auth/cookies, -32020 yt-dlp, -32030 network.
export class RpcError extends Error {
  constructor(public code: number, message: string, public data?: unknown) {
    super(message);
  }
}

function respond(id: unknown, body: object): void {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, ...body }) + "\n");
}

export function run(): void {
  // Node exits on an unhandled rejection (since v15), so an async handler
  // throwing outside its try would kill the sidecar mid-playback. Report and
  // keep serving, on stderr only: stdout is the NDJSON protocol.
  process.on("unhandledRejection", (reason) => {
    process.stderr.write(`[sidecar] unhandled rejection: ${reason instanceof Error ? reason.stack : String(reason)}\n`);
  });
  process.on("uncaughtException", (err) => {
    process.stderr.write(`[sidecar] uncaught exception: ${err?.stack ?? String(err)}\n`);
  });

  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", async (line) => {
    if (!line.trim()) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      respond(null, { error: { code: -32700, message: "parse error" } });
      return;
    }
    const { id, method: name, params } = msg;
    const fn = handlers.get(name);
    if (!fn) {
      if (id !== undefined) respond(id, { error: { code: -32601, message: `unknown method ${name}` } });
      return;
    }
    try {
      const result = await fn(params ?? {});
      if (id !== undefined) respond(id, { result: result ?? null });
    } catch (e: any) {
      log(`[rpc] ${name} failed:`, e?.stack ?? e);
      if (id !== undefined) {
        const code = e instanceof RpcError ? e.code : -32000;
        respond(id, { error: { code, message: String(e?.message ?? e), data: e?.data } });
      }
    }
  });
  rl.on("close", () => process.exit(0));
}
