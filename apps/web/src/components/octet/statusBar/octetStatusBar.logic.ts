import type { ThreadStatusPill } from "../../Sidebar.logic";

/**
 * Octet's bottom status bar is a row of quiet chips about the thread in
 * view (native Octet's footer). This file decides what each one says; the
 * component draws them with T3's own classes.
 */

export type AgentChipState = "working" | "needs-you" | "failed" | "idle";

/** How the agent chip reads: "Claude Code idle", "Codex working"... */
export function agentChipState(pill: Pick<ThreadStatusPill, "label"> | null): AgentChipState {
  switch (pill?.label) {
    case "Working":
    case "Connecting":
      return "working";
    case "Pending Approval":
    case "Awaiting Input":
    case "Guest Request":
      return "needs-you";
    case "Failed":
      return "failed";
    default:
      return "idle";
  }
}

export function agentChipText(name: string, state: AgentChipState): string {
  switch (state) {
    case "needs-you":
      return `${name} needs you`;
    case "working":
      return `${name} working`;
    case "failed":
      return `${name} failed`;
    case "idle":
      return `${name} idle`;
  }
}

export interface ChangesChip {
  readonly files: number;
  readonly insertions: number;
  readonly deletions: number;
}

/** The working tree's totals, or null when there is nothing to show. */
export function changesChip(
  workingTree: { files: readonly unknown[]; insertions: number; deletions: number } | null,
): ChangesChip | null {
  if (!workingTree || workingTree.files.length === 0) return null;
  return {
    files: workingTree.files.length,
    insertions: workingTree.insertions,
    deletions: workingTree.deletions,
  };
}

/** The chip's tooltip. */
export function changesChipTitle(chip: ChangesChip): string {
  const files = `${chip.files} changed ${chip.files === 1 ? "file" : "files"}`;
  return `${files} in the working tree, ${chip.insertions} lines added and ${chip.deletions} removed`;
}

export type CiChipState = "failed" | "running" | "passed" | "cancelled";

export interface CiChip {
  readonly state: CiChipState;
  readonly total: number;
  readonly finished: number;
  readonly failed: number;
}

/** CI for the branch's pull request, rolled up from its checks. */
export function ciChip(
  checks: ReadonlyArray<{ status: string }> | null,
): CiChip | null {
  if (!checks || checks.length === 0) return null;
  const failed = checks.filter((check) => check.status === "failure").length;
  const cancelled = checks.filter((check) => check.status === "cancelled").length;
  const running = checks.filter(
    (check) => check.status === "pending" || check.status === "action-required",
  ).length;
  const finished = checks.length - running;
  const state: CiChipState =
    failed > 0 ? "failed" : running > 0 ? "running" : cancelled > 0 ? "cancelled" : "passed";
  return { state, total: checks.length, finished, failed };
}

export function ciChipText(chip: CiChip): string {
  switch (chip.state) {
    case "failed":
      return `CI ${chip.failed} failed`;
    case "running":
      return `CI ${chip.finished}/${chip.total}`;
    case "cancelled":
      return "CI cancelled";
    case "passed":
      return "CI";
  }
}

/** The last folders of a path, so a deep project path still fits a chip. */
export function directoryChipLabel(path: string, segments = 2): string {
  const parts = path.split(/[\\/]+/u).filter((part) => part.length > 0);
  if (parts.length === 0) return path;
  return parts.slice(-segments).join("/");
}

/** The worktree's folder name, or null when the thread runs in the project's own checkout. */
export function worktreeChipLabel(worktreePath: string | null | undefined): string | null {
  if (!worktreePath) return null;
  const parts = worktreePath.split(/[\\/]+/u).filter((part) => part.length > 0);
  return parts.at(-1) ?? null;
}

export interface PortsChip {
  readonly first: { readonly port: number };
  readonly extra: number;
}

/** The servers the thread started, as "localhost:3000 +2": the first, and how many more. */
export function portsChip(servers: ReadonlyArray<{ readonly port: number }>): PortsChip | null {
  const [first] = servers;
  if (!first) return null;
  return { first, extra: servers.length - 1 };
}

export function portsChipText(chip: PortsChip): string {
  return `localhost:${chip.first.port}${chip.extra > 0 ? ` +${chip.extra}` : ""}`;
}

/** The icon slug (in `sidebar/serviceIconPaths.ts`) for a runtime id the server reports. */
export function runtimeIconSlug(id: string): string | null {
  return id === "node" ? "nodedotjs" : id;
}

