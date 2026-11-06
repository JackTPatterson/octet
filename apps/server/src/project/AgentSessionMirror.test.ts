import * as NodeServices from "@effect/platform-node/NodeServices";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import { describe, expect, it } from "vite-plus/test";

import * as IdAllocator from "@t3tools/provider-core/server/IdAllocator";
import * as EventSink from "../orchestration-v2/EventSink.ts";
import * as Orchestrator from "../orchestration-v2/Orchestrator.ts";
import { claudeProjectDirectoryName } from "../remoteControl/readRemoteControl.ts";
import * as ProviderSessionRuntime from "../persistence/ProviderSessionRuntime.ts";
import * as AgentSessionMirror from "./AgentSessionMirror.ts";
import * as ProjectService from "./ProjectService.ts";

const SESSION = "11111111-2222-4333-8444-555555555555";
const CWD = "/work/my.app";

const line = (type: "user" | "assistant", text: string, at: string) =>
  JSON.stringify({
    type,
    sessionId: SESSION,
    cwd: CWD,
    timestamp: at,
    message:
      type === "user"
        ? { role: "user", content: text }
        : { role: "assistant", content: [{ type: "text", text }] },
  });

const LOG = [
  line("user", "Fix the bug", "2026-11-05T10:00:00.000Z"),
  line("assistant", "Fixed it.", "2026-11-05T10:00:05.000Z"),
  line("user", "Now add a test", "2026-11-05T10:10:00.000Z"),
  line("assistant", "Added the test.", "2026-11-05T10:10:20.000Z"),
];

const message = (role: "user" | "assistant", text: string) => ({ role, text });

function run(input: {
  readonly log: ReadonlyArray<string>;
  readonly existing: ReadonlyArray<{ role: "user" | "assistant"; text: string }>;
  readonly nativeId: string | null;
  readonly sinceMs?: number;
  readonly driver?: string;
}) {
  const written: unknown[] = [];
  const runtimeRows: unknown[] = [];
  const records = {
    thread: {
      id: "thread-1",
      projectId: "project-1",
      worktreePath: null,
      providerInstanceId: "claudeAgent",
      modelSelection: { instanceId: "claudeAgent" },
      activeProviderThreadId: input.nativeId ? "pt-1" : null,
    },
    messages: input.existing,
    turnItems: input.existing.map((_, index) => ({ ordinal: index + 1 })),
    providerThreads: input.nativeId
      ? [
          {
            id: "pt-1",
            driver: "claudeAgent",
            providerInstanceId: "claudeAgent",
            nativeThreadRef: { driver: "claudeAgent", nativeId: input.nativeId, strength: "strong" },
          },
        ]
      : [],
  };
  const mocks = Layer.mergeAll(
    Layer.mock(Orchestrator.OrchestratorV2)({
      getThreadRecords: () => Effect.succeed(records as never),
    }),
    Layer.mock(EventSink.EventSinkV2)({
      write: ({ events }) => {
        written.push(...events);
        return Effect.succeed(events as never);
      },
    }),
    Layer.mock(ProviderSessionRuntime.ProviderSessionRuntimeRepository)({
      upsert: (row: unknown) => {
        runtimeRows.push(row);
        return Effect.void;
      },
    }),
    IdAllocator.layer,
    Layer.mock(ProjectService.ProjectService)({
      getById: () => Effect.succeedSome({ workspaceRoot: CWD } as never),
    }),
  );
  const layer = AgentSessionMirror.layer.pipe(
    Layer.provide(mocks),
    Layer.provideMerge(NodeServices.layer),
  );
  return Effect.runPromise(
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const home = yield* fileSystem.makeTempDirectoryScoped();
      const directory = `${home}/.claude/projects/${claudeProjectDirectoryName(CWD)}`;
      yield* fileSystem.makeDirectory(directory, { recursive: true });
      yield* fileSystem.writeFileString(`${directory}/${SESSION}.jsonl`, input.log.join("\n") + "\n");
      const result = yield* Effect.gen(function* () {
        const mirror = yield* AgentSessionMirror.AgentSessionMirror;
        return yield* mirror.mirror({ threadId: "thread-1" as never, sinceMs: input.sinceMs,
          driver: input.driver,
        });
      }).pipe(
        Effect.provide(layer),
        Effect.provideService(HostProcess.HomeDirectory, home),
        Effect.provideService(HostProcess.Environment, {}),
      );
      return { result, written, runtimeRows };
    }).pipe(Effect.scoped, Effect.orDie, Effect.provide(NodeServices.layer)),
  );
}

