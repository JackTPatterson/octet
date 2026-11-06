import type { ThreadView } from "@t3tools/contracts";

import { agentTerminalCommand } from "./agentTerminal.logic";

/**
 * Flipping a thread between its chat and the agent's own CLI in a terminal. The two are
 * one session, and a session has one driver at a time, so a flip hands it over: the CLI is
 * stopped before the chat takes the session, a running chat turn is stopped before the CLI
 * does, and the CLI's turns are copied into the chat's history on the way back.
 */

/** Whether the agent has a CLI to show. A thread whose agent has none stays a chat. */
export function agentHasCli(driverKind: string | null): boolean {
  return agentTerminalCommand(driverKind, null) !== null;
}

/**
 * The view a thread shows: the preferred one, unless that is a terminal there is no CLI for.
 * A subagent's thread is always the chat: it is a view of what the helper did, not a session
 * of its own to resume in a CLI.
 */
export function effectiveThreadView(
  preferred: ThreadView,
  driverKind: string | null,
  isSubagent = false,
): ThreadView {
  return preferred === "terminal" && (isSubagent || !agentHasCli(driverKind)) ? "chat" : preferred;
}

export function otherThreadView(view: ThreadView): ThreadView {
  return view === "terminal" ? "chat" : "terminal";
}

/**
 * What to type to stop the agent's CLI cleanly: Escape interrupts a turn in progress, then
 * Ctrl+C twice exits (the first only arms the exit). The delays let each key land.
 */
export const STOP_CLI_KEYS: ReadonlyArray<{ readonly data: string; readonly delayMs: number }> = [
  { data: "\u001b", delayMs: 0 },
  { data: "\u0003", delayMs: 200 },
  { data: "\u0003", delayMs: 200 },
];

/** How long to wait for the CLI to exit before handing the session over anyway. */
export const STOP_CLI_TIMEOUT_MS = 6000;

/** Whether the agent terminal has the CLI running: its shell has a child process. */
export function cliIsLive(
  session: {
    readonly state: {
      readonly hasRunningSubprocess: boolean;
      readonly summary: { readonly status: string } | null;
    };
  } | null | undefined,
): boolean {
  return session?.state.summary?.status === "running" && session.state.hasRunningSubprocess;
}

/**
 * Whether to type the CLI's command into the agent terminal as the terminal view opens: the
 * terminal is there but its shell is idle, which is how the CLI was left by a flip to chat.
 * Not within a few seconds of the last launch, so a quick flip back doesn't start it twice.
 */
export function shouldRelaunchCli(input: {
  readonly terminalRunning: boolean;
  readonly cliLive: boolean;
  readonly msSinceLastLaunch: number | null;
}): boolean {
  if (!input.terminalRunning || input.cliLive) return false;
  return input.msSinceLastLaunch === null || input.msSinceLastLaunch > 5000;
}

/** A short line for what the flip to chat brought in, or null when nothing changed. */
export function mirrorNotice(added: number): string | null {
  if (added <= 0) return null;
  return added === 1
    ? "Added 1 message from the CLI to the chat."
    : `Added ${added} messages from the CLI to the chat.`;
}
