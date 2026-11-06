/**
 * Whether a Claude Code session has Remote Control on, from its session log.
 * `/remote-control` writes a `bridge_status` record with the session's claude.ai link
 * when it connects; run again, it turns Remote Control off and writes only the command.
 * Records from before the Claude process started belong to an earlier run of a resumed
 * session. A port of native Octet's `RemoteControlLog`.
 */
export interface RemoteControlState {
  readonly url: string | null;
  readonly isOn: boolean;
  /** A `/remote-control` seen while on: off, unless it reconnects. */
  readonly toggledWhileOn: boolean;
}

export const INITIAL_REMOTE_CONTROL_STATE: RemoteControlState = {
  url: null,
  isOn: false,
  toggledWhileOn: false,
};

/** Folds in one log line; `sinceMs` is when the Claude process started. */
export function consumeRemoteControlLine(
  state: RemoteControlState,
  line: string,
  sinceMs: number | null,
): RemoteControlState {
  // Most lines are neither; skip them before parsing.
  if (!line.includes("bridge_status") && !line.includes("remote-control")) return state;
  let record: unknown;
  try {
    record = JSON.parse(line);
  } catch {
    return state;
  }
  if (typeof record !== "object" || record === null) return state;
  const fields = record as Record<string, unknown>;
  if (fields.type !== "system") return state;
  if (sinceMs !== null && typeof fields.timestamp === "string") {
    const at = Date.parse(fields.timestamp);
    if (Number.isFinite(at) && at < sinceMs) return state;
  }
  switch (fields.subtype) {
    case "bridge_status":
      return {
        url: typeof fields.url === "string" ? fields.url : state.url,
        isOn: true,
        toggledWhileOn: false,
      };
    case "local_command": {
      const run = fields.commandRun;
      const command =
        typeof run === "object" && run !== null
          ? (run as Record<string, unknown>).command
          : undefined;
      if (command !== "remote-control" && command !== "rc") return state;
      // The command's echo comes first; its bridge_status (if it connected) follows.
      // A toggle that isn't followed by one is off.
      if (!state.isOn) return state;
      return state.toggledWhileOn
        ? { url: null, isOn: false, toggledWhileOn: true }
        : { ...state, toggledWhileOn: true };
    }
    default:
      return state;
  }
}

/** On as of the lines read so far. */
export function remoteControlActive(state: RemoteControlState): boolean {
  return state.isOn && !state.toggledWhileOn;
}

export function foldRemoteControlLog(
  text: string,
  sinceMs: number | null,
): { readonly active: boolean; readonly url: string | null } {
  let state = INITIAL_REMOTE_CONTROL_STATE;
  for (const line of text.split("\n")) state = consumeRemoteControlLine(state, line, sinceMs);
  const active = remoteControlActive(state);
  return { active, url: active ? state.url : null };
}
