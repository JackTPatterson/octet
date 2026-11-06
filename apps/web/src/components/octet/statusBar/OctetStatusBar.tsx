import { resolveThreadProviderStack } from "@t3tools/client-runtime/state/models";
import { sourceControlClients } from "@t3tools/client-runtime/source-control-clients";
import { selectEnvironmentQueryData } from "@t3tools/client-runtime/state/runtime";
import type { EnvironmentProject } from "@t3tools/client-runtime/state/shell";
import type { ProjectId, PullRequestRef, ScopedThreadRef } from "@t3tools/contracts";
import {
  CoffeeIcon,
  FileDiffIcon,
  FolderGit2Icon,
  FolderIcon,
  GitBranchIcon,
  GlobeIcon,
  MemoryStickIcon,
  TerminalIcon,
} from "lucide-react";
import { Fragment, useState, type ReactNode } from "react";

import { cn } from "~/lib/utils";
import { useResourceTelemetry } from "../../../lib/resourceTelemetryState";
import { serverEnvironment } from "../../../state/server";
import { updateClientSettings, useClientSettings } from "../../../hooks/useSettings";
import { useKnownTerminalSessions } from "../../../state/terminalSessions";
import { Menu, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuTrigger } from "../../ui/menu";
import { AGENT_TERMINAL_ID } from "../terminal/agentTerminal.logic";
import { StatusBarItemsMenuItems } from "./StatusBarItemsMenu";
import { isEndGroup, visibleStatusBarItems, type StatusBarItemId } from "./octetStatusBarItems";
import { useThreadDiscoveredPorts } from "../../../portDiscoveryState";
import { useRightPanelStore } from "../../../rightPanelStore";
import { useServerConfigs, useQuietThreadShell, useQuietThreadShells } from "../../../state/entities";
import { previewEnvironment } from "../../../state/preview";
import { pullRequestEnvironment } from "../../../state/pullRequests";
import { useEnvironmentQuery, useEnvironmentQuerySelector } from "../../../state/query";
import { useAtomCommand } from "../../../state/use-atom-command";
import { vcsEnvironment } from "../../../state/vcs";
import { projectEnvironment } from "../../../state/projects";
import { SERVICE_ICON_PATHS } from "../sidebar/serviceIconPaths";
import { resolveSidebarThreadStatus, resolveThreadStatusPill } from "../../Sidebar.logic";
import { useSidebarLookups } from "../../Sidebar";
import { PullRequestChecksPopover } from "../../pullRequest/PullRequestChecksPopover";
import { openDiscoveredPort } from "../../preview/openDiscoveredPort";
import {
  PullRequestDiffStat,
  resolvePullRequestState,
} from "../../pullRequest/pullRequestPresentation";
import { SidebarProviderStack } from "../../sidebar/SidebarThreadRow";
import {
  agentChipState,
  agentChipText,
  changesChip,
  changesChipTitle,
  ciChip,
  directoryChipLabel,
  portsChip,
  portsChipText,
  runtimeIconSlug,
  worktreeChipLabel,
} from "./octetStatusBar.logic";
import {
  formatFootprint,
  KEEP_AWAKE_MODES,
  keepAwakeChipLabel,
  keepAwakeChipTitle,
  memoryChipTitle,
  shouldHoldAwake,
  type KeepAwakeMode,
} from "./octetStatusBarUtilities.logic";

/** One footer item: a quiet run of icon and text, filled only on hover. */
const CHIP_CLASS =
  "inline-flex h-6 shrink-0 items-center gap-1.5 rounded-md px-2 text-xs tabular-nums text-muted-foreground";
const LINK_CHIP_CLASS = cn(
  CHIP_CLASS,
  "cursor-pointer transition-colors hover:bg-accent/50 hover:text-foreground",
);

function Divider() {
  return <span aria-hidden className="mx-1 h-3 w-px shrink-0 bg-border" />;
}

/**
 * Octet's footer under the thread: what the agent is doing, the branch, the
 * working tree's size, and CI. Native Octet's status bar, drawn with T3's
 * classes and parts. Each chip hides until it has something to say.
 */
