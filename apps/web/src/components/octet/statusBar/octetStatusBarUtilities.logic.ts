/**
 * The status bar's right-hand utilities: keeping the host awake while agents work, and the
 * memory Octet and its terminals use (native Octet's FooterStatus). This file decides what
 * they say; OctetStatusBar draws them with T3's classes.
 */

export type KeepAwakeMode = "off" | "plugged_in" | "always";
type BackgroundBoolean = "true" | "false" | "unknown";

export const KEEP_AWAKE_MODES: ReadonlyArray<{
  readonly mode: KeepAwakeMode;
  readonly title: string;
  readonly detail: string;
}> = [
  { mode: "off", title: "Off", detail: "Let the computer sleep as usual" },
  { mode: "plugged_in", title: "While agents work, on power", detail: "Sleeps on battery" },
  {
    mode: "always",
    title: "While agents work, on battery too",
    detail: "The display can still sleep",
  },
];

/** The chip's short word for the mode. */
export function keepAwakeChipLabel(mode: KeepAwakeMode): string {
  switch (mode) {
    case "off":
      return "Off";
    case "plugged_in":
      return "Auto";
    case "always":
      return "Agents";
  }
}

/**
 * Whether the host should be held awake: only while an agent works, and in "plugged_in" mode
 * only off battery (an unknown power source counts as plugged in, as on a desktop).
 */
export function shouldHoldAwake(input: {
  readonly mode: KeepAwakeMode;
  readonly workingAgents: number;
  readonly onBattery: BackgroundBoolean;
}): boolean {
  if (input.workingAgents <= 0) return false;
  if (input.mode === "always") return true;
  return input.mode === "plugged_in" && input.onBattery !== "true";
}

export function keepAwakeChipTitle(mode: KeepAwakeMode, holding: boolean): string {
  const state = holding ? "Holding the computer awake now" : "Not holding the computer awake";
  return mode === "off" ? `Keep awake is off\n${state}` : `Keep awake while agents work\n${state}`;
}

/** "812.4 MB", "1.37 GB": resident memory as native Octet's footer prints it. */
export function formatFootprint(bytes: number): string {
  const mb = bytes / 1_048_576;
  return mb >= 1024 ? `${(mb / 1024).toFixed(2)} GB` : `${mb.toFixed(1)} MB`;
}

export function memoryChipTitle(bytes: number | null, terminals: number): string {
  const count = `${terminals} ${terminals === 1 ? "terminal" : "terminals"} open`;
  return bytes === null
    ? `Memory use is loading\n${count}`
    : `Octet and its processes use ${formatFootprint(bytes)}\n${count}`;
}
