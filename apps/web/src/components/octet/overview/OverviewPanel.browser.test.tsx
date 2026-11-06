import "../../../index.css";

import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

import { render } from "../../../../test/render";
import { OverviewPanel } from "./OverviewPanel";

const threadRef = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("thread"));

const tasks = [
  { taskId: "job", kind: "background_task", description: "Build the app" },
  { taskId: "dev", kind: "command", description: "pnpm dev", parentTaskId: "job" },
  { taskId: "watch", kind: "monitor", description: "tail -f build.log" },
  { taskId: "sub", kind: "subagent", description: "Audit the sidebar", childThreadId: "child" },
] as never;

function panel(overrides: Partial<Parameters<typeof OverviewPanel>[0]> = {}) {
  return (
    <div style={{ width: 380, height: 320 }} className="bg-background text-foreground">
      <OverviewPanel
        threadRef={threadRef}
        agentTitle="Fix the sidebar"
        agentStatus="Working"
        tasks={tasks}
        stopDisabled={false}
        stopping={false}
        onStop={async () => undefined}
        onOpenThread={() => undefined}
        {...overrides}
      />
    </div>
  );
}

it("lists background work as a tree under the agent and stops it all", async () => {
  const onStop = vi.fn(async () => undefined);
  await using screen = await render(panel({ onStop }));

  await expect.element(page.getByText("Fix the sidebar")).toBeVisible();
  await expect.element(page.getByText("Background")).toBeVisible();
  const job = screen.container.querySelector('[data-overview-task="job"]')!;
  expect(job.querySelector('[data-overview-task="dev"]')).not.toBeNull();
  expect(screen.container.querySelector('[data-overview-task="watch"]')).not.toBeNull();
  // Subagents have their own list, so the pending subagent task is not a background row.
  expect(screen.container.querySelector('[data-overview-task="sub"]')).toBeNull();
  await page.screenshot({
    path: "__screenshots__/octet-overview.png",
    element: screen.container.firstElementChild as HTMLElement,
  });

  await page.getByRole("button", { name: "Stop all" }).click();
  expect(onStop).toHaveBeenCalledTimes(1);
});

it("folds the background list away", async () => {
  await using screen = await render(panel());
  await page.getByRole("button", { name: /Background/ }).click();
  expect(screen.container.querySelector('[data-overview-task="job"]')).toBeNull();
});

it("says so when nothing is running, and offers no stop", async () => {
  await using _screen = await render(panel({ tasks: [] as never }));
  await expect.element(page.getByText("Nothing running in the background.")).toBeVisible();
  expect(page.getByRole("button", { name: "Stop all" }).elements()).toHaveLength(0);
});
