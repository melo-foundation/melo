export const GESTURE_IDS = [
  "playerBar.doubleClick",
  "compact.escape",
  "titleBar.doubleClick",
] as const;
export type GestureId = typeof GESTURE_IDS[number];

export interface CommandDecl {
  id: string;
  label: string;
  default?: string;
}

export const BUILTIN_KEY_DEFAULTS: Record<string, string> = {
  toggleSearch: "ctrl+KeyF",
  playPause: "Space",
  rewind: "ArrowLeft",
  forward: "ArrowRight",
  nextTrack: "KeyN",
  prevTrack: "KeyP",
  prevTrackAlt: "Backspace",
  deleteTrack: "shift+Delete",
  addToLibrary: "KeyL",
  uiLock: "ctrl+shift+KeyL",
  bgPresetNext: "BracketRight",
  bgPresetPrev: "BracketLeft",
};

const GESTURE_SET = new Set<string>(GESTURE_IDS);
const BUILTIN_KEY_SET = new Set(Object.values(BUILTIN_KEY_DEFAULTS));

export function validateCommands(raw: unknown):
    { commands: CommandDecl[]; error: string | null } {
  if (raw === undefined || raw === null) return { commands: [], error: null };
  if (!Array.isArray(raw))
    return { commands: [], error: "commands must be an array" };

  const commands: CommandDecl[] = [];
  const ids = new Set<string>();
  for (const value of raw) {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return { commands: [], error: "commands entries must be objects" };
    const command = value as Record<string, unknown>;
    if (typeof command.id !== "string" || !/^[a-z][a-zA-Z0-9]*$/.test(command.id))
      return { commands: [], error: `command id must be a slug: ${String(command.id)}` };
    if (ids.has(command.id))
      return { commands: [], error: `duplicate command id: ${command.id}` };
    if (typeof command.label !== "string" || command.label.length === 0)
      return { commands: [], error: `command ${command.id}: label must be a non-empty string` };
    if (command.default !== undefined && typeof command.default !== "string")
      return { commands: [], error: `command ${command.id}: default must be a string` };
    if (typeof command.default === "string" && command.default.includes(".")
        && !GESTURE_SET.has(command.default))
      return { commands: [], error: `command ${command.id}: unknown gesture: ${command.default}` };

    const out: CommandDecl = { id: command.id, label: command.label };
    if (typeof command.default === "string") out.default = command.default;
    commands.push(out);
    ids.add(command.id);
  }
  return { commands, error: null };
}

export function commandLoadWarnings(
  pluginId: string,
  commands: CommandDecl[],
  takenKeys: Set<string>,
): string[] {
  const warnings: string[] = [];
  for (const command of commands) {
    const key = command.default ?? "";
    if (key === "" || GESTURE_SET.has(key)) continue;
    if (BUILTIN_KEY_SET.has(key) || takenKeys.has(key)) {
      warnings.push(`${pluginId}.${command.id}: default key already taken`);
      command.default = "";
      continue;
    }
    takenKeys.add(key);
  }
  return warnings;
}