describe("AgentSessionMirror", () => {
  it("adds the turns typed in the CLI after the ones the thread has, with the next ordinals", async () => {
    const { result, written } = await run({
      log: LOG,
      existing: [message("user", "Fix the bug"), message("assistant", "Fixed it.")],
      nativeId: SESSION,
    });
    expect(result.status).toBe("mirrored");
    expect(result.added).toBe(2);
    const items = (written as Array<{ type: string; payload: { ordinal?: number; text?: string } }>).filter(
      (event) => event.type === "turn-item.updated",
    );
    expect(items.map((event) => event.payload.text)).toEqual(["Now add a test", "Added the test."]);
    expect(items.map((event) => event.payload.ordinal)).toEqual([3, 4]);
    const messages = (written as Array<{ type: string; payload: { role?: string } }>).filter(
      (event) => event.type === "message.updated",
    );
    expect(messages.map((event) => event.payload.role)).toEqual(["user", "assistant"]);
  });

  it("adds nothing when the thread already has every turn", async () => {
    const { result, written } = await run({
      log: LOG,
      existing: [
        message("user", "Fix the bug"),
        message("assistant", "Fixed it."),
        message("user", "Now add a test"),
        message("assistant", "Added the test."),
      ],
      nativeId: SESSION,
    });
    expect(result).toEqual({ added: 0, sessionId: SESSION, status: "mirrored" });
    expect(written).toHaveLength(0);
  });

  it("fills an empty thread from the CLI's new session, found by when the terminal started", async () => {
    const { result } = await run({
      log: LOG,
      existing: [],
      nativeId: null,
      sinceMs: 1,
      driver: "claudeAgent",
    });
    expect(result.status).toBe("mirrored");
    expect(result.added).toBe(4);
    expect(result.sessionId).toBe(SESSION);
  });

  it("makes that session the thread's own, so the chat resumes it", async () => {
    const { written, runtimeRows } = await run({
      log: LOG,
      existing: [],
      nativeId: null,
      sinceMs: 1,
      driver: "claudeAgent",
    });
    const events = written as Array<{ type: string; payload: Record<string, unknown> }>;
    const providerThread = events.find((event) => event.type === "provider-thread.updated");
    expect(providerThread?.payload.nativeThreadRef).toMatchObject({ nativeId: SESSION, strength: "strong" });
    const updated = events.find((event) => event.type === "thread.metadata-updated");
    expect(updated?.payload.activeProviderThreadId).toBe(providerThread?.payload.id);
    expect(runtimeRows).toHaveLength(1);
    expect(runtimeRows[0]).toMatchObject({ resumeCursor: { resume: SESSION } });
  });

  it("does not adopt a session for an agent whose log it can't read", async () => {
    const { result } = await run({
      log: LOG,
      existing: [],
      nativeId: null,
      sinceMs: 1,
      driver: "codex",
    });
    expect(result).toEqual({ added: 0, sessionId: null, status: "unsupported" });
  });

  it("has no session for a thread with none and no start time", async () => {
    const { result } = await run({ log: LOG, existing: [], nativeId: null, driver: "claudeAgent" });
    expect(result).toEqual({ added: 0, sessionId: null, status: "no_session" });
  });
});
