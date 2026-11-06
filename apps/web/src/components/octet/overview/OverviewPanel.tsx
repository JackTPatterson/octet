import { useAtomValue } from "@effect/atom-react";
import type {
  OrchestrationV2PendingBackgroundTask,
  ScopedThreadRef,
  ThreadId,
} from "@t3tools/contracts";
import { presentPendingBackgroundWork } from "@t3tools/client-runtime/state/thread-execution";
import { summarizeSubagentStatuses } from "@t3tools/client-runtime/state/subagent-display";
import { formatDuration } from "@t3tools/shared/orchestrationTiming";
import * as DateTime from "effect/DateTime";
import {
  BotIcon,
  ChevronDownIcon,
  CircleDashedIcon,
  CircleStopIcon,
  RadarIcon,
  TerminalIcon,
  type LucideIcon,
} from "lucide-react";
import { useState, type ComponentProps } from "react";

import { cn } from "~/lib/utils";
import { environmentThreadDetails } from "../../../state/threads";
import { tickTextContent } from "~/lib/tickTextContent";
import { subagentGroupTiming } from "../../chat/TimelineV2EventRow.logic";
import {
  EnvironmentSubagentAvatar,
  SubagentElapsed,
  V2LifecycleRow,
} from "../../chat/V2LifecycleRow";
import { Button } from "../../ui/button";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger } from "../../ui/collapsible";
import { CollapsibleSectionHeader } from "../../ui/collapsible-section-header";
import {
  backgroundTasks,
  buildOverviewTree,
  countOverviewNodes,
  hasWorkingSubagent,
  subagentItems,
  type OverviewNode,
} from "./overview.logic";

type LifecycleItem = ComponentProps<typeof V2LifecycleRow>["item"];
type PendingTask = OrchestrationV2PendingBackgroundTask;

const KIND_ICON: Record<PendingTask["kind"], LucideIcon> = {
  subagent: BotIcon,
  command: TerminalIcon,
  monitor: RadarIcon,
  background_task: CircleDashedIcon,
};

/** The card T3 puts around a group's rows in the timeline. */
const CARD_CLASS = "mt-1 mb-1 rounded-lg border border-border/60 bg-card/30 p-1";

/**
 * Octet's Overview plane: the thread's agent, its subagents (the group
 * header and rows T3 draws in the timeline), and the background commands and
 * monitors it has running. Everything here is T3's own component or class
 * set, so it reads like the rest of the panel.
 */
