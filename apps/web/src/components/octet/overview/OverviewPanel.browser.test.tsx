import "../../../index.css";

import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import {
  EnvironmentId,
  ThreadId,
  TurnItemId,
  NodeId,
  ProviderInstanceId,
  ProviderDriverKind,
  type OrchestrationV2TurnItem,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { Atom } from "effect/reactivity";
import { environmentThreadDetails } from "../../../state/threads";
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
  await page.getByRole("button", { name: "Collapse agent tree" }).click();
  expect(screen.container.querySelector('[data-overview-task="job"]')).toBeNull();
});

it("says so when nothing is running, and offers no stop", async () => {
  await using screen = await render(panel({ tasks: [] as never }));
  await expect.element(page.getByText("No activity yet")).toBeVisible();
  expect(page.getByRole("button", { name: "Stop all" }).elements()).toHaveLength(0);
  await page.screenshot({
    path: "__screenshots__/octet-overview-empty.png",
    element: screen.container.firstElementChild as HTMLElement,
  });
});

it("follows child threads into nested branches, folds them, and opens their conversations", async () => {
  const now = DateTime.makeUnsafe("2026-11-06T12:00:00Z");
  const agent = (
    id: string,
    owner: string,
    title: string,
    child: string,
  ): Extract<OrchestrationV2TurnItem, { type: "subagent" }> => ({
    id: TurnItemId.make(id),
    threadId: ThreadId.make(owner),
    runId: null,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 0,
    type: "subagent",
    subagentId: NodeId.make(id),
    origin: "provider_native",
    driver: ProviderDriverKind.make("codex"),
    providerInstanceId: ProviderInstanceId.make("codex"),
    childThreadId: ThreadId.make(child),
    title,
    prompt: title,
    result: null,
    status: "completed",
    startedAt: now,
    completedAt: now,
    updatedAt: now,
  });
  const rows: Record<string, OrchestrationV2TurnItem[]> = {
    thread: [agent("lead", "thread", "Panel demo", "lead-thread")],
    "lead-thread": [
      agent("sidebar", "lead-thread", "Sidebar check", "sidebar-thread"),
      agent("composer", "lead-thread", "Composer check", "composer-thread"),
    ],
    "sidebar-thread": [
      agent("audit", "sidebar-thread", "Nested audit", "thread"),
      {
        ...agent("script", "sidebar-thread", "", "unused"),
        type: "command_execution",
        input: "pnpm test",
        status: "running",
        completedAt: null,
      },
      {
        ...agent("monitor", "sidebar-thread", "", "unused"),
        type: "command_execution",
        input: "tail -f build.log",
        monitor: true,
        status: "running",
        completedAt: null,
      },
    ],
  };
  const atoms = Atom.family((id: string) =>
    Atom.make({
      projection: { turnItems: rows[id] ?? [], subagents: [] },
    }),
  );
  using _full = vi
    .spyOn(environmentThreadDetails, "threadAtom")
    .mockImplementation((ref) => atoms(ref.threadId) as never);
  using _quiet = vi
    .spyOn(environmentThreadDetails, "quietThreadAtom")
    .mockImplementation((ref) => atoms(ref.threadId) as never);
  const onOpenThread = vi.fn();
  await using screen = await render(panel({ tasks: [], onOpenThread }));
  // Every top-level agent here has finished, so they fold into the Finished group.
  await page.getByRole("button", { name: /^Finished/ }).click();
  await expect
    .element(page.getByRole("button", { name: "Open Nested audit", exact: true }))
    .toBeVisible();
  const lead = screen.container.querySelector('[data-overview-agent="lead"]')!;
  const sidebar = lead.querySelector('[data-overview-agent="sidebar"]')!;
  expect(sidebar.querySelector('[data-overview-agent="audit"]')).not.toBeNull();
  expect(sidebar.querySelector('[data-overview-task="script"]')).not.toBeNull();
  expect(sidebar.querySelector('[data-overview-task="monitor"]')).not.toBeNull();
  expect(lead.querySelector('[data-overview-agent="composer"]')).not.toBeNull();
  expect(screen.container.querySelectorAll("[data-overview-agent]")).toHaveLength(4);
  const wasDark = document.documentElement.classList.contains("dark");
  using _appearance = {
    [Symbol.dispose]() {
      document.documentElement.classList.toggle("dark", wasDark);
    },
  };
  document.documentElement.classList.add("dark");
  await page.screenshot({
    path: "__screenshots__/octet-agent-tree.png",
    element: screen.container.firstElementChild as HTMLElement,
  });
  await page.getByRole("button", { name: "Collapse Sidebar check branches", exact: true }).click();
  expect(sidebar.querySelector('[data-overview-agent="audit"]')).toBeNull();
  await expect
    .element(page.getByRole("button", { name: "Open Composer check", exact: true }))
    .toBeVisible();
  await page.getByRole("button", { name: "Expand Sidebar check branches", exact: true }).click();
  await page.getByRole("button", { name: "Open Sidebar check", exact: true }).click();
  expect(onOpenThread).toHaveBeenCalledWith("sidebar-thread");
});
