import { createRequire } from "module";

// Node's fetch ignores HTTP(S)_PROXY, and loading jsdom's undici replaces Node's
// dispatcher with a direct one anyway. With a proxy set, undici's env-proxy agent
// goes in first, and undici keeps a dispatcher it finds. jsdom always ships beside
// the bundle, so its undici is the one used.
export function useEnvProxy(env: NodeJS.ProcessEnv = process.env): boolean {
  const httpsProxy = env.HTTPS_PROXY || env.https_proxy, httpProxy = env.HTTP_PROXY || env.http_proxy;
  if (!httpsProxy && !httpProxy) return false;
  try {
    const fromJsdom = createRequire(createRequire(import.meta.url).resolve("jsdom"));
    const { setGlobalDispatcher, EnvHttpProxyAgent } = fromJsdom("undici");
    setGlobalDispatcher(new EnvHttpProxyAgent({ httpProxy, httpsProxy, noProxy: env.NO_PROXY || env.no_proxy }));
    return true;
  } catch (e) {
    console.error(`[proxy] not used: ${String(e).split("\n")[0]}`);
    return false;
  }
}
