import "../../../index.css";

import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { beforeEach, expect, it, vi } from "vite-plus/test";
import { page, userEvent } from "vite-plus/test/browser";

import { render } from "../../../../test/render";

const fixture = vi.hoisted(() => ({
  files: {} as Record<string, string>,
  writes: [] as Array<{ relativePath: string; contents: string }>,
  refreshes: 0,
}));

vi.mock("../../../state/projects", () => ({
  projectEnvironment: {
    readFile: (args: { input: { relativePath: string } }) => ({ read: args.input.relativePath }),
    writeFile: { write: true },
  },
}));
vi.mock("../../../state/query", () => ({
  useEnvironmentQuery: (atom: { read: string } | null) => {
    if (atom === null) return { data: null, isPending: false, refresh: () => undefined };
    const contents = fixture.files[atom.read];
    return {
      data:
        contents === undefined
          ? { relativePath: atom.read, contents: "", exists: false }
          : { relativePath: atom.read, contents, exists: true },
      isPending: false,
      refresh: () => {
        fixture.refreshes += 1;
      },
    };
  },
}));
vi.mock("../../../state/session", () => ({ useEnvironmentScope: () => true }));
vi.mock("../../../state/use-atom-command", () => ({
  useAtomCommand: () => async (value: { input: { relativePath: string; contents: string } }) => {
    fixture.writes.push(value.input);
    fixture.files[value.input.relativePath] = value.input.contents;
    return { _tag: "Success" };
  },
}));

import { TodosPanel } from "./TodosPanel";

const threadRef = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("thread"));

beforeEach(() => {
  fixture.files = {};
  fixture.writes = [];
  fixture.refreshes = 0;
});

function panel() {
  return (
    <div style={{ width: 380, height: 460 }} className="bg-background text-foreground">
      <TodosPanel threadRef={threadRef} projectRoot="/work/app" />
    </div>
  );
}

it("shows the project's list and ticks an item in the file", async () => {
  fixture.files["TODO.md"] = "# TODO\n\n## Now\n- [ ] Port the sidebar\n- [~] Status bar\n- [x] Rebrand\n";
  await using screen = await render(panel());

  expect(page.getByText("Agent plan").elements()).toHaveLength(0);
  await expect.element(page.getByText("Port the sidebar")).toBeVisible();
  // Done items fold away until asked.
  expect(page.getByText("Rebrand").elements()).toHaveLength(0);
  await page.screenshot({
    path: "__screenshots__/octet-todos.png",
    element: screen.container.firstElementChild as HTMLElement,
  });

  await page.getByText("Port the sidebar").click();
  await vi.waitFor(() => expect(fixture.writes).toHaveLength(1));
  expect(fixture.writes[0]).toEqual({
    cwd: "/work/app",
    relativePath: "TODO.md",
    contents: "# TODO\n\n## Now\n- [x] Port the sidebar\n- [~] Status bar\n- [x] Rebrand\n",
  });
});

it("adds an item with Enter, creating TODO.md when there is none", async () => {
  await using _screen = await render(panel());
  await expect.element(page.getByText(/No items in TODO.md yet/)).toBeVisible();
  const input = page.getByLabelText("Add a TODO item");
  await input.fill("Write the docs");
  await userEvent.keyboard("{Enter}");
  await vi.waitFor(() => expect(fixture.writes).toHaveLength(1));
  expect(fixture.writes[0]).toEqual({
    cwd: "/work/app",
    relativePath: "TODO.md",
    contents: "# TODO\n\n- [ ] Write the docs\n",
  });
});

it("uses an existing lowercase todo.md and shows done items on request", async () => {
  fixture.files["todo.md"] = "- [ ] Open one\n- [x] Closed one\n";
  await using _screen = await render(panel());
  await expect.element(page.getByText("Open one")).toBeVisible();
  await page.getByRole("button", { name: /Done/ }).click();
  await expect.element(page.getByText("Closed one")).toBeVisible();
});
