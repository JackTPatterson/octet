/**
 * Octet's Overview plane lists what a thread's agent is running: its
 * subagents (drawn as T3 draws them in the timeline) and its background
 * commands and monitors as a tree. T3 already tracks this per thread
 * (turn items, and `pendingBackgroundTasks` with `parentTaskId` for the
 * nesting); this file only shapes it.
 */

export type OverviewTaskKind = "subagent" | "command" | "monitor" | "background_task";

export interface OverviewTask {
  readonly taskId: string;
  readonly kind: OverviewTaskKind;
  readonly parentTaskId?: string | undefined;
  readonly childThreadId?: string | undefined;
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
  const forest = roots.toSorted((left, right) => KIND_ORDER[left.kind] - KIND_ORDER[right.kind]).map(build);
  for (const task of tasks) if (!visited.has(task.taskId)) forest.push(build(task));
  return forest;
}

/** How many tasks the forest holds. */
export function countOverviewNodes<T extends OverviewTask>(forest: readonly OverviewNode<T>[]): number {
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
