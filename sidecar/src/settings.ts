import { join } from "path";
import { readFileSync, existsSync, mkdirSync, chmodSync } from "fs";
import { writeFileAtomic, backupOnce, backupPath } from "./atomic";
import { dataDir, musicDir } from "./env";
import type { PluginGrants } from "./plugins/permissions";
import { nearestSupported, isSupportedRegion } from "./locales";
import type { TagServices } from "./metadata";

// melo settings. Sidecar-relevant fields are typed; everything UI-only lives under `ui` as an
// opaque JSON object owned by the Qt side (theme id, shortcuts, backgrounds...).

export type CookieSource = "browser" | "guest" | "none";
export type YtdlpChannel = "stable" | "nightly";

/** The locale sent to YouTube as hl/gl.
 *
 *  hl decides translated vs original titles: renderers return a creator
 *  translation whenever hl differs from the video's language. There is no
 *  "no locale": hl "", "zxx", "und" and "mul" are rejected, and omitting hl
 *  means en. /player's videoDetails.title ignores hl (always the original). */
export function localePref(): { hl: string; gl: string | undefined } {
  const st = loadSettings();
  const sys = systemLocale().replace(/_/g, "-");
  const sysLang = sys.split("-")[0];
  const sysRegion = systemRegion(sys);

  // hl decides translated titles; gl steers recommendations and availability.
  const wantLang = (st.language || "").trim() || sysLang || "";
  const hl = nearestSupported(wantLang) || nearestSupported(sysLang || "") || "en";
  if ((st.language || "").trim() && !nearestSupported(wantLang)) {
    console.error(`[locale] language "${st.language}" is not a YouTube locale — using ${hl}`);
  }

  const wantRegion = ((st.region || "").trim() || sysRegion || "US").toUpperCase();
  // hl as LOCALES spells it: YouTube answers 400 to "en-gb" or "pt-br".
  // A region YouTube does not offer goes as none: undefined drops out of the JSON
  return { hl, gl: isSupportedRegion(wantRegion) ? wantRegion : undefined };
}

// The region subtag, past a script or variant: zh-Hans-CN is CN, not "HANS"
export function systemRegion(locale: string): string {
  return locale.split("-").slice(1).find((p) => /^[A-Za-z]{2}$/.test(p))?.toUpperCase() ?? "";
}

// ICU answers "und" when LC_ALL or LC_MESSAGES is set but empty; POSIX skips an
// empty one, so the variables are read the same way
export function systemLocale(intl: string = intlLocale(), env: NodeJS.ProcessEnv = process.env): string {
  if (intl && intl !== "und") return intl;
  const v = env.LC_ALL || env.LC_MESSAGES || env.LANG || "";
  const m = /^([A-Za-z]{2,3}(?:[-_][A-Za-z]{2})?)/.exec(v);
  return m ? m[1] : "en-US";
}

function intlLocale(): string {
  try { return Intl.DateTimeFormat().resolvedOptions().locale; } catch { return ""; }
}

export interface SettingsV2 {
  version: 2;
  cookieSource: CookieSource;
  browser: string;              // for --cookies-from-browser
  cookieProfile: string;        // active guest profile name
  streamCookieSource: "same" | "browser";   // whose cookies resolve streams
  homeSource: "youtube" | "ytmusic";
  sendPlayback: boolean;        // report watch history to YT
  downloadPath: string;
  prefetchPercent: number;      // 0-100, when to prefetch next stream
  crossfadeSeconds: number;     // 0 = gapless/no fade
  silenceSkip: boolean;
  metadataAutoEnrich: "off" | "new";
  // which services tagging may contact — auto-tag, the library's auto-tag
  // button and the metadata editor's lookup alike (metadata.ts lookupOrder)
  tagYoutubeMusic: boolean;
  tagLastfm: boolean;
  tagMusicBrainz: boolean;
  tagDeezer: boolean;
  ytdlpChannel: YtdlpChannel;    // nightly tracks YouTube breakage faster
  language: string;              // hl — controls title translations; "" = system
  region: string;                // gl — content region; "" = system
  lastfmApiKey: string;
  lyricsAutoCaptions: boolean;
  discordStatus: boolean;       // the playing track as the Discord activity
  ui: Record<string, unknown>;  // Qt-owned: theme, shortcuts, layout, backgrounds...
  plugins: {
    enabled: Record<string, boolean>;                    // per-plugin enable state
    grants?: Record<string, PluginGrants>;               // per-plugin ui / rawNetwork / intercept grants
    settings?: Record<string, Record<string, unknown>>;  // per-plugin values, keyed by plugin id
  };
}

const FILE = "settings.v2.json";

