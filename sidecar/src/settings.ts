import { join } from "path";
import { readFileSync, existsSync, mkdirSync, chmodSync } from "fs";
import { writeFileAtomic, backupOnce, backupPath } from "./atomic";
import { dataDir, musicDir } from "./env";
import type { PluginGrants } from "./plugins/permissions";
import { nearestSupported } from "./locales";
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
export function localePref(): { hl: string; gl: string } {
  const st = loadSettings();
  const sys = systemLocale().replace(/_/g, "-");
  const [sysLang, sysRegion] = sys.split("-");

  // hl decides translated titles; gl steers recommendations and availability.
  // Validated differently: an unsupported hl returns no usable renderers,
  // while gl tolerates anything (gl=XX and gl="" both work).
  const wantLang = (st.language || "").trim() || sysLang || "";
  const hl = nearestSupported(wantLang) || nearestSupported(sysLang || "") || "en";
  if ((st.language || "").trim() && !nearestSupported(wantLang)) {
    console.error(`[locale] language "${st.language}" is not a YouTube locale — using ${hl}`);
  }

  const wantRegion = ((st.region || "").trim() || sysRegion || "US").toUpperCase();
  return { hl: hl.toLowerCase(), gl: wantRegion };
}

function systemLocale(): string {
  try {
    const l = Intl.DateTimeFormat().resolvedOptions().locale;
    if (l) return l;
  } catch { /* fall through */ }
  const env = process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || "";
  const m = /^([A-Za-z]{2,3}(?:[-_][A-Za-z]{2})?)/.exec(env);
  return m ? m[1] : "en-US";
}

export interface SettingsV2 {
  version: 2;
  cookieSource: CookieSource;
  browser: string;              // for --cookies-from-browser
  cookieProfile: string;        // active guest profile name
  homeSource: "youtube" | "ytmusic";
  sendPlayback: boolean;        // report watch history to YT
  downloadPath: string;
  prefetchPercent: number;      // 0-100, when to prefetch next stream
  crossfadeSeconds: number;     // 0 = gapless/no fade
  silenceSkip: boolean;
  metadataAutoEnrich: "off" | "new";
  // which services tagging may contact — auto-tag, the library's auto-tag
  // button and the metadata editor's lookup alike (metadata.ts lookupOrder)
  tagLastfm: boolean;
  tagMusicBrainz: boolean;
  tagDeezer: boolean;
  ytdlpChannel: YtdlpChannel;    // nightly tracks YouTube breakage faster
  language: string;              // hl — controls title translations; "" = system
  region: string;                // gl — content region; "" = system
  lastfmApiKey: string;
  lyricsAutoCaptions: boolean;
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
    homeSource: "youtube",
    sendPlayback: true,
    downloadPath: join(musicDir(), "melo"),
    prefetchPercent: 50,
    crossfadeSeconds: 0,
    silenceSkip: true,
    metadataAutoEnrich: "new",
    tagLastfm: true,
    tagMusicBrainz: true,
    tagDeezer: true,
    ytdlpChannel: "stable",
    language: "",
    region: "",
    lastfmApiKey: "",
    lyricsAutoCaptions: false,
    ui: {},
    plugins: { enabled: {}, grants: {}, settings: {} },
  };
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
      loaded = { ...defaultSettings(), ...raw, version: 2 };
    } catch (e) {
      // Same rule as the library: a file that exists and will not parse is an
      // error. Falling back to defaults and then saving over it would turn
      // one interrupted write into every preference lost.
      const bak = backupPath(p);
      let recovered: SettingsV2 | null = null;
      if (bak) {
        try {
          recovered = { ...defaultSettings(), ...JSON.parse(readFileSync(bak, "utf-8")), version: 2 };
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
export function tagServicesOf(s: Pick<SettingsV2, "tagLastfm" | "tagMusicBrainz" | "tagDeezer">): TagServices {
  return { lastfm: s.tagLastfm !== false, musicbrainz: s.tagMusicBrainz !== false, deezer: s.tagDeezer !== false };
}

export function autoTagEnabled(v: string | undefined): boolean {
  return v === "new";
}

// The keys that pick which identity melo speaks as. A patch touching any must
// drop the cookie caches: cachedVisitorData is one global sent on every
// request, so a switch without a clear speaks as the old identity.
const COOKIE_IDENTITY_KEYS = ["cookieSource", "cookieProfile", "browser"] as const;

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
