// Running melo's QML JavaScript under node. src/qml/components/*.js are plain
// scripts QML concatenates into an engine scope, with no exports, so they are
// evaluated in a vm context with the QML globals they touch stubbed. Tests read
// the context's properties: the shipped text, not a copy.

import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import vm from "vm";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..", "..");

export interface QmlRect { x: number; y: number; width: number; height: number }
export interface QmlPoint { x: number; y: number }

// Qt.rect/Qt.point as QML hands them out: plain value objects. Enough for
// Coords.js, which is the only file that touches Qt at all.
const Qt = {
  rect: (x: number, y: number, width: number, height: number): QmlRect =>
    ({ x, y, width, height }),
  point: (x: number, y: number): QmlPoint => ({ x, y }),
};

export interface LoadedScript {
  /** everything the script declared, by name */
  globals: Record<string, unknown>;
  /** console.warn / console.error text, in order */
  warnings: string[];
}

// Evaluates one of melo's QML JavaScript libraries, so a test reads the text
// the shell ships rather than a copy of it.

export function loadQmlJsFrom(dir: string, file: string): LoadedScript {
  const warnings: string[] = [];
  const record = (...a: unknown[]) => { warnings.push(a.join(" ")); };
  const sandbox: Record<string, unknown> = {
    Qt,
    console: { log: () => {}, warn: record, error: record },
  };
  const seeded = new Set(Object.keys(sandbox));
  vm.createContext(sandbox);
  // A QML JavaScript library may open with directives — `.pragma library`,
  // `.import` — which the QML engine consumes before the script is script at
  // all. They are not JavaScript and node will not parse them. Blanked rather
  // than dropped, so every line number still matches the file on disk.
  const text = readFileSync(join(dir, file), "utf8")
    .replace(/^\s*\.(pragma|import)[^\n]*/gm, "");
  vm.runInContext(text, sandbox, { filename: file });
  const globals: Record<string, unknown> = {};
  for (const key of Object.keys(sandbox))
    if (!seeded.has(key)) globals[key] = sandbox[key];
  return { globals, warnings };
}
