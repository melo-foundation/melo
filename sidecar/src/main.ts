// melo sidecar entry: JSON-RPC 2.0 over stdio (NDJSON). stdout=protocol, stderr=logs.

// The modules console.log freely and stdout is the protocol channel.
// Route ALL console output to stderr.
console.log = console.info = console.warn = console.debug = console.error =
  (...a: unknown[]) => process.stderr.write(a.map(String).join(" ") + "\n");

import { method, run, log, notify } from "./rpc";
import { initPlugins, listPlugins } from "./plugins/manager";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { setEnv, type SidecarEnv } from "./env";
import { registerHandlers } from "./handlers";
import { initLibrary } from "./library";
import { loadSettings } from "./settings";
import { ensureYtdlp, maybeUpdateYtdlp, downloadYtdlp } from "./ytdlp";
import { warmStreamSession } from "./streams";
import { warmPoTokenSession } from "./potoken";

const SIDECAR_VERSION = "0.1.0";

let initialized = false;

method("initialize", (params: SidecarEnv & { ytdlpSeedPath?: string }) => {
  if (initialized) return { sidecarVersion: SIDECAR_VERSION, capabilities: [] };
  setEnv(params);

  const settings = loadSettings();
  initLibrary(settings.downloadPath);

  const haveYtdlp = ensureYtdlp(params.ytdlpSeedPath);
  if (haveYtdlp) void maybeUpdateYtdlp();
  // packaged installs ship without a yt-dlp seed (keeps the download small) —
  // fetch it in the background; early stream requests fail gracefully until
  // it lands
  else void downloadYtdlp();
  warmStreamSession();   // player fetch + decipher prep before the first click
  warmPoTokenSession();  // ~1.5s of BotGuard setup, off the first play's path

  registerHandlers();

  // plugins: scan the plugin dir + spawn enabled ones (host bundle sits beside
  // this bundle). onChanged pushes the fresh list to Qt.
  const bundleDir = dirname(fileURLToPath(import.meta.url));
  initPlugins({
    pluginsDir: join(params.dataDir, "plugins"),
    pluginDataRoot: join(params.dataDir, "plugin-data"),
    hostPath: join(bundleDir, "melo-plugin-host.mjs"),
    enabled: settings.plugins?.enabled ?? {},
    grants: settings.plugins?.grants ?? {},
    onChanged: () => notify("plugins/changed", { plugins: listPlugins() }),
  });

  initialized = true;
  log(`[init] sidecar ${SIDECAR_VERSION} ready (dataDir=${params.dataDir}, ytdlp=${haveYtdlp}, ffmpeg=${params.ffmpegPath || "PATH"})`);
  return {
    sidecarVersion: SIDECAR_VERSION,
    capabilities: ["radio", "cookies", "silence"],
    ytdlpAvailable: haveYtdlp,
  };
});

run();
log("[sidecar] started, awaiting initialize");
