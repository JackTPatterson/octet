import "../index.css";
import { expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";
import {
  EnvironmentId,
  ThreadId,
  TurnItemId,
  NodeId,
  ProviderDriverKind,
  ProviderInstanceId,
  type OrchestrationV2TurnItem,
} from "@t3tools/contracts";
import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { Atom } from "effect/reactivity";
import * as DateTime from "effect/DateTime";
import { render } from "../../test/render";
import { environmentThreadDetails } from "~/state/threads";
import * as todoFile from "./octet/todos/useProjectTodoFile";
vi.mock("./octet/todos/useProjectTodoFile", () => ({ useProjectTodoFile: vi.fn() }));
import { RightPanelEmptyState } from "./RightPanelTabs";
import type { SurfaceActivityContext } from "./SurfaceActivity";

it("shows live work and unfinished items in the launcher, and clears the cues when they finish", async () => {
  const ref = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("thread"));
  const agent: Extract<OrchestrationV2TurnItem, { type: "subagent" }> = {
    id: TurnItemId.make("agent"),
    threadId: ref.threadId,
    runId: null,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 0,
    type: "subagent",
    subagentId: NodeId.make("agent"),
    origin: "provider_native",
    driver: ProviderDriverKind.make("codex"),
    providerInstanceId: ProviderInstanceId.make("codex"),
    childThreadId: null,
    title: "Review",
    prompt: "Review",
    result: null,
    status: "running",
    startedAt: null,
    completedAt: null,
    updatedAt: DateTime.makeUnsafe("2026-11-06T12:00:00Z"),
  };
  const wasDark = document.documentElement.classList.contains("dark");
  using _appearance = {
    [Symbol.dispose]() {
      document.documentElement.classList.toggle("dark", wasDark);
    },
  };
  document.documentElement.classList.add("dark");
  using projection = vi.spyOn(environmentThreadDetails, "quietThreadAtom").mockReturnValue(
    Atom.make({
      projection: {
        turnItems: [
          agent,
          {
            ...agent,
            id: TurnItemId.make("second"),
            subagentId: NodeId.make("second"),
            driver: ProviderDriverKind.make("claudeAgent"),
          },
          { ...agent, id: TurnItemId.make("third"), subagentId: NodeId.make("third") },
        ],
      },
    }) as never,
  );
  const todos = vi
    .mocked(todoFile.useProjectTodoFile)
    .mockReset()
    .mockReturnValue({
      fileName: "TODO.md",
      contents: "- [ ] Build\n- [x] Done\n- [~] Verify",
      loaded: true,
      refresh: () => {},
    });
  const context: SurfaceActivityContext = {
    threadRef: ref,
    cwd: "/work",
    tasks: [
      { taskId: "script", kind: "command", description: "pnpm build" },
      { taskId: "monitor", kind: "monitor", description: "tail -f build.log" },
    ],
    pullRequest: null,
    linkedPullRequests: 2,
    changedFiles: 4,
    openFiles: 1,
    browserTabs: 0,
    devices: 1,
    configuredUrls: [],
  };
  const onAdd = () => {};
  const launcher = (activityContext: SurfaceActivityContext) => (
    <div className="dark bg-background text-foreground flex" style={{ width: 390, height: 410 }}>
      <RightPanelEmptyState
        activityContext={activityContext}
        onAddBrowser={onAdd}
        onAddBrowserInProfile={onAdd}
        browserProfiles={[]}
        onAddDiff={onAdd}
        onAddFiles={onAdd}
        onAddPullRequest={onAdd}
        onAddPullRequests={onAdd}
        onAddCi={onAdd}
        onAddOverview={onAdd}
        onAddTodos={onAdd}
        onAddDevice={onAdd}
        browserAvailable={false}
        diffAvailable
        filesAvailable
        pullRequestAvailable={false}
        pullRequestsAvailable
        ciAvailable={false}
        overviewAvailable
        todosAvailable
        deviceAvailable
        sideChatAvailable={false}
        sideChatDisabledReason={null}
      />
    </div>
  );
  await using screen = await render(launcher(context));
  await expect
    .element(page.getByLabelText("3 active agents, 1 commands, 1 monitors, 0 background tasks"))
    .toBeVisible();
  await expect.element(page.getByLabelText("2 unfinished TODO items")).toBeVisible();
  await page.screenshot({
    path: "__screenshots__/surface-activity.png",
    element: screen.container.firstElementChild as HTMLElement,
  });
  projection.mockReturnValue(
    Atom.make({ projection: { turnItems: [{ ...agent, status: "completed" }] } }) as never,
  );
  todos.mockReturnValue({
    fileName: "TODO.md",
    contents: "- [x] Build\n- [x] Done\n- [x] Verify",
    loaded: true,
    refresh: () => {},
  });
  await screen.rerender(launcher({ ...context, tasks: [] }));
  expect(page.getByLabelText("2 unfinished TODO items").elements()).toHaveLength(0);
  expect(
    page.getByLabelText("3 active agents, 1 commands, 1 monitors, 0 background tasks").elements(),
  ).toHaveLength(0);
});
