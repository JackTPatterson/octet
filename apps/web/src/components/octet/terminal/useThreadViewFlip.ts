import { scopedThreadKey } from "@t3tools/client-runtime/environment";
import type { ScopedThreadRef, ThreadView } from "@t3tools/contracts";
import { useRef, useState } from "react";

import { useStableCallback } from "../../../hooks/useStableCallback";
import { projectEnvironment } from "../../../state/projects";
import { useKnownTerminalSessions } from "../../../state/terminalSessions";
import { useAtomCommand } from "../../../state/use-atom-command";
import { projectScriptCwd } from "@t3tools/shared/projectScripts";
import { loadGhosttyRuntime } from "../../../terminal/ghostty/runtime";
import { useThreadTerminalActions } from "../../terminal/useThreadTerminalActions";
import { toastManager } from "../../ui/toast";
import { AGENT_TERMINAL_ID } from "./agentTerminal.logic";
import { lastCliLaunch, markCliStoppedByFlip } from "./cliLaunches";
import {
  cliIsLive,
  mirrorNotice,
  otherThreadView,
  STOP_CLI_KEYS,
  STOP_CLI_TIMEOUT_MS,
} from "./threadFlip.logic";

/** Threads whose shell was started ahead of a flip, so hovering again starts nothing more. */
const warmed = new Set<string>();

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Flips a thread between its chat and the agent's own CLI. The two are one session, so a
 * flip hands it over (see threadFlip.logic.ts):
 * - to the terminal: a chat turn in progress is stopped first, then the terminal view
 *   resumes the session in the CLI;
 * - to the chat: the CLI is stopped, its turns are copied into the chat's history (and the
 *   thread adopts the CLI's session if it had none), then the chat shows.
 * It never leaves the person stuck: each step that fails or times out is skipped.
 */
export function useThreadViewFlip(input: {
  threadRef: ScopedThreadRef | null;
  driverKind: string | null;
  view: ThreadView;
  setView: (next: ThreadView) => void;
  isWorking: boolean;
  interrupt: () => Promise<unknown>;
  /** Where the agent's terminal runs, so it can be started ahead of a flip. */
  projectRoot: string | null;
  worktreePath: string | null;
}) {
  const { threadRef, driverKind, view, setView, isWorking, interrupt, projectRoot, worktreePath } = input;
  const { writeToTerminal, launchTerminal } = useThreadTerminalActions(threadRef);
  const workingRef = useRef(isWorking);
  workingRef.current = isWorking;
  const sessions = useKnownTerminalSessions({
    environmentId: threadRef?.environmentId ?? null,
    threadId: threadRef?.threadId ?? null,
  });
  const mirrorCli = useAtomCommand(projectEnvironment.mirrorThreadCli, { reportFailure: false });
  const [flipping, setFlipping] = useState(false);
  const busy = useRef(false);

  // Always reads the latest sessions, so polling sees the CLI wind down.
  const agentSession = useStableCallback(
    () => sessions?.find((session) => session.target.terminalId === AGENT_TERMINAL_ID) ?? null,
  );

  const stopCli = async (threadKey: string) => {
    if (!cliIsLive(agentSession())) return;
    markCliStoppedByFlip(threadKey);
    for (const key of STOP_CLI_KEYS) {
      if (key.delayMs > 0) await sleep(key.delayMs);
      await writeToTerminal(AGENT_TERMINAL_ID, key.data);
    }
    const deadline = Date.now() + STOP_CLI_TIMEOUT_MS;
    while (cliIsLive(agentSession()) && Date.now() < deadline) await sleep(150);
  };

  const flipToChat = async (ref: ScopedThreadRef) => {
    const threadKey = scopedThreadKey(ref);
    // Neither step may keep the chat from showing: the person asked to leave the terminal.
    await stopCli(threadKey).catch(() => undefined);
    const launched = lastCliLaunch(threadKey);
    const result = await mirrorCli({
      environmentId: ref.environmentId,
      input: {
        threadId: ref.threadId,
        ...(driverKind ? { driver: driverKind } : {}),
        // A little before the launch, so a log the CLI wrote at startup still counts.
        ...(launched === null ? {} : { sinceMs: Math.max(0, launched - 2000) }),
      },
    }).catch(() => null);
    if (result?._tag === "Success") {
      const notice = mirrorNotice(result.value.added);
      if (notice) toastManager.add({ type: "success", title: notice });
    }
    setView("chat");
  };

  const flipToTerminal = async () => {
    // A chat turn in progress is the SDK's session; the CLI must not resume it mid-write.
    if (isWorking) {
      await interrupt().catch(() => undefined);
      // Go as soon as the turn has settled, not after a fixed wait.
      const settleBy = Date.now() + 600;
      while (workingRef.current && Date.now() < settleBy) await sleep(40);
    }
    setView("terminal");
  };

  /**
   * Start the agent's shell before it is asked for, so a flip to the terminal only has to
   * type the command rather than wait for the shell's startup files. Only the shell: the CLI
   * must not start while the chat still owns the session, and the terminal view types the
   * command (once) when it opens, as it does after a flip that stopped the CLI.
   */
  const warm = useStableCallback(() => {
    if (threadRef === null || projectRoot === null || view !== "chat") return;
    void loadGhosttyRuntime().catch(() => undefined);
    if (sessions === null || sessions.some((s) => s.target.terminalId === AGENT_TERMINAL_ID)) return;
    const key = scopedThreadKey(threadRef);
    if (warmed.has(key)) return;
    warmed.add(key);
    const cwd = projectScriptCwd({ project: { cwd: projectRoot }, worktreePath });
    const launched = launchTerminal({
      place: () => {},
      terminalId: AGENT_TERMINAL_ID,
      location: { cwd, worktreePath },
    });
    if (launched) markCliStoppedByFlip(key);
    else warmed.delete(key);
  });

  const flip = useStableCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    setFlipping(true);
    await (otherThreadView(view) === "chat" && threadRef ? flipToChat(threadRef) : flipToTerminal());
    busy.current = false;
    setFlipping(false);
  });

  return { flip, flipping, warm };
}
