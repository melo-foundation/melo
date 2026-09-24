import { createContext, useContext } from "react";

// ── Types ──

export interface GlyphDef {
  d: string | string[];
  fill?: boolean;
  viewBox?: string;
  strokeWidth?: number;
}

export type GlyphName =
  | "close"
  | "minimize"
  | "maximize"
  | "restore"
  | "compactOn"
  | "compactOff"
  | "miniExpand"
  | "miniCollapse"
  | "chevronDown"
  | "chevronUp"
  | "chevronLeft"
  | "chevronRight"
  | "arrowUp"
  | "arrowDown"
  | "sortAsc"
  | "sortDesc"
  | "dropdownArrow"
  | "check"
  | "remove"
  | "filter"
  | "prevPreset"
  | "nextPreset"
  | "expand"
  | "playAll"
  | "search"
  | "pin"
  | "settings"
  | "play"
  | "pause"
  | "prevTrack"
  | "nextTrack"
  | "eq"
  | "queueList"
  | "save"
  | "shuffle"
  | "layoutList"
  | "layoutGrid"
  | "layoutCompact"
  | "refresh";

export type GlyphSet = Record<GlyphName, GlyphDef>;

// ── Default (sharp geometric, medium weight) ──

const defaultGlyphs: GlyphSet = {
  close: {
    d: ["M18 6L6 18", "M6 6L18 18"],
    strokeWidth: 2.5,
  },
  minimize: {
    d: "M6 12H18",
    strokeWidth: 2.5,
  },
  maximize: {
    d: "M4 4H20V20H4Z",
    strokeWidth: 2,
  },
  restore: {
    d: ["M8 4H20V16", "M4 8H16V20H4Z"],
    strokeWidth: 2,
  },
  compactOn: {
    d: "M7 9L12 15L17 9",
    strokeWidth: 2,
  },
  compactOff: {
    d: "M7 15L12 9L17 15",
    strokeWidth: 2,
  },
  miniExpand: {
    d: ["M4 4H20V20H4Z", "M12 8V16", "M8 12H16"],
    strokeWidth: 2,
  },
  miniCollapse: {
    d: ["M4 4H20V20H4Z", "M8 12H16"],
    strokeWidth: 2,
  },
  chevronDown: {
    d: "M6 9L12 15L18 9",
    strokeWidth: 2,
  },
  chevronUp: {
    d: "M6 15L12 9L18 15",
    strokeWidth: 2,
  },
  chevronLeft: {
    d: "M15 6L9 12L15 18",
    strokeWidth: 2,
  },
  chevronRight: {
    d: "M9 6L15 12L9 18",
    strokeWidth: 2,
  },
  arrowUp: {
    d: ["M12 19V5", "M5 12L12 5L19 12"],
    strokeWidth: 2,
  },
  arrowDown: {
    d: ["M12 5V19", "M5 12L12 19L19 12"],
    strokeWidth: 2,
  },
  sortAsc: {
    d: "M6 16L12 8L18 16",
    fill: true,
  },
  sortDesc: {
    d: "M6 8L12 16L18 8",
    fill: true,
  },
  dropdownArrow: {
    d: "M6 9L12 15L18 9",
    fill: true,
  },
  check: {
    d: "M5 12L10 17L19 7",
    strokeWidth: 2.5,
  },
  remove: {
    d: "M6 12H18",
    strokeWidth: 2.5,
  },
  filter: {
    d: ["M12 5A2 2 0 1 0 12 9A2 2 0 1 0 12 5Z", "M12 10A2 2 0 1 0 12 14A2 2 0 1 0 12 10Z", "M12 15A2 2 0 1 0 12 19A2 2 0 1 0 12 15Z"],
    fill: true,
  },
  prevPreset: {
    d: "M15 6L9 12L15 18",
    fill: true,
  },
  nextPreset: {
    d: "M9 6L15 12L9 18",
    fill: true,
  },
  expand: {
    d: "M9 6L15 12L9 18",
    fill: true,
  },
  playAll: {
    d: "M6 4L20 12L6 20Z",
    fill: true,
  },
  search: {
    d: ["M3.5 10.5A7 7 0 1 0 17.5 10.5A7 7 0 1 0 3.5 10.5", "M15.5 15.5L21 21"],
    strokeWidth: 2.5,
  },
  pin: {
    d: ["M12 17V22", "M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"],
    strokeWidth: 2.5,
  },
  settings: {
    d: ["M9 12A3 3 0 1 0 15 12A3 3 0 1 0 9 12", "M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"],
    strokeWidth: 2,
  },
  play: {
    d: "M6 3.5L20 12L6 20.5V3.5Z",
    fill: true,
  },
  pause: {
    d: ["M5 3H10V21H5Z", "M14 3H19V21H14Z"],
    fill: true,
  },
  prevTrack: {
    d: ["M4 3H7V21H4Z", "M20 3.5L9 12L20 20.5V3.5Z"],
    fill: true,
  },
  nextTrack: {
    d: ["M4 3.5L15 12L4 20.5V3.5Z", "M17 3H20V21H17Z"],
    fill: true,
  },
  eq: {
    d: ["M4 21V14", "M4 10V3", "M12 21V12", "M12 8V3", "M20 21V16", "M20 12V3", "M1 14H7", "M9 8H15", "M17 16H23"],
    strokeWidth: 2,
  },
  queueList: {
    d: ["M3 6H21", "M3 12H21", "M3 18H21"],
    strokeWidth: 2.5,
  },
  save: {
    d: ["M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z", "M17 21V13H7V21", "M7 3V8H15"],
    strokeWidth: 2,
  },
  shuffle: {
    d: ["M16 3H21V8", "M4 20L21 3", "M21 16V21H16", "M15 15L21 21", "M4 4L9 9"],
    strokeWidth: 2,
  },
  layoutList: {
    d: ["M0 1H14V3.5H0Z", "M0 5.75H14V8.25H0Z", "M0 10.5H14V13H0Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  layoutGrid: {
    d: ["M0 0H6V6H0Z", "M8 0H14V6H8Z", "M0 8H6V14H0Z", "M8 8H14V14H8Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  layoutCompact: {
    d: ["M0 0.5H14V2.5H0Z", "M0 4H14V6H0Z", "M0 7.5H14V9.5H0Z", "M0 11H14V13H0Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  refresh: {
    d: ["M23 4V10H17", "M20.49 15A9 9 0 1 1 18.37 5.64L23 10"],
    strokeWidth: 2,
  },
};

// ── Rounded preset (filled shapes, bolder, softer feel) ──

const roundedGlyphs: GlyphSet = {
  ...defaultGlyphs,
  close: {
    d: ["M12 3A9 9 0 1 0 12 21A9 9 0 1 0 12 3Z", "M15 9L9 15", "M9 9L15 15"],
    strokeWidth: 2,
  },
  minimize: {
    d: "M7 12H17",
    strokeWidth: 3,
  },
  maximize: {
    d: "M6 4A2 2 0 0 0 4 6V18A2 2 0 0 0 6 20H18A2 2 0 0 0 20 18V6A2 2 0 0 0 18 4Z",
    strokeWidth: 2,
  },
  restore: {
    d: ["M9 4H18A2 2 0 0 1 20 6V15", "M6 8A2 2 0 0 0 4 10V18A2 2 0 0 0 6 20H14A2 2 0 0 0 16 18V10A2 2 0 0 0 14 8Z"],
    strokeWidth: 2,
  },
  compactOn: {
    d: "M7 9L12 15L17 9Z",
    fill: true,
  },
  compactOff: {
    d: "M7 15L12 9L17 15Z",
    fill: true,
  },
  miniExpand: {
    d: ["M6 4A2 2 0 0 0 4 6V18A2 2 0 0 0 6 20H18A2 2 0 0 0 20 18V6A2 2 0 0 0 18 4Z", "M12 8V16", "M8 12H16"],
    strokeWidth: 2,
  },
  miniCollapse: {
    d: ["M6 4A2 2 0 0 0 4 6V18A2 2 0 0 0 6 20H18A2 2 0 0 0 20 18V6A2 2 0 0 0 18 4Z", "M8 12H16"],
    strokeWidth: 2,
  },
  chevronDown: {
    d: "M6 9L12 15L18 9Z",
    fill: true,
  },
  chevronUp: {
    d: "M6 15L12 9L18 15Z",
    fill: true,
  },
  chevronLeft: {
    d: "M15 6L9 12L15 18Z",
    fill: true,
  },
  chevronRight: {
    d: "M9 6L15 12L9 18Z",
    fill: true,
  },
  arrowUp: {
    d: ["M12 19V5", "M5 12L12 5L19 12"],
    strokeWidth: 2.5,
  },
  arrowDown: {
    d: ["M12 5V19", "M5 12L12 19L19 12"],
    strokeWidth: 2.5,
  },
  sortAsc: {
    d: "M6 16L12 8L18 16Z",
    fill: true,
  },
  sortDesc: {
    d: "M6 8L12 16L18 8Z",
    fill: true,
  },
  dropdownArrow: {
    d: "M6 9L12 15L18 9Z",
    fill: true,
  },
  check: {
    d: "M5 12L10 17L19 7",
    strokeWidth: 3,
  },
  remove: {
    d: "M7 12H17",
    strokeWidth: 3,
  },
  expand: {
    d: "M9 6L15 12L9 18Z",
    fill: true,
  },
  playAll: {
    d: "M7 5A1 1 0 0 1 8.5 4.1L19.5 11A1 1 0 0 1 19.5 13L8.5 19.9A1 1 0 0 1 7 19Z",
    fill: true,
  },
  filter: {
    d: ["M6 7H18", "M6 12H18", "M6 17H18"],
    strokeWidth: 2.5,
  },
  search: {
    d: ["M3.5 10.5A7 7 0 1 0 17.5 10.5A7 7 0 1 0 3.5 10.5", "M15.5 15.5L21 21"],
    strokeWidth: 3,
  },
  pin: {
    d: ["M12 17V22", "M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"],
    strokeWidth: 2,
  },
  settings: {
    // Simpler gear: circle + 6 lines radiating out
    d: ["M9 12A3 3 0 1 0 15 12A3 3 0 1 0 9 12", "M12 2V6", "M12 18V22", "M2 12H6", "M18 12H22", "M4.93 4.93L7.76 7.76", "M16.24 16.24L19.07 19.07", "M4.93 19.07L7.76 16.24", "M16.24 7.76L19.07 4.93"],
    strokeWidth: 2.5,
  },
  play: {
    d: "M7 4A1 1 0 0 1 8.5 3.2L20 11A1 1 0 0 1 20 13L8.5 20.8A1 1 0 0 1 7 20Z",
    fill: true,
  },
  pause: {
    d: ["M6 3A2 2 0 0 1 8 3H9A2 2 0 0 1 11 5V19A2 2 0 0 1 9 21H8A2 2 0 0 1 6 19Z", "M13 3A2 2 0 0 1 15 3H16A2 2 0 0 1 18 5V19A2 2 0 0 1 16 21H15A2 2 0 0 1 13 19Z"],
    fill: true,
  },
  prevTrack: {
    d: ["M4 3A1 1 0 0 1 5 3H6A1 1 0 0 1 7 4V20A1 1 0 0 1 6 21H5A1 1 0 0 1 4 20Z", "M20 3.5L9 12L20 20.5V3.5Z"],
    fill: true,
  },
  nextTrack: {
    d: ["M4 3.5L15 12L4 20.5V3.5Z", "M17 3A1 1 0 0 1 18 3H19A1 1 0 0 1 20 4V20A1 1 0 0 1 19 21H18A1 1 0 0 1 17 20Z"],
    fill: true,
  },
  eq: {
    d: ["M4 21V14", "M4 10V3", "M12 21V12", "M12 8V3", "M20 21V16", "M20 12V3", "M1 14H7", "M9 8H15", "M17 16H23"],
    strokeWidth: 2.5,
  },
  queueList: {
    d: ["M3 6H21", "M3 12H21", "M3 18H21"],
    strokeWidth: 3,
  },
  save: {
    d: ["M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z", "M17 21V13H7V21", "M7 3V8H15"],
    strokeWidth: 2.5,
  },
  shuffle: {
    d: ["M16 3H21V8", "M4 20L21 3", "M21 16V21H16", "M15 15L21 21", "M4 4L9 9"],
    strokeWidth: 2.5,
  },
  layoutList: {
    d: ["M1 1A1 1 0 0 1 2 0H12A1 1 0 0 1 13 1V2.5A1 1 0 0 1 12 3.5H2A1 1 0 0 1 1 2.5Z", "M1 6.25A1 1 0 0 1 2 5.25H12A1 1 0 0 1 13 6.25V7.75A1 1 0 0 1 12 8.75H2A1 1 0 0 1 1 7.75Z", "M1 11A1 1 0 0 1 2 10H12A1 1 0 0 1 13 11V12.5A1 1 0 0 1 12 13.5H2A1 1 0 0 1 1 12.5Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  layoutGrid: {
    d: ["M1 0A1 1 0 0 0 0 1V5A1 1 0 0 0 1 6H5A1 1 0 0 0 6 5V1A1 1 0 0 0 5 0Z", "M9 0A1 1 0 0 0 8 1V5A1 1 0 0 0 9 6H13A1 1 0 0 0 14 5V1A1 1 0 0 0 13 0Z", "M1 8A1 1 0 0 0 0 9V13A1 1 0 0 0 1 14H5A1 1 0 0 0 6 13V9A1 1 0 0 0 5 8Z", "M9 8A1 1 0 0 0 8 9V13A1 1 0 0 0 9 14H13A1 1 0 0 0 14 13V9A1 1 0 0 0 13 8Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  layoutCompact: {
    d: ["M1 0.5A1 1 0 0 0 0 1.5V2A1 1 0 0 0 1 3H13A1 1 0 0 0 14 2V1.5A1 1 0 0 0 13 0.5Z", "M1 4A1 1 0 0 0 0 5V5.5A1 1 0 0 0 1 6.5H13A1 1 0 0 0 14 5.5V5A1 1 0 0 0 13 4Z", "M1 7.5A1 1 0 0 0 0 8.5V9A1 1 0 0 0 1 10H13A1 1 0 0 0 14 9V8.5A1 1 0 0 0 13 7.5Z", "M1 11A1 1 0 0 0 0 12V12.5A1 1 0 0 0 1 13.5H13A1 1 0 0 0 14 12.5V12A1 1 0 0 0 13 11Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
};

// ── Minimal preset (thin strokes, open shapes, airy) ──

const minimalGlyphs: GlyphSet = {
  ...defaultGlyphs,
  close: {
    d: ["M16 8L8 16", "M8 8L16 16"],
    strokeWidth: 1.5,
  },
  minimize: {
    d: "M8 12H16",
    strokeWidth: 1.5,
  },
  maximize: {
    d: ["M5 8V5H8", "M16 5H19V8", "M19 16V19H16", "M8 19H5V16"],
    strokeWidth: 1.5,
  },
  restore: {
    d: ["M10 4H19V13", "M4 10V18H12", "M4 10H8", "M12 18V14"],
    strokeWidth: 1.5,
  },
  compactOn: {
    d: "M8 10L12 14L16 10",
    strokeWidth: 1.5,
  },
  compactOff: {
    d: "M8 14L12 10L16 14",
    strokeWidth: 1.5,
  },
  miniExpand: {
    d: ["M12 6V18", "M6 12H18"],
    strokeWidth: 1.5,
  },
  miniCollapse: {
    d: "M6 12H18",
    strokeWidth: 1.5,
  },
  chevronDown: {
    d: "M8 10L12 14L16 10",
    strokeWidth: 1.5,
  },
  chevronUp: {
    d: "M8 14L12 10L16 14",
    strokeWidth: 1.5,
  },
  chevronLeft: {
    d: "M14 8L10 12L14 16",
    strokeWidth: 1.5,
  },
  chevronRight: {
    d: "M10 8L14 12L10 16",
    strokeWidth: 1.5,
  },
  arrowUp: {
    d: ["M12 18V6", "M7 11L12 6L17 11"],
    strokeWidth: 1.5,
  },
  arrowDown: {
    d: ["M12 6V18", "M7 13L12 18L17 13"],
    strokeWidth: 1.5,
  },
  sortAsc: {
    d: "M8 15L12 9L16 15",
    strokeWidth: 1.5,
  },
  sortDesc: {
    d: "M8 9L12 15L16 9",
    strokeWidth: 1.5,
  },
  dropdownArrow: {
    d: "M8 10L12 14L16 10",
    strokeWidth: 1.5,
  },
  check: {
    d: "M6 12L10 16L18 8",
    strokeWidth: 1.5,
  },
  remove: {
    d: "M8 12H16",
    strokeWidth: 1.5,
  },
  filter: {
    d: ["M12 6A1.5 1.5 0 1 0 12 9A1.5 1.5 0 1 0 12 6Z", "M12 10.5A1.5 1.5 0 1 0 12 13.5A1.5 1.5 0 1 0 12 10.5Z", "M12 15A1.5 1.5 0 1 0 12 18A1.5 1.5 0 1 0 12 15Z"],
    fill: true,
  },
  prevPreset: {
    d: "M14 7L10 12L14 17",
    strokeWidth: 1.5,
  },
  nextPreset: {
    d: "M10 7L14 12L10 17",
    strokeWidth: 1.5,
  },
  expand: {
    d: "M10 8L14 12L10 16",
    strokeWidth: 1.5,
  },
  playAll: {
    d: "M8 6L18 12L8 18",
    strokeWidth: 1.5,
  },
  search: {
    d: ["M3.5 10.5A7 7 0 1 0 17.5 10.5A7 7 0 1 0 3.5 10.5", "M15.5 15.5L21 21"],
    strokeWidth: 1.5,
  },
  pin: {
    d: ["M12 17V22", "M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"],
    strokeWidth: 1.5,
  },
  settings: {
    d: ["M9 12A3 3 0 1 0 15 12A3 3 0 1 0 9 12", "M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"],
    strokeWidth: 1.5,
  },
  play: {
    d: "M8 5L18 12L8 19",
    strokeWidth: 1.5,
  },
  pause: {
    d: ["M7 4V20", "M17 4V20"],
    strokeWidth: 2,
  },
  prevTrack: {
    d: ["M5 4V20", "M19 4L9 12L19 20"],
    strokeWidth: 1.5,
  },
  nextTrack: {
    d: ["M5 4L15 12L5 20", "M19 4V20"],
    strokeWidth: 1.5,
  },
  eq: {
    d: ["M4 21V14", "M4 10V3", "M12 21V12", "M12 8V3", "M20 21V16", "M20 12V3", "M1 14H7", "M9 8H15", "M17 16H23"],
    strokeWidth: 1.5,
  },
  queueList: {
    d: ["M4 7H20", "M4 12H20", "M4 17H20"],
    strokeWidth: 1.5,
  },
  save: {
    d: ["M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z", "M17 21V13H7V21", "M7 3V8H15"],
    strokeWidth: 1.5,
  },
  shuffle: {
    d: ["M16 3H21V8", "M4 20L21 3", "M21 16V21H16", "M15 15L21 21", "M4 4L9 9"],
    strokeWidth: 1.5,
  },
  layoutList: {
    d: ["M0 1H14V3H0Z", "M0 5.75H14V7.75H0Z", "M0 10.5H14V12.5H0Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
  layoutGrid: {
    d: ["M0.5 0.5H5.5V5.5H0.5Z", "M8.5 0.5H13.5V5.5H8.5Z", "M0.5 8.5H5.5V13.5H0.5Z", "M8.5 8.5H13.5V13.5H8.5Z"],
    viewBox: "0 0 14 14",
    strokeWidth: 1,
  },
  layoutCompact: {
    d: ["M0 0.5H14V2H0Z", "M0 4H14V5.5H0Z", "M0 7.5H14V9H0Z", "M0 11H14V12.5H0Z"],
    fill: true,
    viewBox: "0 0 14 14",
  },
};

// ── Presets map ──

const presets: Record<string, GlyphSet> = {
  default: defaultGlyphs,
  rounded: roundedGlyphs,
  minimal: minimalGlyphs,
};

export const glyphPresetNames = Object.keys(presets);
export const glyphNames = Object.keys(defaultGlyphs) as GlyphName[];

// ── Context ──

const GlyphContext = createContext<GlyphSet>(defaultGlyphs);
export const GlyphProvider = GlyphContext.Provider;
export function useGlyphs(): GlyphSet {
  return useContext(GlyphContext);
}

// ── Resolver ──

export function resolveGlyphs(
  preset?: string,
  overrides?: Partial<Record<GlyphName, GlyphDef>>,
): GlyphSet {
  const base = (preset && presets[preset]) ? { ...presets[preset] } : { ...defaultGlyphs };
  if (overrides) {
    for (const [key, val] of Object.entries(overrides)) {
      if (val) base[key as GlyphName] = val;
    }
  }
  return base;
}

// ── Icon component ──

export function Icon({
  name,
  size = 14,
  className,
}: {
  name: GlyphName;
  size?: number;
  className?: string;
}) {
  const glyphs = useContext(GlyphContext);
  const glyph = glyphs[name];
  const viewBox = glyph.viewBox || "0 0 24 24";
  const paths = Array.isArray(glyph.d) ? glyph.d : [glyph.d];
  const isFill = glyph.fill === true;
  const sw = glyph.strokeWidth ?? 2;

  return (
    <svg
      width={size}
      height={size}
      viewBox={viewBox}
      fill={isFill ? "currentColor" : "none"}
      stroke={isFill ? "none" : "currentColor"}
      strokeWidth={isFill ? undefined : sw}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={{ display: "inline-block", verticalAlign: "middle", flexShrink: 0 }}
    >
      {paths.map((d, i) => (
        <path key={i} d={d} />
      ))}
    </svg>
  );
}
