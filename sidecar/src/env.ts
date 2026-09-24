// Injected environment — set once by the `initialize` RPC before any handler runs.
// Modules read paths from here, never from a global app object.

export interface SidecarEnv {
  dataDir: string;       // ~/.config/melo  (settings.v2.json, library.v2.json, guest-cookies/, themes/)
  musicDir: string;      // ~/Music; downloads default to <musicDir>/melo
  ytdlpPath: string;     // user-writable self-updating binary
  ffmpegPath?: string;   // melo's own build for the silence scan; empty or absent: PATH
  osPrefersDark: boolean;
  appVersion: string;
}

let env: SidecarEnv | null = null;

export function setEnv(e: SidecarEnv): void {
  env = e;
}

export function getEnv(): SidecarEnv {
  if (!env) throw new Error("sidecar not initialized");
  return env;
}

export const dataDir = (): string => getEnv().dataDir;
export const musicDir = (): string => getEnv().musicDir;
export const ytdlpPath = (): string => getEnv().ytdlpPath;
