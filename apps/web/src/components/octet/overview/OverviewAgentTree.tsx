import { scopeThreadRef, scopedThreadKey } from "@t3tools/client-runtime/environment";
import type { ScopedThreadRef, ThreadId } from "@t3tools/contracts";
import { useNavigate } from "@tanstack/react-router";
import { ChevronRightIcon, TerminalIcon, RadarIcon, ListTodoIcon } from "lucide-react";
import { useId, useState, type ReactNode } from "react";

import { cn } from "~/lib/utils";
import { useQuietThreadProjection, useQuietThreadShell } from "../../../state/entities";
import { useEnvironment } from "../../../state/environments";
import { buildThreadRouteParams } from "../../../threadRoutes";
import { V2LifecycleRow } from "../../chat/V2LifecycleRow";
import { Button } from "../../ui/button";
import { Tooltip, TooltipTrigger, TooltipPopup } from "../../ui/tooltip";
import { formatDuration } from "@t3tools/shared/orchestrationTiming";
import * as DateTime from "effect/DateTime";
import { tickTextContent } from "~/lib/tickTextContent";
import {
  agentsOnly,
  buildOverviewActivityTree,
  type OverviewActivity,
  type OverviewNode,
  type OverviewWork,
} from "./overview.logic";

type AgentNode = OverviewNode<OverviewActivity>;

interface TreeProps {
  readonly nodes: readonly AgentNode[];
  readonly sourceRef: ScopedThreadRef;
  readonly rootRef: ScopedThreadRef;
  readonly ancestors: readonly string[];
  readonly onOpenThread: (threadId: ThreadId) => void;
  /** Compact fits a narrow surface such as the thread details' Lineage section. */
  readonly density?: "default" | "compact" | undefined;
  /** Agents only: shells, monitors and tasks are listed elsewhere (Lineage). */
  readonly agentsOnly?: boolean | undefined;
}

function AgentBranches({
  children,
  compact = false,
}: {
  readonly children: ReactNode;
  readonly compact?: boolean;
}) {
  return (
    <ul
      aria-label="Agent branches"
      className={cn(
        compact ? "ms-3" : "ms-5",
        "relative [--agent-tree-line:color-mix(in_srgb,var(--color-muted-foreground)_35%,var(--background))] before:pointer-events-none before:absolute before:-top-2 before:left-0 before:h-2 before:rounded-t-full before:border-l-2 before:border-(--agent-tree-line)",
      )}
    >
      {children}
    </ul>
  );
}

export function OverviewAgentTree(props: TreeProps) {
  return (
    <AgentBranches compact={props.density === "compact"}>
      {props.nodes.map((node) => (
        <OverviewBranch key={node.task.taskId} {...props} node={node} />
      ))}
    </AgentBranches>
  );
}

const WORK_ICON = { monitor: RadarIcon, command: TerminalIcon, background_task: ListTodoIcon };

/** One line for a shell, monitor or task: its icon, the command dimmed and small, and its time. */
export function ActivityWorkRow({ task }: { readonly task: OverviewWork }) {
  const Icon = WORK_ICON[task.kind];
  const started = task.startedAt ? DateTime.toEpochMillis(task.startedAt) : null;
  return (
    <div data-activity-work={task.taskId} className="flex h-7 min-w-0 items-center gap-2 px-1.5">
      <Icon aria-hidden className="size-3 shrink-0 text-muted-foreground/80" />
      <Tooltip>
        <TooltipTrigger
          render={
            <span
              className={cn(
                "min-w-0 flex-1 truncate text-2xs text-muted-foreground",
                task.kind !== "background_task" && "font-mono",
              )}
            />
          }
        >
          {task.label}
        </TooltipTrigger>
        <TooltipPopup>
          {task.kind === "monitor" ? "Monitoring: " : ""}
          {task.label}
        </TooltipPopup>
      </Tooltip>
      {started === null ? null : (
        <span
          className="shrink-0 text-2xs text-muted-foreground/80 tabular-nums"
          ref={tickTextContent((now) => formatDuration(Math.max(1000, now - started)), true)}
        />
      )}
    </div>
  );
}

