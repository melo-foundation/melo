import { createRequire } from "module";

// Node's fetch ignores HTTP(S)_PROXY, and loading jsdom's undici replaces Node's
// dispatcher with a direct one anyway. Ours goes in first, and undici keeps a
// dispatcher it finds. jsdom always ships beside the bundle, so its undici is the
// one used.
// youtube.com's front page sends up to 19 KB of headers; undici stops at 16 KB.
const maxHeaderSize = 64 * 1024;

/** Every fetch's dispatcher: through HTTP(S)_PROXY when one is set. True when it is. */
export function setUpFetch(env: NodeJS.ProcessEnv = process.env): boolean {
  const httpsProxy = env.HTTPS_PROXY || env.https_proxy, httpProxy = env.HTTP_PROXY || env.http_proxy;
  try {
    const fromJsdom = createRequire(createRequire(import.meta.url).resolve("jsdom"));
    const { setGlobalDispatcher, Agent, EnvHttpProxyAgent } = fromJsdom("undici");
    if (!httpsProxy && !httpProxy) { setGlobalDispatcher(new Agent({ maxHeaderSize })); return false; }
    setGlobalDispatcher(new EnvHttpProxyAgent({ httpProxy, httpsProxy, noProxy: env.NO_PROXY || env.no_proxy, maxHeaderSize }));
    return true;
  } catch (e) {
    console.error(`[proxy] not used: ${String(e).split("\n")[0]}`);
    return false;
  }
}
