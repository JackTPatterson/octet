import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { AsyncResult } from "effect/reactivity";
import { expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

const state = vi.hoisted(() => ({
  data: null as unknown,
  error: null as string | null,
  refreshes: 0,
  actions: [] as unknown[],
}));

vi.mock(import("../../state/query"), async (original) => ({
  ...(await original()),
  useEnvironmentQuery: (() => ({
    data: state.data,
    error: state.error,
    isPending: false,
    refresh: () => {
      state.refreshes += 1;
    },
  })) as never,
}));
vi.mock(import("../../state/use-atom-command"), () => ({
  useAtomCommand: (() => async (value: { input: unknown }) => {
    state.actions.push(value.input);
    return AsyncResult.success({});
  }) as never,
}));

import { render } from "../../../test/render";
import { ToastProvider } from "../ui/toast";
import { McpServersDialog } from "./McpServersDialog";

const environmentId = EnvironmentId.make("environment");
const threadId = ThreadId.make("thread");

function dialog() {
  return (
    <ToastProvider timeout={0}>
      <McpServersDialog
        environmentId={environmentId}
        threadId={threadId}
        open
        onOpenChange={() => undefined}
      />
    </ToastProvider>
  );
}

it("lists the agent's servers with their status, tools and the provider's actions", async () => {
  state.actions = [];
  state.refreshes = 0;
  state.error = null;
  state.data = {
    driver: "claudeAgent",
    actions: { reconnect: true, toggle: true, login: false, reloadAll: false },
    servers: [
      {
        name: "github",
        status: "connected",
        scope: "user",
        tools: [{ name: "create_issue", description: "Open an issue" }],
      },
      { name: "claude.ai Notion", status: "needs-auth", scope: "claudeai", tools: [] },
      { name: "blender", status: "failed", error: "spawn blender ENOENT", tools: [] },
      { name: "rea", status: "disabled", tools: [] },
    ],
  };
  await using _screen = await render(dialog());
  await expect.element(page.getByText("Claude · 1 of 4 connected")).toBeVisible();
  await expect.element(page.getByText("spawn blender ENOENT")).toBeVisible();
  // A claude.ai connector signs in there; Claude has no sign-in of its own.
  await expect.element(page.getByRole("button", { name: "Open claude.ai" })).toBeVisible();
  await expect.element(page.getByRole("button", { name: "Enable" })).toBeVisible();

  await page.getByRole("button", { name: "Show github tools" }).click();
  await expect.element(page.getByText("create_issue")).toBeVisible();
  await expect.element(page.getByText("Open an issue")).toBeVisible();

  await page.getByRole("button", { name: "Reconnect" }).first().click();
  await vi.waitFor(() =>
    expect(state.actions).toEqual([{ threadId, server: "github", action: "reconnect" }]),
  );
  await vi.waitFor(() => expect(state.refreshes).toBe(1));
});

it("offers Codex's sign-in and config reload", async () => {
  state.actions = [];
  state.error = null;
  state.data = {
    driver: "codex",
    actions: { reconnect: false, toggle: false, login: true, reloadAll: true },
    servers: [{ name: "linear", status: "needs-auth", tools: [] }],
  };
  await using _screen = await render(dialog());
  await expect.element(page.getByText("Codex · 0 of 1 connected")).toBeVisible();
  await expect.element(page.getByRole("button", { name: "Sign in" })).toBeVisible();
  await expect.element(page.getByRole("button", { name: "Reconnect" })).not.toBeInTheDocument();
  await page.getByRole("button", { name: "Reload config" }).click();
  await vi.waitFor(() =>
    expect(state.actions).toEqual([{ threadId, server: "", action: "reload" }]),
  );
});

it("explains a thread whose agent isn't running", async () => {
  state.data = null;
  state.error =
    "This thread's agent isn't running. Send a message to start it, then run /mcp again.";
  await using _screen = await render(dialog());
  await expect
    .element(page.getByText("This thread's agent isn't running.", { exact: false }))
    .toBeVisible();
});
