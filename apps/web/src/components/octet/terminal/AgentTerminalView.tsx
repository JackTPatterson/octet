import type { ScopedThreadRef } from "@t3tools/contracts";
import { scopedThreadKey } from "@t3tools/client-runtime/environment";
import { useEffect, useRef } from "react";

import { useKnownTerminalSessions } from "../../../state/terminalSessions";
import { projectScriptCwd, projectScriptRuntimeEnv } from "@t3tools/shared/projectScripts";
import ThreadTerminalDrawer from "../../ThreadTerminalDrawer";
import { useThreadTerminalActions } from "../../terminal/useThreadTerminalActions";
import { agentTerminalCommand, AGENT_TERMINAL_ID } from "./agentTerminal.logic";
import { lastCliLaunch, recordCliLaunch, takeCliStoppedByFlip } from "./cliLaunches";
import { cliIsLive, shouldRelaunchCli } from "./threadFlip.logic";

type DrawerProps = Parameters<typeof ThreadTerminalDrawer>[0];

/**
 * Octet's terminal thread view: the thread's agent running as its own CLI in
 * one of T3's terminals, filling the place of the chat. The terminal is a
 * normal T3 thread terminal, so it keeps running when the view changes and
 * reattaches when it comes back.
 */
export function AgentTerminalView(props: {
  threadRef: ScopedThreadRef;
  projectRoot: string;
  worktreePath: string | null;
  driverKind: string | null;
  providerSessionId: string | null;
  keybindings: DrawerProps["keybindings"];
  onAddTerminalContext: DrawerProps["onAddTerminalContext"];
}) {
  const { threadRef } = props;
  const { launchTerminal, writeToTerminal } = useThreadTerminalActions(threadRef);
  const sessions = useKnownTerminalSessions({
    environmentId: threadRef.environmentId,
    threadId: threadRef.threadId,
  });
  const cwd = projectScriptCwd({
    project: { cwd: props.projectRoot },
    worktreePath: props.worktreePath,
  });
  const runtimeEnv = projectScriptRuntimeEnv({
    project: { cwd: props.projectRoot },
    worktreePath: props.worktreePath,
  });
  const command = agentTerminalCommand(props.driverKind, props.providerSessionId);
  // Once per thread: start the agent unless its terminal is already running.
  const startedFor = useRef<string | null>(null);
  const threadKey = scopedThreadKey(threadRef);

  useEffect(() => {
    if (sessions === null || startedFor.current === threadKey) return;
    startedFor.current = threadKey;
    const existing = sessions.find((session) => session.target.terminalId === AGENT_TERMINAL_ID);
    if (existing && existing.state.summary?.status === "running") {
      // The terminal outlived the CLI: a flip to the chat stopped it so the chat could take
      // the session. Resume it here (the command resumes the thread's session).
      if (
        takeCliStoppedByFlip(threadKey) &&
        command !== null &&
        shouldRelaunchCli({
          terminalRunning: true,
          cliLive: cliIsLive(existing),
          msSinceLastLaunch: (() => {
            const at = lastCliLaunch(threadKey);
            return at === null ? null : Date.now() - at;
          })(),
        })
      ) {
        recordCliLaunch(threadKey);
        void writeToTerminal(AGENT_TERMINAL_ID, `${command}\r`);
      }
      return;
    }
    const launched = launchTerminal({
      place: () => {},
      terminalId: AGENT_TERMINAL_ID,
      location: { cwd, worktreePath: props.worktreePath },
    });
    if (!launched || command === null) return;
    void launched.result.then((result) => {
      if (result._tag !== "Success") return;
      recordCliLaunch(threadKey);
      void writeToTerminal(AGENT_TERMINAL_ID, `${command}\r`);
    });
  }, [sessions, threadKey, launchTerminal, writeToTerminal, cwd, props.worktreePath, command]);

  return (
    // Inset like a terminal window, in the terminal's own colour, so the text
    // doesn't run into the edges of the view.
    <div
      data-testid="octet-agent-terminal"
      className="relative flex min-h-0 min-w-0 flex-1 flex-col bg-(--terminal-background) px-4 pt-3 pb-2"
    >
      <ThreadTerminalDrawer
        mode="panel"
        hideActions
        visible
        threadRef={threadRef}
        threadId={threadRef.threadId}
        cwd={cwd}
        worktreePath={props.worktreePath}
        runtimeEnv={runtimeEnv}
        height={0}
        terminalIds={[AGENT_TERMINAL_ID]}
        activeTerminalId={AGENT_TERMINAL_ID}
        terminalGroups={[{ id: AGENT_TERMINAL_ID, terminalIds: [AGENT_TERMINAL_ID] }]}
        activeTerminalGroupId={AGENT_TERMINAL_ID}
        onSplitTerminal={() => {}}
        onSplitTerminalVertical={() => {}}
        onNewTerminal={() => {}}
        onActiveTerminalChange={() => {}}
        onCloseTerminal={() => {}}
        onHeightChange={() => undefined}
        onAddTerminalContext={props.onAddTerminalContext}
        terminalLabelsById={new Map([[AGENT_TERMINAL_ID, "Agent"]])}
        terminalLaunchLocationsById={
          new Map([[AGENT_TERMINAL_ID, { cwd, worktreePath: props.worktreePath, runtimeEnv }]])
        }
        keybindings={props.keybindings}
      />
    </div>
  );
}
