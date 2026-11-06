// The screenshots need the app's styles; the browser project does not load them by default.
import "../../../index.css";

import type { ReactNode } from "react";
import { expect, it, vi } from "vite-plus/test";
import { page, userEvent } from "vite-plus/test/browser";

import { render } from "../../../../test/render";
import type { SidebarThreadSummary } from "../../../types";
import { resolveSidebarThreadStatus } from "../../Sidebar.logic";
import { CardPeek } from "./CardPeek";
import { BranchCardRow } from "./OctetSidebar";
import { groupIntoBranchCards } from "./octetSidebar.logic";

const NOW = Date.parse("2026-11-04T12:00:00.000Z");

function shell(id: string, overrides: Partial<Record<keyof SidebarThreadSummary, unknown>>) {
  return {
    id,
    environmentId: "env",
    projectId: "project",
    title: `Thread ${id}`,
    branch: "main",
    worktreePath: null,
    providerInstanceId: "codex",
    providerInstanceHistory: ["codex"],
    modelSelection: { instanceId: "codex" },
    runtime: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    pendingSubagentRequest: null,
    pendingGuestMessageCount: 0,
    blockedOnThreadWait: false,
    latestUserMessageAt: null,
    updatedAt: "2026-11-04T11:00:00.000Z",
    ...overrides,
  } as unknown as SidebarThreadSummary;
}

function Frame(props: { children: ReactNode }) {
  // T3's sidebar tokens apply inside the sidebar; borrow its background.
  return (
    <ul
      data-testid="frame"
      className="bg-sidebar text-sidebar-foreground"
      style={{ width: 260, padding: 8 }}
    >
      {props.children}
    </ul>
  );
}

it("draws a branch as T3's thread row with the branch's loudest status", async () => {
  const [card] = groupIntoBranchCards(
    [
      shell("a", {
        title: "Bash: cd ~/Developer/locklandia && pnpm test",
        runtime: { status: "running" },
        updatedAt: "2026-11-04T11:37:00.000Z",
      }),
      shell("b", { title: "The script is written", hasPendingApprovals: true }),
      shell("c", {
        title: "Focus-based app unblock suggestions",
        updatedAt: "2026-11-03T09:00:00.000Z",
      }),
    ],
    resolveSidebarThreadStatus,
  );
  await using screen = await render(
    <Frame>
      <BranchCardRow
        card={card!}
        routeThreadKey={null}
        nowMs={NOW}
        providerEntries={new Map()}
        onOpen={vi.fn()}
        onNewThread={vi.fn()}
      />
    </Frame>,
  );
  // Titled after the newest thread, loud with the approval another thread waits on.
  await expect
    .element(screen.getByText("Bash: cd ~/Developer/locklandia && pnpm test"))
    .toBeInTheDocument();
  await expect.element(screen.getByText("Approval")).toBeInTheDocument();
  await expect.element(screen.getByText("main")).toBeInTheDocument();
  await page.screenshot({
    path: "__screenshots__/octet-branch-card.png",
    element: screen.getByTestId("frame"),
  });
});

it("shows a quiet branch's age instead of a status, and opens its thread", async () => {
  const [card] = groupIntoBranchCards(
    [shell("solo", { title: "T3 Code fork or port", branch: "master" })],
    resolveSidebarThreadStatus,
  );
  const onOpen = vi.fn();
  await using screen = await render(
    <Frame>
      <BranchCardRow
        card={card!}
        routeThreadKey={null}
        nowMs={NOW}
        providerEntries={new Map()}
        onOpen={onOpen}
      />
    </Frame>,
  );
  await expect.element(screen.getByText("1h")).toBeInTheDocument();
  await screen.getByText("T3 Code fork or port").click();
  expect(onOpen).toHaveBeenCalledWith(card!.threads[0]);
  await page.screenshot({
    path: "__screenshots__/octet-branch-card-solo.png",
    element: screen.getByTestId("frame"),
  });
});

it("draws the servers a branch started under its card", async () => {
  const [card] = groupIntoBranchCards(
    [shell("s", { title: "Add pricing page", branch: "feat/pricing" })],
    resolveSidebarThreadStatus,
  );
  const server = (port: number, processName: string) =>
    ({
      host: "localhost",
      port,
      url: `http://localhost:${port}`,
      processName,
      pid: port,
      terminal: null,
    }) as never;
  await using screen = await render(
    <Frame>
      <BranchCardRow
        card={card!}
        routeThreadKey={null}
        nowMs={NOW}
        providerEntries={new Map()}
        onOpen={vi.fn()}
        servers={[server(3000, "next-server"), server(5173, "vite"), server(5432, "postgres"), server(4000, "node"), server(9999, "mystery")]}
      />
    </Frame>,
  );
  await expect.element(page.getByTestId("octet-service-ports")).toBeVisible();
  await expect.element(page.getByTestId("frame")).toMatchScreenshot("octet-branch-card-servers");
});

it("peeks at every thread on a card when hovered, and opens one from the peek", async () => {
  const [card] = groupIntoBranchCards(
    [
      shell("a", { title: "Fix the sidebar", updatedAt: "2026-11-04T11:37:00.000Z" }),
      shell("b", { title: "Review the PR", hasPendingApprovals: true }),
    ],
    resolveSidebarThreadStatus,
  );
  const onOpen = vi.fn();
  await using screen = await render(
    <Frame>
      <BranchCardRow
        card={card!}
        routeThreadKey={null}
        nowMs={NOW}
        providerEntries={new Map()}
        onOpen={vi.fn()}
        peek={<CardPeek card={card!} onOpen={onOpen} />}
      />
    </Frame>,
  );
  await screen.getByTestId("octet-branch-card").hover();
  await expect.element(page.getByTestId("octet-card-peek")).toBeVisible();
  // The thread waiting on approval is listed first.
  const rows = page.getByTestId("octet-card-peek").getByRole("button").elements();
  expect(rows[0]?.textContent).toContain("Review the PR");
  await page.getByTestId("octet-card-peek").getByText("Fix the sidebar").click();
  expect(onOpen).toHaveBeenCalledWith(card!.threads.find((thread) => thread.id === "a"));
});

it("swaps the title for T3's rename input, and right-click asks for the thread menu", async () => {
  const [card] = groupIntoBranchCards(
    [shell("r", { title: "Old name" })],
    resolveSidebarThreadStatus,
  );
  const onContextMenu = vi.fn();
  const onCommit = vi.fn();
  await using screen = await render(
    <Frame>
      <BranchCardRow
        card={card!}
        routeThreadKey={null}
        nowMs={NOW}
        providerEntries={new Map()}
        onOpen={vi.fn()}
        onContextMenu={onContextMenu}
        rename={{ title: "New name", onChange: vi.fn(), onCommit, onCancel: vi.fn() }}
      />
    </Frame>,
  );
  const input = page.getByRole("textbox", { name: "Thread title" });
  await expect.element(input).toHaveValue("New name");
  await input.click();
  await userEvent.keyboard("{Enter}");
  expect(onCommit).toHaveBeenCalled();
  await screen.getByTestId("octet-branch-card").click({ button: "right" });
  expect(onContextMenu).toHaveBeenCalled();
});
