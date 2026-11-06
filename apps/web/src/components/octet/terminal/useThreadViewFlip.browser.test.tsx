import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { beforeEach, expect, it, vi } from "vite-plus/test";

import { act, render } from "../../../../test/render";

const fixture = vi.hoisted(() => ({
  sessions: [] as unknown[],
  writes: [] as string[],
  mirrorCalls: [] as unknown[],
  mirrorResult: { added: 0, sessionId: null as string | null, status: "mirrored" },
  toasts: [] as unknown[],
  events: [] as string[],
}));

vi.mock("../../terminal/useThreadTerminalActions", () => ({
  useThreadTerminalActions: () => ({
    writeToTerminal: async (_id: string, data: string) => {
      fixture.writes.push(data);
      fixture.events.push(`write:${JSON.stringify(data)}`);
      // The CLI exits after its second Ctrl+C.
      if (fixture.writes.filter((w) => w === "\u0003").length >= 2) {
        fixture.sessions = [agentSession(false)];
      }
    },
  }),
}));
vi.mock("../../../state/terminalSessions", () => ({
  useKnownTerminalSessions: () => fixture.sessions,
}));
vi.mock("../../../state/use-atom-command", () => ({
  useAtomCommand: () => async (value: unknown) => {
    fixture.mirrorCalls.push(value);
    fixture.events.push("mirror");
    return { _tag: "Success", value: fixture.mirrorResult };
  },
}));
vi.mock("../../ui/toast", () => ({
  toastManager: { add: (toast: unknown) => fixture.toasts.push(toast) },
}));

import { recordCliLaunch, takeCliStoppedByFlip } from "./cliLaunches";
import { useThreadViewFlip } from "./useThreadViewFlip";

const agentSession = (live: boolean) => ({
  target: { terminalId: "octet-agent" },
  state: { hasRunningSubprocess: live, summary: { status: "running" } },
});

const threadRef = scopeThreadRef(EnvironmentId.make("env"), ThreadId.make("thread-1"));

function Harness(props: {
  view: "chat" | "terminal";
  isWorking?: boolean;
  setView: (view: "chat" | "terminal") => void;
  interrupt: () => Promise<unknown>;
}) {
  const { flip, flipping } = useThreadViewFlip({
    threadRef,
    driverKind: "claudeAgent",
    view: props.view,
    setView: props.setView,
    isWorking: props.isWorking ?? false,
    interrupt: props.interrupt,
  });
  return (
    <button onClick={() => void flip()} data-flipping={flipping}>
      flip
    </button>
  );
}

beforeEach(() => {
  fixture.sessions = [];
  fixture.writes = [];
  fixture.mirrorCalls = [];
  fixture.toasts = [];
  fixture.events = [];
  fixture.mirrorResult = { added: 0, sessionId: null, status: "mirrored" };
});

it("flipping to chat stops the CLI, copies its turns in, then shows the chat", async () => {
  fixture.sessions = [agentSession(true)];
  fixture.mirrorResult = { added: 3, sessionId: "abc", status: "mirrored" };
  recordCliLaunch("env:thread-1", 1_000_000);
  const setView = vi.fn((view: string) => fixture.events.push(`view:${view}`));
  await using screen = await render(
    <Harness view="terminal" setView={setView} interrupt={async () => {}} />,
    { router: false },
  );
  await act(() => screen.container.querySelector("button")!.click());
  await vi.waitFor(() => expect(setView).toHaveBeenCalledWith("chat"), { timeout: 8000 });

  // Escape, then Ctrl+C twice, then the copy, and only then the view.
  expect(fixture.writes).toEqual(["\u001b", "\u0003", "\u0003"]);
  expect(fixture.events.filter((e) => !e.startsWith("write")).join(",")).toBe("mirror,view:chat");
  expect(fixture.mirrorCalls[0]).toMatchObject({
    environmentId: "env",
    input: { threadId: "thread-1", driver: "claudeAgent", sinceMs: 998_000 },
  });
  expect(fixture.toasts).toEqual([{ type: "success", title: "Added 3 messages from the CLI to the chat." }]);
  // The terminal view may now restart the CLI it finds idle, once.
  expect(takeCliStoppedByFlip("env:thread-1")).toBe(true);
  expect(takeCliStoppedByFlip("env:thread-1")).toBe(false);
});

it("flipping to chat with no CLI running just copies and shows", async () => {
  fixture.sessions = [agentSession(false)];
  const setView = vi.fn();
  await using screen = await render(
    <Harness view="terminal" setView={setView} interrupt={async () => {}} />,
    { router: false },
  );
  await act(() => screen.container.querySelector("button")!.click());
  await vi.waitFor(() => expect(setView).toHaveBeenCalledWith("chat"));
  expect(fixture.writes).toEqual([]);
  expect(fixture.mirrorCalls).toHaveLength(1);
  expect(fixture.toasts).toEqual([]);
  expect(takeCliStoppedByFlip("env:thread-1")).toBe(false);
});

it("flipping to the terminal stops a running chat turn first", async () => {
  const order: string[] = [];
  const setView = vi.fn((view: string) => order.push(`view:${view}`));
  const interrupt = vi.fn(async () => {
    order.push("interrupt");
  });
  await using screen = await render(
    <Harness view="chat" isWorking setView={setView} interrupt={interrupt} />,
    { router: false },
  );
  await act(() => screen.container.querySelector("button")!.click());
  await vi.waitFor(() => expect(setView).toHaveBeenCalledWith("terminal"));
  expect(order).toEqual(["interrupt", "view:terminal"]);
  expect(fixture.mirrorCalls).toHaveLength(0);
});

it("flipping to the terminal from an idle chat does not interrupt anything", async () => {
  const setView = vi.fn();
  const interrupt = vi.fn(async () => {});
  await using screen = await render(
    <Harness view="chat" setView={setView} interrupt={interrupt} />,
    { router: false },
  );
  await act(() => screen.container.querySelector("button")!.click());
  await vi.waitFor(() => expect(setView).toHaveBeenCalledWith("terminal"));
  expect(interrupt).not.toHaveBeenCalled();
});
