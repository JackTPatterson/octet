import type { ThreadStructureTurnItem } from "@t3tools/client-runtime/state/models";
import type {
  OrchestrationV2TurnItem,
  OrchestrationV2PendingBackgroundTask,
} from "@t3tools/contracts";
import { presentPendingBackgroundWork } from "@t3tools/client-runtime/state/thread-execution";

export type OverviewTaskKind = "subagent" | "command" | "monitor" | "background_task";

export interface OverviewTask {
  readonly taskId: string;
  readonly kind: OverviewTaskKind;
  readonly parentTaskId?: string | undefined;
  readonly childThreadId?: string | undefined;
  /** Still working: what Stop all would stop. Finished agents stay listed but aren't live. */
  readonly live?: boolean | undefined;
}

export interface OverviewNode<T extends OverviewTask> {
  readonly task: T;
  readonly children: readonly OverviewNode<T>[];
}

const KIND_ORDER: Record<OverviewTaskKind, number> = {
  subagent: 0,
  command: 1,
  monitor: 2,
  background_task: 3,
};

/**
 * The tasks as a forest. A task whose parent isn't in the list is a root,
 * so work orphaned by a finished parent still shows. Siblings keep the
 * order they arrived in, subagents first.
 */
export function buildOverviewTree<T extends OverviewTask>(
  tasks: readonly T[],
): readonly OverviewNode<T>[] {
  const ids = new Set(tasks.map((task) => task.taskId));
  const childrenOf = new Map<string, T[]>();
  const roots: T[] = [];
  for (const task of tasks) {
    const parent = task.parentTaskId;
    if (parent && parent !== task.taskId && ids.has(parent)) {
      const siblings = childrenOf.get(parent) ?? [];
      siblings.push(task);
      childrenOf.set(parent, siblings);
    } else {
      roots.push(task);
    }
  }
  const visited = new Set<string>();
  const build = (task: T): OverviewNode<T> => {
    visited.add(task.taskId);
    const children = (childrenOf.get(task.taskId) ?? [])
      .filter((child) => !visited.has(child.taskId))
      .toSorted((left, right) => KIND_ORDER[left.kind] - KIND_ORDER[right.kind])
      .map(build);
    return { task, children };
  };
  // A cycle (a is b's parent and b is a's) has no root; show its members flat.
  const forest = roots
    .toSorted((left, right) => KIND_ORDER[left.kind] - KIND_ORDER[right.kind])
    .map(build);
  for (const task of tasks) if (!visited.has(task.taskId)) forest.push(build(task));
  return forest;
}

/** How many tasks the forest holds. */
export function countOverviewNodes<T extends OverviewTask>(
  forest: readonly OverviewNode<T>[],
): number {
  return forest.reduce((total, node) => total + 1 + countOverviewNodes(node.children), 0);
}

const WORKING = new Set(["pending", "running", "waiting"]);

export interface SubagentItemInput {
  readonly type: string;
  readonly status: string;
  readonly completedAt?: { readonly epochMilliseconds?: number } | number | null | undefined;
  readonly updatedAt?: { readonly epochMilliseconds?: number } | number | null | undefined;
}

const ms = (value: SubagentItemInput["completedAt"]): number =>
  typeof value === "number" ? value : (value?.epochMilliseconds ?? 0);

/**
 * The thread's subagent items for the list: the ones still working first,
 * then the rest, most recently finished first. Mid-turn T3 holds subagents
 * only as turn items, so this reads them and not the pending tasks.
 */
export function subagentItems<T extends SubagentItemInput>(items: readonly T[]): readonly T[] {
  return items
    .filter((item) => item.type === "subagent")
    .toSorted((left, right) => {
      const working = Number(WORKING.has(right.status)) - Number(WORKING.has(left.status));
      if (working !== 0) return working;
      return (
        Math.max(ms(right.completedAt), ms(right.updatedAt)) -
        Math.max(ms(left.completedAt), ms(left.updatedAt))
      );
    });
}

/** Whether any subagent is still working. */
export function hasWorkingSubagent(items: readonly SubagentItemInput[]): boolean {
  return items.some((item) => item.type === "subagent" && WORKING.has(item.status));
}

/** Pending background tasks other than subagents, which the subagent list covers. */
export function backgroundTasks<T extends OverviewTask>(tasks: readonly T[]): readonly T[] {
  return tasks.filter((task) => task.kind !== "subagent");
}

interface AgentTreeItem {
  readonly id: string;
  readonly subagentId: string;
  readonly parentItemId: string | null;
}

export interface OverviewAgentTask<T extends AgentTreeItem> extends OverviewTask {
  readonly kind: "subagent";
  readonly agent: T;
}

export function buildOverviewAgentTree<T extends AgentTreeItem>(
  agents: readonly T[],
  items: readonly { readonly id: string; readonly parentItemId: string | null }[],
): readonly OverviewNode<OverviewAgentTask<T>>[] {
  const byId = new Map(items.map((item) => [item.id, item]));
  const latest = new Map<string, T>();
  for (const agent of agents)
    if (!latest.has(agent.subagentId)) latest.set(agent.subagentId, agent);
  const aliases = new Map(agents.map((agent) => [agent.id, latest.get(agent.subagentId)!]));
  return buildOverviewTree(
    [...latest.values()].map((agent): OverviewAgentTask<T> => {
      const seen = new Set([agent.id]);
      let parent = agent.parentItemId;
      while (parent && !seen.has(parent)) {
        seen.add(parent);
        const ancestor = aliases.get(parent);
        if (ancestor && ancestor.subagentId !== agent.subagentId) {
          return { taskId: agent.id, kind: "subagent", agent, parentTaskId: ancestor.id };
        }
        parent = byId.get(parent)?.parentItemId ?? null;
      }
      return { taskId: agent.id, kind: "subagent", agent };
    }),
  );
}