function OverviewBranch({ node, ...props }: TreeProps & { readonly node: AgentNode }) {
  if (node.task.kind === "subagent")
    return <OverviewAgentBranch {...props} node={node} agent={node.task.agent} />;
  const task = node.task;
  const Icon =
    task.kind === "monitor" ? RadarIcon : task.kind === "command" ? TerminalIcon : ListTodoIcon;
  const started = task.startedAt ? DateTime.toEpochMillis(task.startedAt) : null;
  if (props.density === "compact") {
    return (
      <li
        data-overview-task={task.taskId}
        className="relative border-l-2 border-(--agent-tree-line) ps-4"
      >
        <ActivityWorkRow task={task} />
        {node.children.length ? <OverviewAgentTree {...props} nodes={node.children} /> : null}
      </li>
    );
  }
  return (
    <li
      data-overview-task={task.taskId}
      className="relative border-l-2 border-(--agent-tree-line) py-1 ps-5"
    >
      <div className="flex min-h-8 min-w-0 items-center gap-2 text-xs">
        <Icon aria-hidden className="size-3.5 shrink-0 text-muted-foreground" />
        <div className="min-w-0 flex-1">
          <Tooltip>
            <TooltipTrigger
              render={
                <span
                  className={cn("block truncate", task.kind !== "background_task" && "font-mono")}
                />
              }
            >
              {task.label}
            </TooltipTrigger>
            <TooltipPopup>{task.label}</TooltipPopup>
          </Tooltip>
          <div className="flex gap-2 text-2xs text-muted-foreground">
            <span>{task.kind === "monitor" ? "Monitoring" : "Running"}</span>
            {started === null ? null : (
              <span
                className="tabular-nums"
                ref={tickTextContent((now) => formatDuration(Math.max(1000, now - started)), true)}
              />
            )}
          </div>
        </div>
      </div>
      {node.children.length ? <OverviewAgentTree {...props} nodes={node.children} /> : null}
    </li>
  );
}

function OverviewAgentBranch({
  node,
  agent,
  ...props
}: TreeProps & {
  readonly node: AgentNode;
  readonly agent: Extract<OverviewActivity, { kind: "subagent" }>["agent"];
}) {
  const [open, setOpen] = useState(true);
  const childrenId = useId();
  const navigate = useNavigate();
  const remoteEnvironment = useEnvironment(agent.remoteChild?.environmentId ?? null);
  const childRef = agent.childThreadId
    ? scopeThreadRef(props.sourceRef.environmentId, agent.childThreadId)
    : agent.remoteChild && remoteEnvironment
      ? scopeThreadRef(agent.remoteChild.environmentId, agent.remoteChild.threadId)
      : null;
  const childKey = childRef ? scopedThreadKey(childRef) : null;
  const canFollow = childKey !== null && !props.ancestors.includes(childKey);
  const childThread = useQuietThreadProjection(canFollow ? childRef : null);
  const childItems = childThread?.projection.turnItems ?? [];
  const childShell = useQuietThreadShell(canFollow ? childRef : null);
  const childForest = buildOverviewActivityTree(
    childItems,
    childShell?.pendingBackgroundTasks ?? [],
    childThread?.projection.runs ?? [],
  );
  const childNodes = props.agentsOnly ? agentsOnly(childForest) : childForest;
  const hasChildren = node.children.length > 0 || childNodes.length > 0;
  const openThread = (threadId: ThreadId) => {
    if (props.sourceRef.environmentId === props.rootRef.environmentId) props.onOpenThread(threadId);
    else {
      void navigate({
        to: "/$environmentId/$threadId",
        params: buildThreadRouteParams(scopeThreadRef(props.sourceRef.environmentId, threadId)),
      });
    }
  };

  return (
    <li
      data-overview-agent={agent.subagentId}
      className={cn(
        // The last branch's trunk stops where its curve starts (the curve's top), so the two meet
        // without a stub: 2px down in the compact rows, 8px in the roomy ones.
        props.density === "compact" ? "ps-5 last:before:h-0.5" : "ps-6 last:before:h-2",
        "relative before:pointer-events-none before:absolute before:inset-y-0 before:left-0 before:border-l-2 before:border-(--agent-tree-line) last:before:bottom-auto",
      )}
    >
      <span
        aria-hidden="true"
        className={cn(
          "pointer-events-none absolute left-0 rounded-bl-2xl border-b-2 border-l-2 border-(--agent-tree-line)",
          props.density === "compact" ? "top-0.5 h-3.5 w-5" : "top-2 h-4 w-7",
        )}
      />
      <div
        className={cn(
          "relative flex min-w-0 items-center",
          props.density === "compact" ? "h-8" : "h-12",
        )}
      >
        <div className="min-w-0 flex-1">
          <V2LifecycleRow
            environmentId={props.sourceRef.environmentId}
            item={agent}
            runs={[]}
            onOpenThread={openThread}
            compact={props.density === "compact"}
          />
        </div>
        {hasChildren ? (
          <Button
            size="icon-micro"
            variant="ghost-muted"
            aria-label={`${open ? "Collapse" : "Expand"} ${agent.title || "agent"} branches`}
            aria-expanded={open}
            aria-controls={childrenId}
            onClick={() => setOpen((value) => !value)}
          >
            <ChevronRightIcon className={cn("size-3", open && "rotate-90")} />
          </Button>
        ) : null}
      </div>
      {open && hasChildren ? (
        <div id={childrenId}>
          <AgentBranches compact={props.density === "compact"}>
            {node.children.map((child) => (
              <OverviewBranch key={`local:${child.task.taskId}`} {...props} node={child} />
            ))}
            {childRef && childKey
              ? childNodes.map((child) => (
                  <OverviewBranch
                    key={`${childKey}:${child.task.taskId}`}
                    {...props}
                    node={child}
                    sourceRef={childRef}
                    ancestors={[...props.ancestors, childKey]}
                  />
                ))
              : null}
          </AgentBranches>
        </div>
      ) : null}
    </li>
  );
}