export function OverviewPanel(props: {
  readonly threadRef: ScopedThreadRef;
  readonly agentTitle: string;
  readonly agentStatus: string;
  readonly tasks: ReadonlyArray<PendingTask>;
  readonly stopDisabled: boolean;
  readonly stopping: boolean;
  readonly onStop: () => Promise<void>;
  readonly onOpenThread: (threadId: ThreadId) => void;
}) {
  const environmentId = props.threadRef.environmentId;
  // The full items, as the timeline reads them; the shell's structure items are trimmed.
  const turnItems: ReadonlyArray<LifecycleItem> =
    useAtomValue(
      environmentThreadDetails.threadAtom(props.threadRef),
      (thread) => thread?.projection.turnItems,
    ) ?? [];
  const [subagentsOpen, setSubagentsOpen] = useState(true);
  const [backgroundOpen, setBackgroundOpen] = useState(true);
  const subagents = subagentItems(turnItems).flatMap((item) =>
    item.type === "subagent" ? [item] : [],
  );
  const forest = buildOverviewTree(
    backgroundTasks(props.tasks).map((task) => ({
      ...task,
      label: presentPendingBackgroundWork([task])?.items[0]?.label ?? task.kind,
    })),
  );
  const backgroundCount = countOverviewNodes(forest);
  const working = hasWorkingSubagent(subagents) || backgroundCount > 0;
  const statusSummary = summarizeSubagentStatuses(subagents.map((agent) => agent.status));
  const label = `${subagents.length} ${subagents.length === 1 ? "subagent" : "subagents"}`;
  const started = (taskId: string) => {
    const item = turnItems.findLast(
      (candidate) => (candidate.nativeItemRef?.nativeId || candidate.id) === taskId,
    );
    return item?.startedAt ? DateTime.toEpochMillis(item.startedAt) : null;
  };

  const renderTask = (node: OverviewNode<PendingTask & { label: string }>) => {
    const { task } = node;
    const Icon = KIND_ICON[task.kind];
    const startedAtMs = started(task.taskId);
    return (
      <li key={task.taskId} data-overview-task={task.taskId}>
        <div className="flex min-h-9 min-w-0 items-center gap-2.5 rounded-md px-2 py-1.5">
          <span
            aria-hidden
            className="inline-flex size-6 shrink-0 items-center justify-center rounded-full border border-border/70 bg-muted"
          >
            <Icon className="size-3.5 text-muted-foreground" />
          </span>
          <span
            className={cn(
              "min-w-0 flex-1 truncate text-xs text-foreground",
              (task.kind === "command" || task.kind === "monitor") && "font-mono",
            )}
          >
            {task.label}
          </span>
          {startedAtMs === null ? null : (
            <span
              ref={tickTextContent(
                (nowMs) => formatDuration(Math.max(1_000, nowMs - startedAtMs)),
                true,
              )}
              className="shrink-0 text-xs text-muted-foreground tabular-nums"
            />
          )}
        </div>
        {node.children.length > 0 ? (
          <ul className="ms-5 border-s border-border/70 ps-1">{node.children.map(renderTask)}</ul>
        ) : null}
      </li>
    );
  };

  return (
    <div data-octet-overview-panel="" className="flex h-full min-h-0 flex-col overflow-y-auto px-3 py-2">
      <div className="flex items-center gap-2 py-1.5">
        <span className="min-w-0 flex-1 truncate font-semibold text-sm">{props.agentTitle}</span>
        <span className="shrink-0 text-muted-foreground text-xs">{props.agentStatus}</span>
        {working ? (
          <Button
            size="xs"
            variant="ghost"
            disabled={props.stopDisabled}
            onClick={() => void props.onStop()}
          >
            <CircleStopIcon aria-hidden className="size-3" />
            {props.stopping ? "Stopping…" : "Stop all"}
          </Button>
        ) : null}
      </div>

      {subagents.length === 0 && backgroundCount === 0 ? (
        <p className="py-1 text-muted-foreground text-xs">Nothing running in the background.</p>
      ) : null}

      {subagents.length > 0 ? (
        <Collapsible open={subagentsOpen} onOpenChange={setSubagentsOpen} data-subagent-group>
          <CollapsibleTrigger
            aria-label={label}
            aria-description={statusSummary}
            className={cn(
              "flex w-full min-w-0 items-center gap-2.5 py-2 text-left transition-opacity hover:opacity-100",
              subagentsOpen || hasWorkingSubagent(subagents)
                ? "text-foreground opacity-100"
                : "text-muted-foreground opacity-55",
            )}
          >
            <span className="flex shrink-0 items-center -space-x-1.5" aria-hidden>
              {subagents.slice(0, 3).map((agent) => (
                <EnvironmentSubagentAvatar
                  key={agent.id}
                  environmentId={environmentId}
                  providerInstanceId={agent.providerInstanceId}
                  driver={agent.driver}
                  remote={agent.remoteChild}
                  status={subagents.length === 1 ? agent.status : undefined}
                />
              ))}
              {subagents.length > 3 ? (
                <span className="relative inline-flex size-6 items-center justify-center rounded-full bg-muted font-medium text-3xs text-muted-foreground ring-2 ring-background">
                  +{subagents.length - 3}
                </span>
              ) : null}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block font-semibold text-xs">{label}</span>
              <span
                className={cn(
                  "block truncate text-3xs text-muted-foreground",
                  hasWorkingSubagent(subagents)
                    ? "text-info"
                    : subagents.some((agent) => agent.status === "failed") && "text-destructive",
                )}
              >
                {statusSummary}
              </span>
            </span>
            <span className="shrink-0 text-muted-foreground text-xs tabular-nums">
              <SubagentElapsed agent={subagentGroupTiming(subagents)} />
            </span>
            <ChevronDownIcon
              aria-hidden
              className={cn(
                "size-3.5 shrink-0 text-muted-foreground transition-transform",
                subagentsOpen && "rotate-180",
              )}
            />
          </CollapsibleTrigger>
          <CollapsiblePanel animate={false}>
            {subagentsOpen ? (
              <div className={CARD_CLASS}>
                {subagents.map((agent) => (
                  <V2LifecycleRow
                    key={agent.id}
                    environmentId={environmentId}
                    item={agent}
                    runs={[]}
                    onOpenThread={props.onOpenThread}
                  />
                ))}
              </div>
            ) : null}
          </CollapsiblePanel>
        </Collapsible>
      ) : null}

      {backgroundCount > 0 ? (
        <div className="mt-2">
          <CollapsibleSectionHeader
            variant="panel"
            expanded={backgroundOpen}
            onClick={() => setBackgroundOpen((open) => !open)}
            accessory={<span className="text-muted-foreground tabular-nums">{backgroundCount}</span>}
          >
            Background
          </CollapsibleSectionHeader>
          {backgroundOpen ? (
            <ul className={CARD_CLASS}>{forest.map(renderTask)}</ul>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