const ENDED_RUN = new Set(["completed", "interrupted", "failed", "cancelled", "rolled_back"]);

interface RunStatusInput {
  readonly id: string;
  readonly status: string;
}

/**
 * Whether an item that says it is working really is. The projection can leave an
 * item `running` after its run ended (a dropped completion event), so an item of
 * an ended run is stale, whatever its own status.
 */
function itemWorking(
  item: { readonly status: string; readonly runId?: string | null },
  endedRuns: ReadonlySet<string>,
): boolean {
  return WORKING.has(item.status) && !(item.runId && endedRuns.has(item.runId));
}

/** Whether a node or any node under it is live. */
export function isLiveNode<T extends OverviewTask>(node: OverviewNode<T>): boolean {
  return node.task.live === true || node.children.some(isLiveNode);
}

export type OverviewActivity =
  | OverviewAgentTask<Extract<OrchestrationV2TurnItem, { type: "subagent" }>>
  | (OverviewTask & {
      readonly kind: "command" | "monitor" | "background_task";
      readonly label: string;
      readonly startedAt: OrchestrationV2TurnItem["startedAt"];
    });

export function buildOverviewActivityTree(
  items: readonly ThreadStructureTurnItem[],
  pending: readonly OrchestrationV2PendingBackgroundTask[],
  runs: readonly RunStatusInput[] = [],
): readonly OverviewNode<OverviewActivity>[] {
  const endedRuns = new Set(runs.flatMap((run) => (ENDED_RUN.has(run.status) ? [run.id] : [])));
  const pendingIds = new Set(
    pending.flatMap((task) => [
      task.taskId as string,
      ...(task.kind === "subagent" && task.childThreadId ? [task.childThreadId as string] : []),
    ]),
  );
  const agents = subagentItems(items).flatMap((item) => (item.type === "subagent" ? [item] : []));
  const tasks: OverviewActivity[] = [];
  const flatten = (nodes: readonly OverviewNode<OverviewAgentTask<(typeof agents)[number]>>[]) => {
    for (const node of nodes) {
      const agent = node.task.agent;
      const live =
        itemWorking(agent, endedRuns) ||
        (WORKING.has(agent.status) &&
          [agent.id, agent.subagentId, agent.childThreadId].some(
            (id) => id != null && pendingIds.has(id),
          ));
      tasks.push({ ...node.task, live });
      flatten(node.children);
    }
  };
  flatten(buildOverviewAgentTree(agents, items));
  const aliases = new Map<string, string>();
  for (const task of tasks) {
    if (task.kind === "subagent") aliases.set(task.agent.subagentId, task.taskId);
  }
  for (const agent of agents) aliases.set(agent.id, aliases.get(agent.subagentId)!);
  const commands = items.flatMap((item) =>
    item.type === "command_execution" && itemWorking(item, endedRuns) ? [item] : [],
  );
  for (const item of commands) {
    aliases.set(item.id, item.id);
    if (item.nativeItemRef?.nativeId) aliases.set(item.nativeItemRef.nativeId, item.id);
  }
  const byId = new Map(items.map((item) => [item.id as string, item]));
  const parentOf = (id: string | null | undefined): string | undefined => {
    const seen = new Set<string>();
    while (id && !seen.has(id)) {
      seen.add(id);
      if (aliases.has(id)) return aliases.get(id);
      if (pending.some((task) => task.taskId === id)) return id;
      id = byId.get(id)?.parentItemId;
    }
    return undefined;
  };
  const work = new Map<string, OverviewActivity>();
  for (const item of commands) {
    work.set(item.id, {
      taskId: item.id,
      kind: item.monitor ? "monitor" : "command",
      label: item.input,
      startedAt: item.startedAt,
      parentTaskId: parentOf(item.parentItemId),
      live: true,
    });
  }
  for (const task of pending) {
    if (task.kind === "subagent") continue;
    const id = aliases.get(task.taskId) ?? task.taskId;
    const existing = work.get(id);
    work.set(id, {
      taskId: id,
      kind: task.kind,
      label: presentPendingBackgroundWork([task])?.items[0]?.label ?? task.kind,
      startedAt: existing && existing.kind !== "subagent" ? existing.startedAt : null,
      parentTaskId: parentOf(task.parentTaskId) ?? existing?.parentTaskId,
      live: true,
    });
  }
  return buildOverviewTree([...tasks, ...work.values()]);
}

/** The forest with only its agents: other work is dropped, with everything under it. */
export function agentsOnly(
  nodes: readonly OverviewNode<OverviewActivity>[],
): readonly OverviewNode<OverviewActivity>[] {
  return nodes.flatMap((node) =>
    node.task.kind === "subagent" ? [{ task: node.task, children: agentsOnly(node.children) }] : [],
  );
}

export type OverviewWork = Exclude<OverviewActivity, { kind: "subagent" }>;

/** Every command, monitor and background task in the forest, in tree order. */
export function collectWork(
  nodes: readonly OverviewNode<OverviewActivity>[],
): readonly OverviewWork[] {
  return nodes.flatMap((node) => [
    ...(node.task.kind === "subagent" ? [] : [node.task]),
    ...collectWork(node.children),
  ]);
}
