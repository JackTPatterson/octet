import { describe, expect, it } from "vite-plus/test";

import {
  backgroundTasks,
  buildOverviewTree,
  countOverviewNodes,
  hasWorkingSubagent,
  subagentItems,
  type OverviewTask,
} from "./overview.logic";

const task = (taskId: string, kind: OverviewTask["kind"], parentTaskId?: string): OverviewTask => ({
  taskId,
  kind,
  parentTaskId,
});

describe("buildOverviewTree", () => {
  it("nests work under the task that started it", () => {
    const forest = buildOverviewTree([
      task("job", "background_task"),
      task("dev", "command", "job"),
      task("watch", "monitor", "job"),
      task("solo", "command"),
    ]);
    expect(forest.map((node) => node.task.taskId)).toEqual(["solo", "job"]);
    expect(forest[1]!.children.map((node) => node.task.taskId)).toEqual(["dev", "watch"]);
    expect(countOverviewNodes(forest)).toBe(4);
  });

  it("shows work whose parent is gone as a root", () => {
    const forest = buildOverviewTree([task("dev", "command", "finished-parent")]);
    expect(forest.map((node) => node.task.taskId)).toEqual(["dev"]);
  });

  it("puts subagents before commands, monitors and tasks", () => {
    const forest = buildOverviewTree([
      task("bg", "background_task"),
      task("cmd", "command"),
      task("sub", "subagent"),
      task("mon", "monitor"),
    ]);
    expect(forest.map((node) => node.task.kind)).toEqual([
      "subagent",
      "command",
      "monitor",
      "background_task",
    ]);
  });

  it("survives a task that is its own parent and a parent cycle", () => {
    expect(countOverviewNodes(buildOverviewTree([task("a", "command", "a")]))).toBe(1);
    expect(
      countOverviewNodes(buildOverviewTree([task("a", "command", "b"), task("b", "command", "a")])),
    ).toBe(2);
  });
});

describe("subagentItems", () => {
  const sub = (id: string, status: string, completedAt: number | null = null) => ({
    id,
    type: "subagent",
    status,
    completedAt,
  });

  it("lists working subagents first, then the rest newest first, and skips other items", () => {
    const sorted = subagentItems([
      sub("old", "completed", 100),
      { id: "cmd", type: "command_execution", status: "running", completedAt: null },
      sub("beta", "running"),
      sub("new", "failed", 300),
      sub("gamma", "pending"),
    ]);
    expect(sorted.map((item) => item.id)).toEqual(["beta", "gamma", "new", "old"]);
  });

  it("knows whether anything is still working", () => {
    expect(hasWorkingSubagent([sub("a", "completed", 1)])).toBe(false);
    expect(hasWorkingSubagent([sub("a", "completed", 1), sub("b", "waiting")])).toBe(true);
    expect(hasWorkingSubagent([{ type: "command_execution", status: "running" }])).toBe(false);
  });
});

describe("backgroundTasks", () => {
  it("drops subagents, which have their own list", () => {
    expect(
      backgroundTasks([task("s", "subagent"), task("c", "command"), task("m", "monitor")]).map(
        (entry) => entry.taskId,
      ),
    ).toEqual(["c", "m"]);
  });
});
