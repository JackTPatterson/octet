import "../../../index.css";

import { EnvironmentId } from "@t3tools/contracts";
import { beforeEach, expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

import { render } from "../../../../test/render";

const fixture = vi.hoisted(() => ({ calls: [] as Array<{ kind: string; value: unknown }> }));

vi.mock("../../../state/server", () => ({
  serverEnvironment: {
    waitsLive: () => ({}),
    resolveWait: { kind: "resolve" },
    cancelWait: { kind: "cancel" },
    updateWait: { kind: "update" },
    createWait: { kind: "create" },
  },
}));
vi.mock("../../../state/query", () => ({
  useEnvironmentQuery: () => ({ data: null }),
}));
vi.mock("../../../state/use-atom-command", () => ({
  useAtomCommand: (command: { kind: string }) => async (value: unknown) => {
    fixture.calls.push({ kind: command.kind, value });
    return { _tag: "Success" };
  },
}));

import { WaitDialog } from "./WaitDialog";
import { WaitRows } from "./WaitRows";

const env = EnvironmentId.make("env");

const wait = (id: string, overrides: Record<string, unknown> = {}) =>
  ({
    id,
    title: `Wait ${id}`,
    condition: { type: "manual" },
    next: "",
    createdAt: "2026-11-05T10:00:00.000Z",
    createdBy: "you",
    origin: { cwd: "/work" },
    state: "waiting",
    autoContinue: false,
    lastCheckedAt: null,
    lastResult: null,
    failures: 0,
    nextCheckAt: null,
    readyAt: null,
    continuedAt: null,
    ...overrides,
  }) as never;

beforeEach(() => {
  fixture.calls = [];
});

const waits = [
  wait("pr", {
    title: "API migration PR merged",
    condition: { type: "pull_request_merged", repository: "acme/app", number: 12 },
    state: "ready",
    next: "Deploy the migration",
    origin: { cwd: "/work", threadId: "thread-1" },
  }),
  wait("url", {
    title: "Staging is up",
    condition: { type: "url_up", url: "https://staging.example.com" },
    lastResult: "Not yet",
  }),
  wait("legal", { title: "Legal signs off", condition: { type: "manual", description: "Legal sign-off" } }),
];

it("shows each wait with its condition, and carries one on", async () => {
  const onOpenThread = vi.fn();
  await using screen = await render(
    <div style={{ width: 280 }} className="bg-sidebar text-sidebar-foreground">
      <WaitRows environmentId={env} waits={waits} onOpenThread={onOpenThread} />
    </div>,
  );
  await expect.element(page.getByText("API migration PR merged")).toBeVisible();
  await expect.element(page.getByText("acme/app#12 merged")).toBeVisible();
  await expect.element(page.getByText("staging.example.com up")).toBeVisible();
  await expect.element(page.getByText("Waiting · Not yet")).toBeVisible();
  await page.screenshot({
    path: "__screenshots__/octet-waits.png",
    element: screen.container.firstElementChild as HTMLElement,
  });

  await page.getByRole("button", { name: "Continue" }).click();
  expect(fixture.calls).toEqual([
    { kind: "resolve", value: { environmentId: env, input: { id: "pr", action: "continue" } } },
  ]);
  expect(onOpenThread).not.toHaveBeenCalled();
});

it("settles a manual wait, drops one, and opens the thread a wait came from", async () => {
  const onOpenThread = vi.fn();
  await using _screen = await render(<WaitRows environmentId={env} waits={waits} onOpenThread={onOpenThread} />);

  await page.getByRole("button", { name: "It happened" }).click();
  expect(fixture.calls.at(-1)).toEqual({
    kind: "resolve",
    value: { environmentId: env, input: { id: "legal", action: "ready" } },
  });

  await page.getByText("Staging is up").hover();
  await page.getByRole("button", { name: "Drop wait: Staging is up" }).click();
  expect(fixture.calls.at(-1)).toEqual({
    kind: "cancel",
    value: { environmentId: env, input: { id: "url" } },
  });

  await page.getByText("API migration PR merged").click();
  expect(onOpenThread).toHaveBeenCalledWith({ environmentId: env, threadId: "thread-1" });
});

it("renders nothing without waits", async () => {
  const screen = await render(<WaitRows environmentId={env} waits={[]} onOpenThread={() => undefined} />);
  expect(screen.container.querySelector("[data-octet-waits]")).toBeNull();
  await screen.unmount();
});

it("edits a wait: the dialog starts from it, and saves only what changed in the form", async () => {
  await using _screen = await render(<WaitRows environmentId={env} waits={waits} onOpenThread={() => undefined} />);
  await page.getByText("Staging is up").hover();
  await page.getByRole("button", { name: "Edit wait: Staging is up" }).click();

  const title = page.getByLabelText("Waiting for");
  await expect.element(title).toHaveValue("Staging is up");
  await expect.element(page.getByLabelText("URL")).toHaveValue("https://staging.example.com");
  await title.fill("Staging answers");
  await page.getByLabelText("Then (optional)").fill("Run the smoke tests");
  await page.getByRole("button", { name: "Save" }).click();

  expect(fixture.calls.at(-1)).toEqual({
    kind: "update",
    value: {
      environmentId: env,
      input: {
        id: "url",
        title: "Staging answers",
        next: "Run the smoke tests",
        autoContinue: false,
        condition: { type: "url_up", url: "https://staging.example.com" },
      },
    },
  });
});

it("makes a wait by hand, and won't save one that is incomplete", async () => {
  const origin = { cwd: "/work", threadId: "thread-1", projectId: "project-1" } as never;
  await using _screen = await render(<WaitDialog open onOpenChange={() => undefined} environmentId={env} origin={origin} />);

  const save = page.getByRole("button", { name: "Wait", exact: true });
  await expect.element(save).toBeDisabled();
  await page.getByLabelText("Waiting for").fill("Legal signs off");
  await expect.element(save).toBeEnabled();
  await page.getByLabelText("What you will confirm (optional)").fill("Approved");
  await save.click();

  expect(fixture.calls.at(-1)).toEqual({
    kind: "create",
    value: {
      environmentId: env,
      input: {
        title: "Legal signs off",
        condition: { type: "manual", description: "Approved" },
        next: "",
        autoContinue: false,
        origin,
      },
    },
  });
});
