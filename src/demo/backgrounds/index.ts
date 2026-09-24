import type { ProceduralEntry } from "./types";
import { createOrbs } from "./orbs";
import { createAurora } from "./aurora";
import { createParticles } from "./particles";
import { createStarfield } from "./starfield";
import { createMesh } from "./mesh";
import { createBokeh } from "./bokeh";
import { createWaves } from "./waves";
import { createNoise } from "./noise";

export const PROCEDURAL_REGISTRY: Record<string, ProceduralEntry> = {
  orbs: {
    label: "Floating Orbs",
    optionDefs: {
      count: { type: "number", label: "Count", min: 3, max: 20, step: 1, default: 8 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 2, step: 0.1, default: 0.5 },
      minSize: { type: "number", label: "Min Size", min: 20, max: 200, step: 10, default: 60 },
      maxSize: { type: "number", label: "Max Size", min: 50, max: 400, step: 10, default: 200 },
      colors: { type: "colors", label: "Colors", default: "#cc3333,#4a9eff,#4daa5c,#e06088" },
      blur: { type: "number", label: "Blur", min: 0, max: 60, step: 5, default: 30 },
    },
    create: createOrbs,
  },
  aurora: {
    label: "Aurora",
    optionDefs: {
      bands: { type: "number", label: "Bands", min: 2, max: 8, step: 1, default: 4 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 3, step: 0.1, default: 0.5 },
      colors: { type: "colors", label: "Colors", default: "#00ff88,#4a9eff,#cc3333,#e06088" },
      intensity: { type: "number", label: "Intensity", min: 0.1, max: 1, step: 0.05, default: 0.6 },
    },
    create: createAurora,
  },
  particles: {
    label: "Particles",
    optionDefs: {
      count: { type: "number", label: "Count", min: 20, max: 300, step: 10, default: 80 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 3, step: 0.1, default: 0.5 },
      size: { type: "number", label: "Size", min: 1, max: 6, step: 0.5, default: 2 },
      color: { type: "colors", label: "Color", default: "#ffffff" },
      lines: { type: "boolean", label: "Connection Lines", default: true },
      lineDistance: { type: "number", label: "Line Distance", min: 50, max: 300, step: 10, default: 120 },
    },
    create: createParticles,
  },
  starfield: {
    label: "Starfield",
    optionDefs: {
      count: { type: "number", label: "Count", min: 50, max: 500, step: 10, default: 200 },
      twinkle: { type: "boolean", label: "Twinkle", default: true },
      sizeRange: { type: "number", label: "Size Range", min: 0.5, max: 4, step: 0.5, default: 2 },
      drift: { type: "number", label: "Drift", min: 0, max: 1, step: 0.05, default: 0.1 },
      colored: { type: "boolean", label: "Colored", default: false },
    },
    create: createStarfield,
  },
  mesh: {
    label: "Mesh Gradient",
    optionDefs: {
      colors: { type: "colors", label: "Colors", default: "#cc3333,#4a9eff,#4daa5c,#e06088" },
      speed: { type: "number", label: "Speed", min: 0.1, max: 2, step: 0.1, default: 0.3 },
      blobSize: { type: "number", label: "Blob Size", min: 0.3, max: 1, step: 0.05, default: 0.6 },
    },
    create: createMesh,
  },
  bokeh: {
    label: "Bokeh",
    optionDefs: {
      count: { type: "number", label: "Count", min: 5, max: 40, step: 1, default: 15 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 2, step: 0.1, default: 0.3 },
      sizeRange: { type: "number", label: "Size Range", min: 20, max: 150, step: 10, default: 60 },
      colors: { type: "colors", label: "Colors", default: "#cc3333,#4a9eff,#e06088,#ffffff" },
    },
    create: createBokeh,
  },
  waves: {
    label: "Waves",
    optionDefs: {
      layers: { type: "number", label: "Layers", min: 2, max: 8, step: 1, default: 4 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 3, step: 0.1, default: 0.5 },
      amplitude: { type: "number", label: "Amplitude", min: 10, max: 200, step: 10, default: 60 },
      colors: { type: "colors", label: "Colors", default: "#cc3333,#4a9eff,#4daa5c" },
      position: { type: "number", label: "Position", min: 0, max: 1, step: 0.05, default: 0.7 },
    },
    create: createWaves,
  },
  noise: {
    label: "Film Grain",
    optionDefs: {
      scale: { type: "number", label: "Scale", min: 1, max: 10, step: 1, default: 4 },
      speed: { type: "number", label: "Speed", min: 0.1, max: 5, step: 0.1, default: 2 },
      intensity: { type: "number", label: "Intensity", min: 0.01, max: 0.3, step: 0.01, default: 0.05 },
      monochrome: { type: "boolean", label: "Monochrome", default: true },
    },
    create: createNoise,
  },
};

export type { BgRenderer, BgRendererFactory, OptionDef, ProceduralEntry } from "./types";
