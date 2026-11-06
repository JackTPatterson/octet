import type { SidebarThreadSummary } from "../../../types";
import type { SidebarThreadStatus } from "../../Sidebar.logic";

/**
 * Octet's sidebar shows a project's work as one card per branch (or
 * worktree), the way native Octet shows a workspace. The card is drawn with
 * T3's thread row; this file only decides what goes on it.
 */
export type BranchCardThread = Pick<
  SidebarThreadSummary,
  "id" | "environmentId" | "title" | "branch" | "worktreePath" | "updatedAt" | "latestUserMessageAt"
>;

export interface BranchCard<T extends BranchCardThread> {
  /** Stable within a project: the worktree path, else the branch. */
  readonly key: string;
  readonly branch: string | null;
  readonly worktreePath: string | null;
  /** Newest first; the first is the one the card opens and is titled after. */
  readonly threads: readonly T[];
  readonly latestActivityMs: number;
  /** The loudest status among its threads, in T3's terms. */
  readonly status: SidebarThreadStatus;
}

/** When a thread last did something: its newest message, else its last update. */
export function threadActivityMs(
  thread: Pick<BranchCardThread, "updatedAt" | "latestUserMessageAt">,
): number {
  const candidates = [thread.latestUserMessageAt, thread.updatedAt]
    .map((value) => (value ? Date.parse(value) : Number.NaN))
    .filter((value) => !Number.isNaN(value));
  return candidates.length === 0 ? 0 : Math.max(...candidates);
}

// What needs the person first, then what broke, then what is busy.
const STATUS_RANK: Record<SidebarThreadStatus, number> = {
  approval: 8,
  input: 7,
  request: 6,
  limited: 5,
  failed: 4,
  working: 3,
  waiting: 2,
  ready: 0,
};

/** A card is as loud as its loudest thread. */
export function loudestStatus(statuses: Iterable<SidebarThreadStatus>): SidebarThreadStatus {
  let loudest: SidebarThreadStatus = "ready";
  for (const status of statuses) if (STATUS_RANK[status] > STATUS_RANK[loudest]) loudest = status;
  return loudest;
}

export function branchCardKey(thread: Pick<BranchCardThread, "branch" | "worktreePath">): string {
  if (thread.worktreePath) return `worktree:${thread.worktreePath}`;
  return `branch:${thread.branch ?? ""}`;
}

/** One project's threads as branch cards, most recently active card first. */
export function groupIntoBranchCards<T extends BranchCardThread>(
  threads: readonly T[],
  statusOf: (thread: T) => SidebarThreadStatus,
): BranchCard<T>[] {
  const byKey = new Map<string, T[]>();
  for (const thread of threads) {
    const key = branchCardKey(thread);
    const list = byKey.get(key);
    if (list) list.push(thread);
    else byKey.set(key, [thread]);
  }
  const cards: BranchCard<T>[] = [];
  for (const [key, members] of byKey) {
    const sorted = members.toSorted(
      (left, right) => threadActivityMs(right) - threadActivityMs(left),
    );
    const newest = sorted[0]!;
    cards.push({
      key,
      branch: newest.branch,
      worktreePath: newest.worktreePath,
      threads: sorted,
      latestActivityMs: threadActivityMs(newest),
      status: loudestStatus(sorted.map(statusOf)),
    });
  }
  return cards.toSorted((left, right) => right.latestActivityMs - left.latestActivityMs);
}

/** Cards with a thread whose title matches every word of the query. */
export function filterBranchCards<T extends BranchCardThread>(
  cards: readonly BranchCard<T>[],
  query: string,
): BranchCard<T>[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [...cards];
  const matches = (thread: T) => {
    const haystack = `${thread.title} ${thread.branch ?? ""}`.toLowerCase();
    return words.every((word) => haystack.includes(word));
  };
  return cards.filter((card) => card.threads.some(matches));
}

/** What a rename box should do with what was typed, as the chat header's does. */
export function resolveCardRename(input: {
  readonly title: string;
  readonly originalTitle: string;
}): { action: "commit"; title: string } | { action: "reject-empty" } | { action: "noop" } {
  const trimmed = input.title.trim();
  if (trimmed.length === 0) return { action: "reject-empty" };
  if (trimmed === input.originalTitle) return { action: "noop" };
  return { action: "commit", title: trimmed };
}

/** Where a card lives: in its project, or on one of the two shelves. */
export type CardPlace = "active" | "waiting" | "idle";

export type CardDropPlan = "settle" | "snooze" | "unsettle" | "unsnooze" | "none";

/**
 * Dropping a card on a shelf moves its work there (Idle settles, Waiting
 * snoozes); dropping a shelved card back on the projects brings it back.
 */
export function planCardDrop(from: CardPlace, to: CardPlace): CardDropPlan {
  if (from === to) return "none";
  if (to === "idle") return "settle";
  if (to === "waiting") return "snooze";
  return from === "idle" ? "unsettle" : "unsnooze";
}

/** The project keys a filter lets through; none chosen lets every project through. */
export function projectInScope(projectKey: string, scopeKeys: readonly string[]): boolean {
  return scopeKeys.length === 0 || scopeKeys.includes(projectKey);
}

export interface PeekRow {
  readonly id: string;
  readonly title: string;
  readonly status: SidebarThreadStatus;
}

/** The hover peek's rows: every thread on the card, loudest first, then newest. */
export function peekRows<T extends BranchCardThread>(
  card: BranchCard<T>,
  statusOf: (thread: T) => SidebarThreadStatus,
): PeekRow[] {
  return card.threads
    .map((thread) => ({ id: thread.id, title: thread.title, status: statusOf(thread) }))
    .map((row, index) => ({ row, index }))
    .toSorted(
      (left, right) =>
        STATUS_RANK[right.row.status] - STATUS_RANK[left.row.status] || left.index - right.index,
    )
    .map(({ row }) => row);
}