export function defaultSettings(): SettingsV2 {
  return {
    version: 2,
    cookieSource: "guest",
    browser: "firefox",
    cookieProfile: "Default",
    streamCookieSource: "same",
    homeSource: "youtube",
    sendPlayback: true,
    downloadPath: join(musicDir(), "melo"),
    prefetchPercent: 50,
    crossfadeSeconds: 0,
    silenceSkip: true,
    metadataAutoEnrich: "new",
    tagYoutubeMusic: true,
    tagLastfm: false,
    tagMusicBrainz: true,
    tagDeezer: true,
    ytdlpChannel: "stable",
    language: "",
    region: "",
    lastfmApiKey: "",
    lyricsAutoCaptions: false,
    discordStatus: false,
    ui: {},
    plugins: { enabled: {}, grants: {}, settings: {} },
  };
}

// A saved file without tagLastfm predates the off default and keeps it on.
export function fromSaved(raw: Partial<SettingsV2>): SettingsV2 {
  return { ...defaultSettings(), tagLastfm: true, ...raw, version: 2 };
}

let cached: SettingsV2 | null = null;
let settingsReadFailed = false;

export function loadSettings(): SettingsV2 {
  if (cached) return cached;
  const p = join(dataDir(), FILE);
  let loaded: SettingsV2;
  if (!existsSync(p)) {
    loaded = defaultSettings();
  } else {
    try {
      const raw = JSON.parse(readFileSync(p, "utf-8"));
      loaded = fromSaved(raw);
    } catch (e) {
      // Same rule as the library: a file that exists and will not parse is an
      // error. Falling back to defaults and then saving over it would turn
      // one interrupted write into every preference lost.
      const bak = backupPath(p);
      let recovered: SettingsV2 | null = null;
      if (bak) {
        try {
          recovered = fromSaved(JSON.parse(readFileSync(bak, "utf-8")));
          process.stderr.write(`[settings] ${p} is unreadable; recovered from the backup\n`);
        } catch { /* the backup is gone too */ }
      }
      if (recovered) {
        loaded = recovered;
      } else {
        settingsReadFailed = true;
        process.stderr.write(`[settings] ${p} exists but will not parse (${String(e)}). NOT overwriting it; this session uses defaults and will not save.\n`);
        loaded = defaultSettings();
      }
    }
  }
  cached = loaded;
  return loaded;
}

// The services tagging may contact, as metadata.ts takes them. Separate keys
// because saveSettings merges patches shallowly, so one object would have to
// be sent whole by every toggle.
export function tagServicesOf(s: Pick<SettingsV2, "tagYoutubeMusic" | "tagLastfm" | "tagMusicBrainz" | "tagDeezer">): TagServices {
  return { ytmusic: s.tagYoutubeMusic !== false, lastfm: s.tagLastfm !== false,
           musicbrainz: s.tagMusicBrainz !== false, deezer: s.tagDeezer !== false };
}

export function autoTagEnabled(v: string | undefined): boolean {
  return v === "new";
}

// The keys that pick which identity melo speaks as. A patch touching any must
// drop the cookie caches: cachedVisitorData is one global sent on every
// request, so a switch without a clear speaks as the old identity.
const COOKIE_IDENTITY_KEYS = ["cookieSource", "cookieProfile", "browser", "streamCookieSource"] as const;

export function touchesCookieIdentity(patch: Partial<SettingsV2>): boolean {
  return COOKIE_IDENTITY_KEYS.some((k) => patch[k] !== undefined);
}

export function saveSettings(patch: Partial<SettingsV2>, removeUi: string[] = []): SettingsV2 {
  const current = loadSettings();
  const merged: SettingsV2 = { ...current, ...patch, version: 2 };
  // ui is merged shallowly per-key so Qt can patch single keys — which means
  // a key missing from the patch is kept, so a removal has to be named
  if (patch.ui) merged.ui = { ...current.ui, ...patch.ui };
  if (removeUi.length) {
    const ui = { ...(merged.ui ?? {}) } as Record<string, unknown>;
    for (const k of removeUi) delete ui[k];
    merged.ui = ui as SettingsV2["ui"];
  }
  if (settingsReadFailed) {
    process.stderr.write("[settings] refusing to save over settings that failed to load\n");
    cached = merged;
    return merged;
  }
  const path = join(dataDir(), FILE);
  backupOnce(path);
  // 0600: holds lastfmApiKey among other things. Atomic, so an interrupted
  // write cannot leave a truncated file.
  writeFileAtomic(path, JSON.stringify(merged, null, 2), 0o600);
  try { chmodSync(path, 0o600); } catch { /* not ours, or gone */ }
  cached = merged;
  return merged;
}
