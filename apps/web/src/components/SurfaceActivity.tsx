import type { ReactNode } from "react";
import type {
  OrchestrationV2PendingBackgroundTask,
  ScopedThreadRef,
  ThreadLinkedPullRequest,
} from "@t3tools/contracts";
import { RadarIcon, TerminalIcon, ListTodoIcon } from "lucide-react";
import { useQuietThreadProjection, useQuietThreadShells } from "~/state/entities";
import { threadRuntimeIsActive } from "@t3tools/client-runtime/state/shell";
import { useEnvironmentQuery } from "~/state/query";
import { pullRequestEnvironment } from "~/state/pullRequests";
import { ProviderInstanceIcon } from "./chat/ProviderInstanceIcon";
import {
  buildOverviewActivityTree,
  type OverviewActivity,
  type OverviewNode,
} from "./octet/overview/overview.logic";
import { useProjectTodoFile } from "./octet/todos/useProjectTodoFile";
import { parseProjectTodos } from "./octet/todos/projectTodos.logic";
import { useDiscoveredLocalServers } from "./preview/useDiscoveredLocalServers";
import {
  pullRequestChecksState,
  pullRequestChecksStatePresentation,
} from "./pullRequest/pullRequestPresentation";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";
import { cn } from "~/lib/utils";

export interface SurfaceActivityContext {
  readonly threadRef: ScopedThreadRef;
  readonly cwd: string | null;
  readonly tasks: readonly OrchestrationV2PendingBackgroundTask[];
  readonly pullRequest: ThreadLinkedPullRequest | null | undefined;
  readonly linkedPullRequests: number;
  readonly changedFiles: number;
  readonly openFiles: number;
  readonly browserTabs: number;
  readonly devices: number;
  readonly configuredUrls: readonly string[];
}

function ActivityCue({
  label,
  children,
  active = false,
}: {
  readonly label: string;
  readonly children: ReactNode;
  readonly active?: boolean;
}) {
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <span
            aria-label={label}
            className="inline-flex shrink-0 items-center gap-1.5 text-2xs text-muted-foreground tabular-nums"
          />
        }
      >
        {active ? <span aria-hidden className="size-1.5 rounded-full bg-success" /> : null}
        {children}
      </TooltipTrigger>
      <TooltipPopup>{label}</TooltipPopup>
    </Tooltip>
  );
}

function CountCue({
  count,
  label,
  active = false,
}: {
  readonly count: number;
  readonly label: string;
  readonly active?: boolean;
}) {
  return count > 0 ? (
    <ActivityCue label={`${count} ${label}`} active={active}>
      <span className="min-w-4 rounded bg-muted px-1 text-center">{count}</span>
    </ActivityCue>
  ) : null;
}

function OverviewCue({ context }: { readonly context: SurfaceActivityContext }) {
  const thread = useQuietThreadProjection(context.threadRef);
  const nodes = buildOverviewActivityTree(
    thread?.projection.turnItems ?? [],
    context.tasks,
    thread?.projection.runs ?? [],
  );
  const work: OverviewActivity[] = [];
  const visit = (entries: readonly OverviewNode<OverviewActivity>[]) => {
    for (const entry of entries) {
      if (entry.task.live) work.push(entry.task);
      visit(entry.children);
    }
  };
  visit(nodes);
  const agents = work.flatMap((task) => (task.kind === "subagent" ? [task.agent] : []));
  const commands = work.filter((task) => task.kind === "command").length;
  const monitors = work.filter((task) => task.kind === "monitor").length;
  const background = work.filter((task) => task.kind === "background_task").length;
  if (!work.length) return null;
  return (
    <ActivityCue
      active
      label={`${agents.length} active agents, ${commands} commands, ${monitors} monitors, ${background} background tasks`}
    >
      {agents.length ? (
        <span className="flex -space-x-1.5">
          {agents.slice(0, 3).map((agent) => (
            <span
              key={agent.id}
              className="inline-flex size-5 items-center justify-center rounded-full border border-background bg-muted"
            >
              <ProviderInstanceIcon
                driverKind={agent.driver}
                displayName={agent.title ?? "Agent"}
                size="compact"
              />
            </span>
          ))}
        </span>
      ) : null}
      {agents.length > 3 ? <span>+{agents.length - 3}</span> : null}
      {commands ? (
        <span className="inline-flex items-center gap-0.5">
          <TerminalIcon className="size-3" />
          {commands}
        </span>
      ) : null}
      {monitors ? (
        <span className="inline-flex items-center gap-0.5">
          <RadarIcon className="size-3" />
          {monitors}
        </span>
      ) : null}
      {background ? (
        <span className="inline-flex items-center gap-0.5">
          <ListTodoIcon className="size-3" />
          {background}
        </span>
      ) : null}
    </ActivityCue>
  );
}

