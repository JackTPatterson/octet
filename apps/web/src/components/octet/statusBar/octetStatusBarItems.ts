import type { ClientSettings } from "@t3tools/contracts";

/**
 * The chips the status bar can show, in their default order. Ids are stored in client
 * settings, so never rename one. A divider is drawn only where the group changes.
 */
export const STATUS_BAR_ITEMS = [
  { id: "agent", label: "Agent", group: "pane", defaultVisible: true },
  { id: "remoteControl", label: "Remote Control", group: "pane", defaultVisible: true },
  { id: "runtime", label: "Runtime version", group: "pane", defaultVisible: true },
  { id: "directory", label: "Directory", group: "pane", defaultVisible: true },
  { id: "branch", label: "Git branch", group: "repository", defaultVisible: true },
  { id: "worktree", label: "Git worktree", group: "repository", defaultVisible: true },
  { id: "changes", label: "Changes", group: "repository", defaultVisible: true },
  { id: "pullRequest", label: "Pull request", group: "repository", defaultVisible: true },
  { id: "ci", label: "CI", group: "repository", defaultVisible: true },
  { id: "ports", label: "Servers", group: "servers", defaultVisible: true },
  // The right-hand group, kept apart from the scrolling chips (see `isEndGroup`).
  { id: "awake", label: "Keep awake", group: "utilities", defaultVisible: true },
  { id: "memory", label: "Memory", group: "utilities", defaultVisible: true },
] as const;

/** Chips in these groups are drawn at the bar's right edge, outside the scrolling run. */
export const isEndGroup = (group: StatusBarGroup): boolean => group === "utilities";

export type StatusBarItemId = (typeof STATUS_BAR_ITEMS)[number]["id"];
type StatusBarGroup = (typeof STATUS_BAR_ITEMS)[number]["group"];
export type StatusBarItemSettings = Pick<ClientSettings, "statusBarItems" | "statusBarOrder">;

const DEFAULT_ORDER: ReadonlyArray<StatusBarItemId> = STATUS_BAR_ITEMS.map((item) => item.id);
const KNOWN = new Set<string>(DEFAULT_ORDER);

/**
 * Every chip id, in the saved order: unknown ids (a later version's, an older one's) are
 * dropped, repeats are ignored, and chips the saved order lacks follow it in default order.
 */
export function resolveStatusBarOrder(saved: ReadonlyArray<string>): ReadonlyArray<StatusBarItemId> {
  const seen = new Set<string>();
  const order: StatusBarItemId[] = [];
  for (const id of saved) {
    if (!KNOWN.has(id) || seen.has(id)) continue;
    seen.add(id);
    order.push(id as StatusBarItemId);
  }
  for (const id of DEFAULT_ORDER) if (!seen.has(id)) order.push(id);
  return order;
}

export function resolveStatusBarVisibility(
  overrides: Readonly<Record<string, boolean>>,
): Readonly<Record<StatusBarItemId, boolean>> {
  return Object.fromEntries(
    STATUS_BAR_ITEMS.map((item) => [item.id, overrides[item.id] ?? item.defaultVisible]),
  ) as Record<StatusBarItemId, boolean>;
}

/** The chips to draw, in order, with the group each sits in. */
export function visibleStatusBarItems(
  settings: StatusBarItemSettings,
): ReadonlyArray<{ readonly id: StatusBarItemId; readonly group: StatusBarGroup }> {
  const visibility = resolveStatusBarVisibility(settings.statusBarItems);
  return resolveStatusBarOrder(settings.statusBarOrder)
    .filter((id) => visibility[id])
    .map((id) => ({ id, group: STATUS_BAR_ITEMS.find((item) => item.id === id)!.group }));
}

/** Moves a chip up (-1) or down (+1) one place, and returns the whole order to save. */
export function moveStatusBarItem(
  saved: ReadonlyArray<string>,
  id: StatusBarItemId,
  delta: -1 | 1,
): ReadonlyArray<StatusBarItemId> {
  const order = [...resolveStatusBarOrder(saved)];
  const from = order.indexOf(id);
  const to = from + delta;
  if (from < 0 || to < 0 || to >= order.length) return order;
  [order[from], order[to]] = [order[to]!, order[from]!];
  return order;
}

/** Stores only choices that differ from the default, so a later default change reaches everyone else. */
export function setStatusBarItemVisible(
  overrides: Readonly<Record<string, boolean>>,
  id: StatusBarItemId,
  visible: boolean,
): Record<string, boolean> {
  const { [id]: _previous, ...rest } = overrides;
  const item = STATUS_BAR_ITEMS.find((candidate) => candidate.id === id)!;
  return visible === item.defaultVisible ? rest : { ...rest, [id]: visible };
}

export function isDefaultStatusBar(settings: StatusBarItemSettings): boolean {
  const order = resolveStatusBarOrder(settings.statusBarOrder);
  const visibility = resolveStatusBarVisibility(settings.statusBarItems);
  return (
    order.every((id, index) => id === DEFAULT_ORDER[index]) &&
    STATUS_BAR_ITEMS.every((item) => visibility[item.id] === item.defaultVisible)
  );
}

export const RESET_STATUS_BAR = {
  statusBarItems: {},
  statusBarOrder: [],
} satisfies Partial<ClientSettings>;
