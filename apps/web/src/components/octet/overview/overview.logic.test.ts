import * as DateTime from "effect/DateTime";
import { ThreadId, TurnItemId, type OrchestrationV2TurnItem } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  backgroundTasks,
  buildOverviewAgentTree,
  buildOverviewActivityTree,
  buildOverviewTree,
  countOverviewNodes,
  hasWorkingSubagent,
  isLiveNode,
  agentsOnly,
  collectWork,
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

describe("buildOverviewAgentTree", () => {
  it("keeps nested agents under their nearest agent ancestor, including tool wrappers", () => {
    const agents = [
      { id: "lead", subagentId: "lead-node", parentItemId: null },
      { id: "review", subagentId: "review-node", parentItemId: "spawn-tool" },
      { id: "check", subagentId: "check-node", parentItemId: "review" },
      { id: "orphan", subagentId: "orphan-node", parentItemId: "missing" },
    ];
    const forest = buildOverviewAgentTree(agents, [
      ...agents,
      { id: "spawn-tool", parentItemId: "lead" },
    ]);
    expect(forest.map((node) => node.task.agent.id)).toEqual(["lead", "orphan"]);
    expect(forest[0]!.children[0]!.task.agent.id).toBe("review");
    expect(forest[0]!.children[0]!.children[0]!.task.agent.id).toBe("check");
  });

  it("deduplicates agent updates and terminates malformed parent chains", () => {
    const agents = [
      { id: "new", subagentId: "lead-node", parentItemId: null },
      { id: "old", subagentId: "lead-node", parentItemId: null },
      { id: "child", subagentId: "child-node", parentItemId: "old" },
      { id: "orphan", subagentId: "orphan-node", parentItemId: "loop" },
    ];
    const forest = buildOverviewAgentTree(agents, [
      ...agents,
      { id: "loop", parentItemId: "loop" },
    ]);
    expect(countOverviewNodes(forest)).toBe(3);
    expect(forest[0]!.task.agent.id).toBe("new");
    expect(forest[0]!.children[0]!.task.agent.id).toBe("child");
    expect(forest[1]!.task.agent.id).toBe("orphan");
  });
});

describe("buildOverviewActivityTree", () => {
  it("merges background command reports, preserves ownership, and removes finished foreground work", () => {
    const command: Extract<OrchestrationV2TurnItem, { type: "command_execution" }> = {
      id: TurnItemId.make("script"),
      threadId: ThreadId.make("thread"),
      runId: null,
      nodeId: null,
      providerThreadId: null,
      providerTurnId: null,
      nativeItemRef: null,
      parentItemId: null,
      ordinal: 0,
      type: "command_execution",
      input: "pnpm build",
      title: "Build",
      status: "running",
      startedAt: null,
      completedAt: null,
      updatedAt: DateTime.makeUnsafe("2026-11-06T12:00:00Z"),
    };
    const forest = buildOverviewActivityTree(
      [
        command,
        { ...command, id: TurnItemId.make("finished"), status: "completed" },
        { ...command, id: TurnItemId.make("monitor"), monitor: true, parentItemId: command.id },
      ],
      [
        { taskId: "job", kind: "background_task", description: "Build app" },
        { taskId: "script", kind: "command", description: "pnpm build", parentTaskId: "job" },
      ],
    );
    expect(countOverviewNodes(forest)).toBe(3);
    expect(forest[0]!.task.taskId).toBe("job");
    expect(forest[0]!.children[0]!.task.taskId).toBe("script");
    expect(forest[0]!.children[0]!.children[0]!.task.kind).toBe("monitor");
  });

  it("drops work left running by an ended run and marks finished agents not live", () => {
    const base = {
      threadId: ThreadId.make("thread"),
      nodeId: null,
      providerThreadId: null,
      providerTurnId: null,
      nativeItemRef: null,
      parentItemId: null,
      ordinal: 0,
      startedAt: null,
      completedAt: null,
      updatedAt: DateTime.makeUnsafe("2026-11-06T12:00:00Z"),
    };
    const stale = {
      ...base,
      id: TurnItemId.make("stale"),
      runId: "run-old",
      type: "command_execution",
      input: "sleep 1",
      title: null,
      status: "running",
    } as unknown as OrchestrationV2TurnItem;
    const current = {
      ...stale,
      id: TurnItemId.make("current"),
      runId: "run-new",
    } as OrchestrationV2TurnItem;
    const runs = [
      { id: "run-old", status: "completed" },
      { id: "run-new", status: "running" },
    ];
    const forest = buildOverviewActivityTree([stale, current], [], runs);
    expect(forest.map((node) => node.task.taskId)).toEqual(["current"]);
    expect(forest.every(isLiveNode)).toBe(true);
    expect(buildOverviewActivityTree([stale], [], runs)).toEqual([]);
  });
});

describe("agentsOnly / collectWork", () => {
  it("splits a forest into its agents and the shells and monitors they run", () => {
    const agent = (id: string) =>
      ({ taskId: id, kind: "subagent", agent: { id }, live: true }) as never;
    const work = (id: string, kind: "command" | "monitor") =>
      ({ taskId: id, kind, label: id, startedAt: null, live: true }) as never;
    const forest = [
      {
        task: agent("lead"),
        children: [
          { task: work("ssh", "command"), children: [] },
          { task: agent("helper"), children: [{ task: work("tail", "monitor"), children: [] }] },
        ],
      },
      { task: work("wait", "command"), children: [] },
    ];
    expect(
      agentsOnly(forest).map((node) => [
        node.task.taskId,
        node.children.map((child) => child.task.taskId),
      ]),
    ).toEqual([["lead", ["helper"]]]);
    expect(collectWork(forest).map((task) => task.taskId)).toEqual(["ssh", "tail", "wait"]);
  });
});
