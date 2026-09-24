import { writeFileSync, renameSync, existsSync, copyFileSync, unlinkSync, mkdirSync } from "fs";
import { dirname, basename, join } from "path";

/**
 * Write a file so that an interrupted write cannot destroy the old one.
 *
 * writeFileSync truncates in place, and a truncated library or settings file
 * loads as empty/defaults, which the next save makes permanent. The sidecar is
 * SIGKILLed at shutdown, so a normal quit can interrupt a write. The temp file
 * sits in the same directory because rename is only atomic within a
 * filesystem. Same contract as ThemeStore::writeUserTheme (QSaveFile).
 */
export function writeFileAtomic(path: string, data: string, mode = 0o600): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  try {
    writeFileSync(tmp, data, { mode });
    renameSync(tmp, path);
  } catch (e) {
    try { if (existsSync(tmp)) unlinkSync(tmp); } catch { /* nothing to clean */ }
    throw e;
  }
}

/**
 * Keep one generation back, so a file that is corrupt for a reason a rename
 * cannot prevent — a disk error, a second instance writing concurrently — is
 * still recoverable rather than silently replaced by an empty one.
 */
export function backupOnce(path: string): void {
  if (!existsSync(path)) return;
  try { copyFileSync(path, path + ".bak"); } catch { /* best effort */ }
}

/** True when a .bak exists to fall back to. */
export function backupPath(path: string): string | null {
  const b = path + ".bak";
  return existsSync(b) ? b : null;
}
