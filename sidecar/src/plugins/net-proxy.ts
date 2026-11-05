// The network proxy every plugin process without rawNetwork is pointed at
// (NODE_USE_ENV_PROXY). It runs in the sidecar, out of the plugin's reach, and
// checks each tunnel: the host against the manifest's `network` list, and every
// address the host resolves to. A host that resolves to a loopback, private or
// link-local address is refused unless the manifest names that exact host.
import { createServer, type IncomingMessage, type Server } from "http";
import { connect, isIP, type Socket } from "net";
import { lookup as dnsLookup } from "dns/promises";
import { randomBytes } from "crypto";
import { networkHostAllowed } from "./permissions";

export type Lookup = (host: string) => Promise<string[]>;
const systemLookup: Lookup = async (host) =>
  (await dnsLookup(host, { all: true, verbatim: true })).map((a) => a.address);

export interface ProxyRoute {
  network: string[];
  onRefuse?: (target: string, why: string) => void;
}

function v4Private(ip: string): boolean {
  const [a, b] = ip.split(".").map(Number);
  return a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168)
    || (a === 192 && b === 0 && ip.split(".")[2] === "0")
    || (a === 198 && (b === 18 || b === 19));
}

/** Loopback, private, link-local, CGNAT, multicast, reserved or unspecified. */
export function isPrivateAddress(ip: string): boolean {
  if (isIP(ip) === 4) return v4Private(ip);
  if (isIP(ip) !== 6) return true;
  const v6 = ip.toLowerCase();
  const mapped = /^(?:0*:)*:?ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v6) ?? /^64:ff9b::(\d+\.\d+\.\d+\.\d+)$/.exec(v6);
  if (mapped) return v4Private(mapped[1]);
  if (v6 === "::" || v6 === "::1") return true;
  const first = parseInt(v6.split(":")[0] || "0", 16);
  return (first & 0xfe00) === 0xfc00      // fc00::/7 unique local
      || (first & 0xffc0) === 0xfe80      // fe80::/10 link-local
      || (first & 0xff00) === 0xff00      // ff00::/8 multicast
      || v6.startsWith("::ffff:") || v6.startsWith("::");
}

export class PluginProxy {
  private server: Server;
  private routes = new Map<string, ProxyRoute>();
  readonly ready: Promise<number>;
  port = 0;

  constructor(private lookup: Lookup = systemLookup) {
    this.server = createServer((_req, res) => { res.writeHead(405); res.end(); });
    this.server.on("connect", (req, sock: Socket, head) => { void this.tunnel(req, sock, head); });
    this.server.on("clientError", (_e, sock) => sock.destroy());
    this.ready = new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "127.0.0.1", () => {
        this.port = (this.server.address() as { port: number }).port;
        resolve(this.port);
      });
    });
    this.server.unref();
  }

  /** A route for one plugin process; the URL carries its token. */
  add(route: ProxyRoute): { token: string; url: string } {
    const token = randomBytes(18).toString("hex");
    this.routes.set(token, route);
    return { token, url: `http://melo:${token}@127.0.0.1:${this.port}` };
  }
  remove(token: string): void { this.routes.delete(token); }
  close(): void { this.server.close(); this.routes.clear(); }

  private routeOf(req: IncomingMessage): ProxyRoute | undefined {
    const m = /^Basic\s+(.+)$/i.exec(String(req.headers["proxy-authorization"] ?? ""));
    if (!m) return undefined;
    const [user, token] = Buffer.from(m[1], "base64").toString().split(":");
    return user === "melo" ? this.routes.get(token ?? "") : undefined;
  }

  private async tunnel(req: IncomingMessage, sock: Socket, head: Buffer): Promise<void> {
    sock.on("error", () => {});
    const refuse = (status: string) => { sock.end(`HTTP/1.1 ${status}\r\n\r\n`); };
    const route = this.routeOf(req);
    if (!route) return refuse("407 Proxy Authentication Required");
    const target = String(req.url ?? "");
    let host: string, port: number;
    try {
      const u = new URL(`http://${target}`);
      host = u.hostname.replace(/^\[|\]$/g, "").toLowerCase();
      port = Number(u.port || 80);
    } catch { return refuse("400 Bad Request"); }
    const deny = (why: string) => { route.onRefuse?.(target, why); refuse("403 Forbidden"); };
    if (!networkHostAllowed(route.network, host)) return deny("not in the manifest network allowlist");
    let addrs: string[];
    try { addrs = isIP(host) ? [host] : await this.lookup(host); }
    catch { return refuse("502 Bad Gateway"); }
    if (addrs.length === 0) return refuse("502 Bad Gateway");
    const named = route.network.some((p) => p.toLowerCase() === host);
    if (!named && addrs.some(isPrivateAddress)) return deny("resolves to a local or private address");
    const up = connect({ host: addrs[0], port });
    up.on("error", () => { if (!sock.destroyed) refuse("502 Bad Gateway"); });
    up.on("connect", () => {
      sock.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length) up.write(head);
      up.pipe(sock);
      sock.pipe(up);
    });
    sock.on("close", () => up.destroy());
    up.on("close", () => sock.destroy());
  }
}