export function OctetStatusBar(props: {
  threadRef: ScopedThreadRef;
  /** The folder git runs in: the worktree, else the project root. */
  cwd: string | null;
  project: EnvironmentProject | null;
}) {
  const { threadRef, cwd, project } = props;
  const shell = useQuietThreadShell(threadRef);
  const { providerEntriesByEnvironment } = useSidebarLookups();
  const gitStatus = useEnvironmentQuery(
    cwd === null
      ? null
      : vcsEnvironment.status({
          environmentId: threadRef.environmentId,
          input: { cwd },
        }),
  ).data;
  const runtime = useEnvironmentQuery(
    cwd === null
      ? null
      : projectEnvironment.runtimeVersion({
          environmentId: threadRef.environmentId,
          input: { cwd },
        }),
  ).data?.runtime;
  const providerEntries = providerEntriesByEnvironment.get(threadRef.environmentId);
  const instanceId = shell ? resolveThreadProviderStack(shell).at(-1) : undefined;
  const isClaudeThread =
    (instanceId ? providerEntries?.get(instanceId)?.driverKind : undefined) === "claudeAgent";
  // Remote Control is the Claude CLI's, so it is only asked of a Claude thread's terminal.
  const agentTerminals = useKnownTerminalSessions({
    environmentId: threadRef.environmentId,
    threadId: threadRef.threadId,
  });
  const agentTerminalPid =
    agentTerminals?.find((session) => session.target.terminalId === AGENT_TERMINAL_ID)?.state
      .summary?.pid ?? null;
  const remote = useEnvironmentQuery(
    cwd === null || agentTerminalPid === null || !isClaudeThread
      ? null
      : projectEnvironment.remoteControl({
          environmentId: threadRef.environmentId,
          input: { cwd, pid: agentTerminalPid },
        }),
  ).data;
  const openPanel = useRightPanelStore((store) => store.open);
  const openPullRequest = useRightPanelStore((store) => store.openPullRequest);
  const openPreview = useAtomCommand(previewEnvironment.open, { reportFailure: false });
  const servers = useThreadDiscoveredPorts({
    environmentId: threadRef.environmentId,
    threadId: threadRef.threadId,
  });
  const ports = portsChip(servers);

  // The right-hand utilities: memory, and holding the host awake while agents work.
  const telemetry = useResourceTelemetry(threadRef.environmentId).data;
  const footprintBytes = telemetry?.groups.allT3.currentRssBytes ?? null;
  const terminalCount = useKnownTerminalSessions({
    environmentId: threadRef.environmentId,
    threadId: null,
  })?.length ?? 0;
  const allShells = useQuietThreadShells();
  const workingAgents = allShells.filter(
    (candidate) =>
      candidate.environmentId === threadRef.environmentId &&
      resolveSidebarThreadStatus(candidate as never) === "working",
  ).length;
  const keepAwakeMode: KeepAwakeMode = useClientSettings((current) => current.keepAwake);
  const hold = shouldHoldAwake({
    mode: keepAwakeMode,
    workingAgents,
    onBattery: telemetry?.power.onBattery ?? "unknown",
  });
  // Asked again every few seconds: the server's assertion is a short lease that lapses with the asks.
  const keepAwake = useEnvironmentQuery(
    serverEnvironment.keepAwake({ environmentId: threadRef.environmentId, input: { hold } }),
  ).data;

  const providerName =
    (instanceId ? providerEntries?.get(instanceId)?.displayName : undefined) ?? "Agent";
  const agentState = agentChipState(
    shell ? resolveThreadStatusPill({ thread: shell as never }) : null,
  );

  const changes = changesChip(gitStatus?.isRepo ? gitStatus.workingTree : null);
  const branch = gitStatus?.isRepo ? gitStatus.refName : null;
  const pr = gitStatus?.pr ?? null;

  const serverConfigs = useServerConfigs();
  const supportsChecks =
    serverConfigs.get(threadRef.environmentId)?.environment.capabilities.pullRequestChecks === true;
  const repository = sourceControlClients.repositorySelector(project?.repositoryIdentity);
  const prReference: PullRequestRef | null =
    project !== null && repository !== null && pr !== null
      ? { projectId: project.id as ProjectId, repository, number: pr.number }
      : null;
  const reference = supportsChecks ? prReference : null;
  const checksAtom =
    reference === null
      ? null
      : pullRequestEnvironment.checks({ environmentId: threadRef.environmentId, input: reference });
  const checksData = useEnvironmentQuerySelector(checksAtom, selectEnvironmentQueryData);
  const ci = ciChip(checksData?.checks ?? null);

  const chips: Partial<Record<StatusBarItemId, ReactNode>> = {};
  if (remote?.active) {
    chips.remoteControl = (
      <a
        key="remote"
        className={LINK_CHIP_CLASS}
        href={remote.url ?? undefined}
        target="_blank"
        rel="noreferrer"
        title={`Remote Control is on${remote.url ? `\n${remote.url}\nClick to open it` : ""}`}
      >
        <span aria-hidden className="size-1.5 rounded-full bg-emerald-500" />
        <span>Remote</span>
      </a>
    );
  }
  chips.agent = (
    <span key="agent" className={CHIP_CLASS} title={agentChipText(providerName, agentState)}>
      {shell && providerEntries ? (
        <SidebarProviderStack thread={shell as never} providerEntryByInstanceId={providerEntries} />
      ) : null}
      <span className={cn(agentState === "needs-you" && "text-amber-600 dark:text-amber-300/90")}>
        {agentChipText(providerName, agentState)}
      </span>
    </span>
  );
  if (runtime) {
    const slug = runtimeIconSlug(runtime.id);
    const iconPath = slug ? SERVICE_ICON_PATHS[slug] : undefined;
    chips.runtime = (
      <span key="runtime"
        className={CHIP_CLASS}
        title={`${runtime.name} ${runtime.version}, the version that runs in this folder`}
      >
        {iconPath ? (
          <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden className="size-3.5">
            <path d={iconPath} />
          </svg>
        ) : null}
        <span className="font-mono">{runtime.version}</span>
      </span>
    );
  }
  if (cwd) {
    chips.directory = (
      <button key="directory"
        type="button"
        className={LINK_CHIP_CLASS}
        title={`${cwd}\nClick to show the project's files`}
        onClick={() => openPanel(threadRef, "files")}
      >
        <FolderIcon aria-hidden className="size-3.5" />
        <span className="max-w-56 truncate font-mono">{directoryChipLabel(cwd)}</span>
      </button>
    );
  }
  if (branch) {
    chips.branch = (
      <span key="branch" className={CHIP_CLASS} title={`Branch ${branch}`}>
        <GitBranchIcon aria-hidden className="size-3.5" />
        <span className="max-w-56 truncate font-mono">{branch}</span>
      </span>
    );
  }
  const worktree = worktreeChipLabel(shell?.worktreePath);
  if (worktree) {
    chips.worktree = (
      <span key="worktree" className={CHIP_CLASS} title={`Worktree at ${shell?.worktreePath}`}>
        <FolderGit2Icon aria-hidden className="size-3.5" />
        <span className="max-w-40 truncate">{worktree}</span>
      </span>
    );
  }
  if (changes) {
    chips.changes = (
      <button key="changes"
        type="button"
        className={LINK_CHIP_CLASS}
        title={`${changesChipTitle(changes)}\nClick to show the diff`}
        onClick={() => openPanel(threadRef, "diff")}
      >
        <FileDiffIcon aria-hidden className="size-3.5" />
        <span>{changes.files}</span>
        <PullRequestDiffStat additions={changes.insertions} deletions={changes.deletions} />
      </button>
    );
  }
  if (pr && prReference) {
    const state = resolvePullRequestState({ state: pr.state, isDraft: pr.isDraft ?? false });
    chips.pullRequest = (
      <button key="pull-request"
        type="button"
        className={LINK_CHIP_CLASS}
        title={`${pr.title}\n${state.label}\nClick to show the pull request`}
        onClick={() =>
          openPullRequest(threadRef, {
            projectId: prReference.projectId,
            repository: prReference.repository,
            number: prReference.number,
          })
        }
      >
        <state.Icon aria-hidden className={cn("size-3.5", state.toneClassName)} />
        <span>#{pr.number}</span>
      </button>
    );
  }
  if (ci && checksData && reference) {
    const failing = ci.state === "failed";
    chips.ci = (
      <PullRequestChecksPopover key="ci"
        checksState={failing ? "failing" : ci.state === "running" ? "pending" : "passing"}
        checks={checksData.checks}
        threadRef={threadRef}
        variant="count"
        render={
          <button
            type="button"
            className={cn(LINK_CHIP_CLASS, failing && "text-destructive hover:text-destructive")}
          />
        }
      />
    );
  }

  if (ports) {
    const [first] = servers;
    chips.ports = (
      <button key="ports"
        type="button"
        className={LINK_CHIP_CLASS}
        title={`Servers this thread started\nClick to open ${first?.url ?? "the first"} in the browser panel`}
        onClick={() => {
          if (first) void openDiscoveredPort({ threadRef, port: first, openPreview });
        }}
      >
        <GlobeIcon aria-hidden className="size-3.5" />
        <span className="font-mono">{portsChipText(ports)}</span>
      </button>
    );
  }

  if (keepAwake?.supported) {
    const holding = hold && keepAwake.holding;
    chips.awake = (
      <Menu key="awake">
        <MenuTrigger
          className={LINK_CHIP_CLASS}
          title={keepAwakeChipTitle(keepAwakeMode, holding)}
          aria-label={`Keep awake: ${keepAwakeChipLabel(keepAwakeMode)}, ${holding ? "active" : "inactive"}`}
        >
          <CoffeeIcon aria-hidden className="size-3.5" />
          <span>{keepAwakeChipLabel(keepAwakeMode)}</span>
          <span
            aria-hidden
            className={cn("size-1.5 rounded-full", holding ? "bg-emerald-500" : "bg-muted-foreground/30")}
          />
        </MenuTrigger>
        <MenuPopup align="end" side="top">
          <MenuRadioGroup
            value={keepAwakeMode}
            onValueChange={(value) => void updateClientSettings({ keepAwake: value as KeepAwakeMode })}
          >
            {KEEP_AWAKE_MODES.map((option) => (
              <MenuRadioItem key={option.mode} value={option.mode} closeOnClick>
                <span className="flex flex-col">
                  <span>{option.title}</span>
                  <span className="text-xs text-muted-foreground">{option.detail}</span>
                </span>
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    );
  }
  chips.memory = (
    <span key="memory" className={CHIP_CLASS} title={memoryChipTitle(footprintBytes, terminalCount)}>
      <MemoryStickIcon aria-hidden className="size-3.5" />
      <span>{footprintBytes === null ? "—" : formatFootprint(footprintBytes)}</span>
      <TerminalIcon aria-hidden className="ml-1 size-3.5" />
      <span>{terminalCount}</span>
    </span>
  );

  const settings = useClientSettings((current) => ({
    statusBarItems: current.statusBarItems,
    statusBarOrder: current.statusBarOrder,
  }));
  const [menuPosition, setMenuPosition] = useState<{ x: number; y: number } | null>(null);
  const rendered: ReactNode[] = [];
  const renderedEnd: ReactNode[] = [];
  let previousGroup: string | null = null;
  for (const item of visibleStatusBarItems(settings)) {
    const chip = chips[item.id];
    if (!chip) continue;
    // The utilities sit at the right edge, outside the scrolling run of chips.
    if (isEndGroup(item.group)) {
      renderedEnd.push(<Fragment key={item.id}>{chip}</Fragment>);
      continue;
    }
    if (previousGroup !== null && previousGroup !== item.group) {
      rendered.push(<Divider key={`divider-${item.id}`} />);
    }
    previousGroup = item.group;
    rendered.push(<Fragment key={item.id}>{chip}</Fragment>);
  }

  return (
    <footer
      aria-label="Status bar"
      data-octet-status-bar=""
      className="flex h-[30px] shrink-0 items-center gap-0.5 border-t border-border/60 px-2"
      onContextMenu={(event) => {
        event.preventDefault();
        setMenuPosition({ x: event.clientX, y: event.clientY });
      }}
    >
      <div className="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto [scrollbar-width:none]">
        {rendered}
      </div>
      {renderedEnd.length > 0 ? (
        <div className="flex shrink-0 items-center gap-0.5">{renderedEnd}</div>
      ) : null}
      <Menu open={menuPosition !== null} onOpenChange={(open) => !open && setMenuPosition(null)}>
        <MenuPopup
          anchor={
            menuPosition
              ? { getBoundingClientRect: () => new DOMRect(menuPosition.x, menuPosition.y, 0, 0) }
              : undefined
          }
          align="start"
          side="top"
        >
          <StatusBarItemsMenuItems />
        </MenuPopup>
      </Menu>
    </footer>
  );
}
