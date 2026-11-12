import {
  NodeId,
  PlanId,
  RunId,
  ThreadId,
  TurnItemId,
  type OrchestrationV2TurnItem,
} from "@t3tools/contracts";
import { DateTime } from "effect";
import { expect, it } from "vite-plus/test";
import { render } from "../../../test/render";
import { ThreadTasksCard } from "./ThreadTasksCard";

function tasks(
  text: string,
  status: "pending" | "running" | "completed",
  date: string,
): OrchestrationV2TurnItem {
  const now = DateTime.makeUnsafe(date);
  return {
    id: TurnItemId.make(text),
    threadId: ThreadId.make("thread"),
    runId: RunId.make("run"),
    nodeId: NodeId.make("node"),
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 0,
    status: "completed",
    title: null,
    startedAt: now,
    completedAt: now,
    updatedAt: now,
    type: "todo_list",
    planId: PlanId.make("plan"),
    steps: [{ id: "step", text, status }],
  };
}

it("shows the latest task update, then refreshes its completion and clears on a thread without tasks", async () => {
  const older = tasks("Old task", "pending", "2026-11-08T00:00:00Z");
  const current = tasks(
    "Create scenic sky and landscape assets",
    "running",
    "2026-11-09T00:00:00Z",
  );
  await using screen = await render(
    <ThreadTasksCard projection={{ turnItems: [current, older] }} />,
  );
  await expect.element(screen.getByText("Create scenic sky and landscape assets")).toBeVisible();
  await expect.element(screen.getByText("Old task")).not.toBeInTheDocument();
  await expect.element(screen.getByRole("button", { name: /Tasks\s*0\s*\/\s*1/ })).toBeVisible();
  await screen.rerender(
    <ThreadTasksCard
      projection={{
        turnItems: [
          tasks("Create scenic sky and landscape assets", "completed", "2026-11-09T01:00:00Z"),
        ],
      }}
    />,
  );
  await expect.element(screen.getByRole("button", { name: /Tasks\s*1\s*\/\s*1/ })).toBeVisible();
  if (current.type !== "todo_list") throw new Error("Expected task fixture");
  await screen.rerender(
    <ThreadTasksCard projection={{ turnItems: [{ ...current, steps: [] }] }} />,
  );
  await expect.element(screen.getByRole("button", { name: /Tasks/ })).not.toBeInTheDocument();
  await screen.rerender(<ThreadTasksCard projection={null} />);
  await expect.element(screen.getByRole("button", { name: /Tasks/ })).not.toBeInTheDocument();
  await expect
    .element(screen.getByText("Create scenic sky and landscape assets"))
    .not.toBeInTheDocument();
});
