import "../../../index.css";

import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { beforeEach, expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

import { act, render } from "../../../../test/render";

const fixture = vi.hoisted(() => ({
  shells: [] as unknown[],
  navigations: [] as unknown[],
  newThreads: [] as unknown[],
  settled: [] as unknown[],
}));

vi.mock("../../../state/entities", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../../state/entities")>()),
  useQuietThreadShells: () => fixture.shells,
}));
vi.mock("../../Sidebar", () => ({
  useSidebarLookups: () => ({ providerEntriesByEnvironment: new Map() }),
}));
vi.mock("../../../hooks/useHandleNewThread", () => ({
  useHandleNewThread: () => ({
    handleNewThread: async (...args: unknown[]) => {
      fixture.newThreads.push(args);
    },
  }),
}));
vi.mock("../../../hooks/useThreadActions", () => ({
  useThreadActions: () => ({
    settleThread: async (ref: unknown) => {
      fixture.settled.push(ref);
    },
  }),
}));
vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useRouter: () => ({
    navigate: async (options: unknown) => {
      fixture.navigations.push(options);
    },
  }),
}));

import { AgentTabBar } from "./AgentTabBar";

const shell = (id: string, title: string, extra: Record<string, unknown> = {}) => ({
  id,
  environmentId: "env",
  projectId: "project",
  title,
  branch: "master",
  worktreePath: null,
  createdAt: "2026-11-05T10:00:00.000Z",
  hasPendingApprovals: false,
  hasPendingUserInput: false,
  pendingSubagentRequest: null,
  pendingGuestMessageCount: 0,
  blockedOnThreadWait: false,
  runtime: null,
  lineage: {},
  ...extra,
});

beforeEach(() => {
  fixture.navigations = [];
  fixture.newThreads = [];
  fixture.settled = [];
  fixture.shells = [
    shell("a", "Fix the sidebar", { createdAt: "2026-11-05T09:00:00.000Z" }),
    shell("b", "Status bar chips", {
      createdAt: "2026-11-05T09:30:00.000Z",
      hasPendingApprovals: true,
    }),
    shell("c", "Other branch", { branch: "feat" }),
  ];
});

const threadRef = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("a"));

it("shows the branch's agents as tabs, marks the current one, and flags what needs you", async () => {
  await using screen = await render(
    <div style={{ width: 560 }} className="bg-background text-foreground">
      <AgentTabBar threadRef={threadRef} />
    </div>,
  );
  const tabs = page.getByRole("tab");
  await expect.element(tabs.first()).toBeVisible();
  expect(tabs.elements()).toHaveLength(2);
  await expect.element(page.getByRole("tab", { name: /Fix the sidebar/ })).toHaveAttribute("aria-selected", "true");
  expect(screen.container.querySelectorAll(".bg-amber-500")).toHaveLength(1);
  await page.screenshot({
    path: "__screenshots__/octet-agent-tabs.png",
    element: screen.container.firstElementChild as HTMLElement,
  });
});

it("opens another agent's thread, and adds one on the same branch", async () => {
  await using _screen = await render(<AgentTabBar threadRef={threadRef} />);
  await page.getByRole("tab", { name: /Status bar chips/ }).click();
  expect(fixture.navigations).toHaveLength(1);
  expect(fixture.navigations[0]).toMatchObject({ to: "/$environmentId/$threadId" });

  await page.getByRole("button", { name: "New agent on this branch" }).click();
  expect(fixture.newThreads).toHaveLength(1);
  expect(fixture.newThreads[0]).toMatchObject([
    expect.anything(),
    { branch: "master", worktreePath: null, envMode: "local" },
  ]);
});

it("closes a tab by settling its thread, and moves to the neighbouring tab when it was the open one", async () => {
  await using _screen = await render(<AgentTabBar threadRef={threadRef} />);
  // Closing the tab that is not open stays where we are.
  await page.getByRole("button", { name: "Close Status bar chips" }).click();
  expect(fixture.settled).toEqual([{ environmentId: "env", threadId: "b" }]);
  expect(fixture.navigations).toHaveLength(0);

  // Closing the open one (the first) goes to the next tab first.
  await page.getByRole("button", { name: "Close Fix the sidebar" }).click();
  expect(fixture.navigations[0]).toMatchObject({ params: { threadId: "b" } });
  expect(fixture.settled).toHaveLength(2);
});

it("closes with a middle-click", async () => {
  await using screen = await render(<AgentTabBar threadRef={threadRef} />);
  const tab = screen.container.querySelector('[data-tab-id="b"]')!;
  await act(() => {
    tab.dispatchEvent(new MouseEvent("auxclick", { bubbles: true, cancelable: true, button: 1 }));
  });
  expect(fixture.settled).toEqual([{ environmentId: "env", threadId: "b" }]);
});

it("cannot close the only tab", async () => {
  fixture.shells = [shell("a", "Only agent")];
  await using _screen = await render(<AgentTabBar threadRef={threadRef} />);
  await expect.element(page.getByRole("tab", { name: /Only agent/ })).toBeVisible();
  expect(page.getByRole("button", { name: /Close/ }).elements()).toHaveLength(0);
});

it("moves between tabs with the arrow keys", async () => {
  await using _screen = await render(<AgentTabBar threadRef={threadRef} />);
  const first = page.getByRole("tab", { name: /Fix the sidebar/ });
  first.element().focus();
  await first.element().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  await vi.waitFor(() => expect(fixture.navigations[0]).toMatchObject({ params: { threadId: "b" } }));
});

it("gives a lone tab room for its title", async () => {
  fixture.shells = [shell("a", "Test Agent and Subagent View of the whole thing")];
  await using screen = await render(
    <div style={{ width: 900 }} className="bg-background text-foreground">
      <AgentTabBar threadRef={threadRef} />
    </div>,
  );
  const tab = page.getByRole("tab").element() as HTMLElement;
  expect(tab.getBoundingClientRect().width).toBeGreaterThan(180);
  await page.screenshot({
    path: "__screenshots__/octet-agent-tabs-single.png",
    element: screen.container.firstElementChild as HTMLElement,
  });
});

it("shows an unsent draft as the last tab, and leaves the plus off while it is open", async () => {
  const draftRef = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("draft-1"));
  await using _screen = await render(
    <AgentTabBar threadRef={draftRef} draft={{ projectId: "project", branch: "master", worktreePath: null }} />,
  );
  const tabs = page.getByRole("tab");
  await expect.element(tabs.last()).toHaveTextContent("New thread");
  await expect.element(tabs.last()).toHaveAttribute("aria-selected", "true");
  expect(tabs.elements()).toHaveLength(3);
  await expect.element(page.getByRole("button", { name: "New agent on this branch" })).toBeDisabled();
});
