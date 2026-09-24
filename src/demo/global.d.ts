// Ambient types matching musetop's global.d.ts — just the types used by demo components

interface SearchResult {
  id: string;
  title: string;
  channel: string;
  duration: number;
  thumbnail: string;
}

interface SearchPlaylistResult {
  playlistId: string;
  title: string;
  channel: string;
  videoCount: number;
  thumbnail: string;
}

interface SearchFilters {
  sort?: "relevance" | "date" | "views" | "rating";
  type?: "any" | "video" | "channel" | "playlist" | "movie";
  uploadDate?: "any" | "hour" | "today" | "week" | "month" | "year";
  duration?: "any" | "short" | "medium" | "long";
}

interface PlaylistInfo {
  playlistId: string;
  title: string;
  description: string;
  thumbnail: string;
}

interface HomeSection {
  title: string;
  playlists: PlaylistInfo[];
}

interface ChipItem {
  text: string;
  token: string;
  isSelected: boolean;
}

interface ShortcutMap {
  toggleSearch: string;
  playPause: string;
  rewind: string;
  forward: string;
  nextTrack: string;
  prevTrack: string;
  prevTrackAlt: string;
  deleteTrack: string;
  addToLibrary: string;
  uiLock: string;
  bgPresetNext: string;
  bgPresetPrev: string;
}

type BgType = "none" | "gradient" | "orbs" | "aurora" | "particles" | "starfield" | "mesh" | "bokeh" | "waves" | "noise";

interface BackgroundConfig {
  type: BgType;
  gradient?: string;
  opacity: number;
  blur: number;
  blendMode?: string;
  options: Record<string, number | string | boolean>;
  scale?: number;
  positionX?: number;
  positionY?: number;
}

interface ThemePalette {
  accent: string;
  accentHover: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  textMuted: string;
  bgBase: string;
  bgSurface: string;
  bgElevated: string;
  bgOverlay: string;
  bgHover: string;
  border: string;
  borderLight: string;
  success: string;
}

interface Theme {
  id: string;
  name: string;
  palette: ThemePalette;
  settings: {
    transparentHover: boolean;
    hoverOpacity: number;
    miniTransparentHover: boolean;
    miniHoverOpacity: number;
    visualizerBg: string;
    visualizerBgAlpha: number;
    bgOpacity: number;
    glassBlur: "off" | "always" | "hover" | "away";
    glassMaterial?: "acrylic" | "mica";
    contextMenuOpacity: number;
    textShadow: boolean;
    textShadowColor: string;
    textShadowBlur: number;
    textShadowOpacity: number;
    textShadowBlend: string;
    font: string;
    fontScale: number;
    fontWeight: number;
    playerHeight: number;
    uiLocked: boolean;
    fontUrl?: string;
    googleFont?: string;
    background?: BackgroundConfig;
  };
  customCSS: string;
  builtIn: boolean;
  glyphPreset?: string;
  glyphs?: Partial<Record<string, { d: string | string[]; fill?: boolean; viewBox?: string; strokeWidth?: number }>>;
  buttonShape?: "sharp" | "rounded" | "pill";
}

interface TrackMetadata {
  artist?: string;
  cleanTitle?: string;
  album?: string;
  albumArt?: string;
  year?: number;
  genre?: string;
  artSource?: "album" | "custom" | "thumbnail" | "default";
}

interface LibraryTrack {
  id: string;
  title: string;
  channel: string;
  duration: number;
  thumbnail: string;
  downloaded: boolean;
  addedAt: number;
  metadata?: TrackMetadata;
}

interface LibraryPlaylist {
  playlistId: string;
  title: string;
  thumbnail: string;
  trackIds: string[];
  addedAt: number;
}

interface LibraryData {
  tracks: LibraryTrack[];
  playlists: LibraryPlaylist[];
}

interface Settings {
  cookieSource: "browser" | "guest" | "none";
  browser: string;
  cookieProfile: string;
  cookieProfiles: string[];
  sendPlayback: boolean;
  homeSource: "youtube" | "youtube-music";
  prefetchPercent: number;
  downloadPath: string;
  transparentHover: boolean;
  hoverOpacity: number;
  miniTransparentHover: boolean;
  miniHoverOpacity: number;
  crossfadeDuration: number;
  silenceThreshold: number;
  silenceScanStart: number;
  silenceScanEnd: number;
  visualizerBg: string;
  visualizerBgAlpha: number;
  bgOpacity: number;
  glassBlur: "off" | "always" | "hover" | "away";
  glassMaterial?: "acrylic" | "mica";
  contextMenuOpacity: number;
  libraryDefault: "both" | "add" | "download";
  playlistDefault: "both" | "add" | "download";
  textShadow: boolean;
  textShadowColor: string;
  textShadowBlur: number;
  textShadowOpacity: number;
  textShadowBlend: string;
  font: string;
  fontScale: number;
  fontWeight: number;
  playerHeight: number;
  uiLocked: boolean;
  zoomScale: number;
  background?: BackgroundConfig;
  shortcuts: ShortcutMap;
  pasteAction: "queue" | "play" | "library";
  playlistPasteAction: "open" | "play" | "library";
  activeThemeId: string;
  lastfmApiKey: string;
  artPriority: ("custom" | "album" | "thumbnail")[];
  autoEnrich: "off" | "heuristic" | "api";
}
