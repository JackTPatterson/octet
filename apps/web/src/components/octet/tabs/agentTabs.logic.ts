import { branchCardKey } from "../sidebar/octetSidebar.logic";

/**
 * Octet's agent tabs run along the top of a thread: the agents working on the
 * same branch (or worktree) as the one in view, the way native Octet's tabs
 * are a workspace's agents. They are the threads of the sidebar's branch
 * card, so this reuses the card's grouping rule.
 */
export interface AgentTabThread {
  readonly id: string;
  readonly environmentId: string;
  readonly projectId: string;
  readonly branch: string | null;
  readonly worktreePath: string | null;
  readonly createdAt?: { readonly epochMilliseconds?: number } | number | string | null | undefined;
  readonly settledOverride?: string | null | undefined;
  readonly lineage?:
    | {
        readonly relationshipToParent?: string | null;
        readonly parentThreadId?: string | null;
        readonly sideChat?: boolean | undefined;
      }
    | undefined;
}

const createdMs = (value: AgentTabThread["createdAt"]): number => {
  if (typeof value === "number") return value;
  if (typeof value === "string") return Date.parse(value) || 0;
  return value?.epochMilliseconds ?? 0;
};

/** A side chat is part of another thread, not a tab of its own. */
function isOwnThread(thread: AgentTabThread): boolean {
  return thread.lineage?.sideChat !== true;
}

/** A subagent's thread: it gets a tab, beside the agent that started it. */
export function isSubagentThread(thread: AgentTabThread): boolean {
  return thread.lineage?.relationshipToParent === "subagent";
}

/**
 * The tabs for the thread in view: every live thread on its branch card,
 * oldest first so tabs hold their place as agents work, each followed by its
 * subagents, and the current one even if it is settled. Null when there is no
 * current thread.
 */
export function agentTabsFor<T extends AgentTabThread>(
  threads: readonly T[],
  current: { readonly environmentId: string; readonly id: string } | null,
  createdMsOf: (thread: T) => number = (thread) => createdMs(thread.createdAt),
): readonly T[] | null {
  if (!current) return null;
  const here = threads.find(
    (thread) => thread.environmentId === current.environmentId && thread.id === current.id,
  );
  if (!here) return null;
  const key = branchCardKey(here);
  const live = (thread: T) =>
    thread.environmentId === here.environmentId &&
    thread.projectId === here.projectId &&
    isOwnThread(thread) &&
    (thread === here || thread.settledOverride !== "settled");
  const byAge = (left: T, right: T) => createdMsOf(left) - createdMsOf(right);
  // Agents of the branch card, oldest first so tabs hold their place as agents work.
  const roots = threads
    .filter((thread) => live(thread) && !isSubagentThread(thread) && branchCardKey(thread) === key)
    .toSorted(byAge);
  // Each subagent follows the agent that started it (a subagent of a subagent, that one).
  const subagents = threads.filter((thread) => live(thread) && isSubagentThread(thread));
  const childrenOf = (parent: T): T[] =>
    subagents.filter((thread) => thread.lineage?.parentThreadId === parent.id).toSorted(byAge);
  const ordered: T[] = [];
  const place = (thread: T) => {
    ordered.push(thread);
    for (const child of childrenOf(thread)) place(child);
  };
  for (const root of roots) place(root);
  // A subagent in view whose parent isn't on this card still shows, last.
  if (!ordered.includes(here)) ordered.push(here);
  return ordered;
}

/**
 * Where to go when the tab `closingId` is closed: the tab before it, else the one after,
 * and null when it is the only tab (it is then not closed from the strip).
 */
export function tabAfterClosing<T extends { readonly id: string }>(
  tabs: readonly T[],
  closingId: string,
): T | null {
  const index = tabs.findIndex((tab) => tab.id === closingId);
  if (index < 0) return null;
  return tabs[index - 1] ?? tabs[index + 1] ?? null;
}

/** The tab one step along from `fromId`, wrapping round; used by the arrow keys. */
export function adjacentTab<T extends { readonly id: string }>(
  tabs: readonly T[],
  fromId: string,
  delta: -1 | 1,
): T | null {
  const index = tabs.findIndex((tab) => tab.id === fromId);
  if (index < 0 || tabs.length === 0) return null;
  return tabs[(index + delta + tabs.length) % tabs.length] ?? null;
}