function TodoCue({ context }: { readonly context: SurfaceActivityContext }) {
  const file = useProjectTodoFile(context.threadRef.environmentId, context.cwd);
  const remaining = parseProjectTodos(file.contents).items.filter(
    (item) => item.status !== "completed",
  ).length;
  return file.loaded ? <CountCue count={remaining} label="unfinished TODO items" /> : null;
}

function BrowserCue({ context }: { readonly context: SurfaceActivityContext }) {
  const servers = useDiscoveredLocalServers({
    environmentId: context.threadRef.environmentId,
    configuredUrls: context.configuredUrls,
  });
  return servers.length ? (
    <ActivityCue label={`${servers.length} live local servers`} active>
      {servers.length} live
    </ActivityCue>
  ) : (
    <CountCue count={context.browserTabs} label="browser tabs" />
  );
}

function ChecksCue({ context }: { readonly context: SurfaceActivityContext }) {
  const pr = context.pullRequest;
  const query = useEnvironmentQuery(
    pr
      ? pullRequestEnvironment.checks({
          environmentId: context.threadRef.environmentId,
          input: { projectId: pr.projectId, repository: pr.repository, number: pr.number },
        })
      : null,
  );
  const checks = query.data?.checks ?? [];
  const state = pullRequestChecksState(checks);
  if (!state) return <CountCue count={checks.length} label="checks" />;
  const presentation = pullRequestChecksStatePresentation(state);
  return (
    <ActivityCue label={`${checks.length} checks · ${presentation.label}`}>
      <span className={cn("inline-flex items-center gap-1", presentation.toneClassName)}>
        <presentation.Icon className="size-3" />
        {state === "passing" ? "Passed" : state === "failing" ? "Failed" : "Running"}
      </span>
    </ActivityCue>
  );
}

function SideChatCue({ context }: { readonly context: SurfaceActivityContext }) {
  const threads = useQuietThreadShells().filter(
    (thread) =>
      thread.environmentId === context.threadRef.environmentId &&
      thread.lineage.sideChat &&
      thread.lineage.parentThreadId === context.threadRef.threadId,
  );
  const running = threads.filter((thread) => threadRuntimeIsActive(thread.runtime)).length;
  return (
    <CountCue
      count={threads.length}
      label={running ? `side chats, ${running} running` : "side chats"}
      active={running > 0}
    />
  );
}

export function SurfaceActivity({
  label,
  context,
}: {
  readonly label: string;
  readonly context: SurfaceActivityContext;
}) {
  switch (label) {
    case "Overview":
      return <OverviewCue context={context} />;
    case "TODO":
      return <TodoCue context={context} />;
    case "Browser":
      return <BrowserCue context={context} />;
    case "Diff":
      return <CountCue count={context.changedFiles} label="changed files" />;
    case "Files":
      return <CountCue count={context.openFiles} label="open files" />;
    case "Linked pull requests":
      return <CountCue count={context.linkedPullRequests} label="linked pull requests" />;
    case "Pull request":
      return context.pullRequest ? (
        <ActivityCue label={`Pull request #${context.pullRequest.number}`}>
          #{context.pullRequest.number}
        </ActivityCue>
      ) : null;
    case "CI":
      return <ChecksCue context={context} />;
    case "Device":
      return <CountCue count={context.devices} label="device sessions" active />;
    case "Side chat":
      return <SideChatCue context={context} />;
    default:
      return null;
  }
}
