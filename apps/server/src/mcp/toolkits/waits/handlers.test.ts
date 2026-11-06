import { assert, it } from "@effect/vitest";
import {
  EnvironmentId,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
  WaitError,
  WaitId,
  type Wait,
  type WaitCreateInput,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";

import * as ThreadManagementService from "../../../orchestration-v2/ThreadManagementService.ts";
import * as ProjectService from "../../../project/ProjectService.ts";
import * as WaitService from "../../../waits/WaitService.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import { liveThreadShell } from "../../McpToolAccess.testkit.ts";
import { cancelWait, listWaits, resolveOrigin, waitFor } from "./handlers.ts";
import { OctetWaitsToolkit } from "./tools.ts";

const THREAD_ID = ThreadId.make("thread:caller");

const scope = (thread: boolean): McpInvocationContext.McpInvocationScope => ({
  environmentId: EnvironmentId.make("environment-1"),
  requestNamespace: "provider-session-1",
  thread: thread
    ? {
        threadId: THREAD_ID,
        providerSessionId: "provider-session-1",
        providerInstanceId: ProviderInstanceId.make("codex"),
      }
    : undefined,
  client: undefined,
  capabilities: new Set(["orchestration"] as const),
  issuedAt: 1,
});

const sampleWait = (input: WaitCreateInput): Wait => ({
  id: WaitId.make("wait:1"),
  title: input.title,
  condition: input.condition,
  next: input.next ?? "",
  createdAt: "2026-11-05T12:00:00.000Z",
  createdBy: input.createdBy ?? "you",
  origin: input.origin,
  state: "waiting",
  autoContinue: input.autoContinue ?? false,
  lastCheckedAt: null,
  lastResult: null,
  failures: 0,
  nextCheckAt: null,
  readyAt: null,
  continuedAt: null,
});

const harness = Effect.gen(function* () {
  const created = yield* Ref.make<ReadonlyArray<WaitCreateInput>>([]);
  const cancelled = yield* Ref.make<ReadonlyArray<string>>([]);
  const waits = Layer.mock(WaitService.WaitService)({
    create: (input) =>
      input.title === "reject"
        ? Effect.fail(new WaitError({ message: "The date is not a valid ISO 8601 time." }))
        : Ref.update(created, (all) => [...all, input]).pipe(
            Effect.as({ wait: sampleWait(input) }),
          ),
    list: () =>
      Effect.succeed({
        waits: [
          sampleWait({
            title: "listed",
            condition: { type: "manual" },
            origin: { cwd: "/x" },
          }),
        ],
      }),
    cancel: (input) =>
      input.id === "wait:missing"
        ? Effect.fail(new WaitError({ message: "Wait not found." }))
        : Ref.update(cancelled, (all) => [...all, input.id]).pipe(
            Effect.as({
              wait: {
                ...sampleWait({ title: "c", condition: { type: "manual" }, origin: { cwd: "/" } }),
                state: "cancelled" as const,
              },
            }),
          ),
  });
  const threads = Layer.mock(ThreadManagementService.ThreadManagementService)({
    getThreadShell: (threadId) =>
      Effect.succeed(
        threadId === THREAD_ID
          ? {
              ...liveThreadShell(THREAD_ID),
              projectId: ProjectId.make("project:1"),
              worktreePath: "/work/tree",
            }
          : null,
      ),
  });
  const projects = Layer.mock(ProjectService.ProjectService)({
    getById: () => Effect.succeedSome({ workspaceRoot: "/work/root" } as never),
  });
  return { created, cancelled, layer: Layer.mergeAll(waits, threads, projects) };
});

const as = <A, E, R>(effect: Effect.Effect<A, E, R>, thread = true) =>
  effect.pipe(Effect.provideService(McpInvocationContext.McpInvocationContext, scope(thread)));

it("advertises Octet's waits tools", () => {
  assert.deepEqual(Object.keys(OctetWaitsToolkit.tools).sort(), [
    "cancel_wait",
    "list_waits",
    "wait_for",
  ]);
});

it.effect("wait_for takes its origin from the invoking thread", () =>
  Effect.gen(function* () {
    const { created, layer } = yield* harness;
    const result = yield* as(
      waitFor({
        title: "PR merged",
        condition: { type: "pull_request_merged", repository: "o/r", number: 3 },
        next: "Deploy",
        autoContinue: true,
      }),
    ).pipe(Effect.provide(layer));
    const [input] = yield* Ref.get(created);
    assert.deepEqual(input!.origin, {
      threadId: THREAD_ID,
      projectId: ProjectId.make("project:1"),
      cwd: "/work/tree",
    });
    assert.equal(input!.createdBy, "codex");
    assert.isTrue(input!.autoContinue);
    assert.equal(result.wait.title, "PR merged");
  }),
);

it.effect("the origin falls back to the project root, and is empty outside a thread", () =>
  Effect.gen(function* () {
    const { layer } = yield* harness;
    const noThread = yield* as(resolveOrigin(), false).pipe(Effect.provide(layer));
    assert.deepEqual(noThread, { cwd: "" });
  }),
);

it.effect("wait_for turns a refused wait into a tool failure", () =>
  Effect.gen(function* () {
    const { layer } = yield* harness;
    const failure = yield* as(
      waitFor({ title: "reject", condition: { type: "manual" }, next: "" }),
    ).pipe(Effect.provide(layer), Effect.flip);
    assert.equal(failure._tag, "OrchestratorMcpFailure");
    assert.equal(failure.message, "The date is not a valid ISO 8601 time.");
  }),
);

it.effect("list_waits and cancel_wait go through the service", () =>
  Effect.gen(function* () {
    const { cancelled, layer } = yield* harness;
    const listed = yield* as(listWaits()).pipe(Effect.provide(layer));
    assert.deepEqual(
      listed.waits.map((wait) => wait.title),
      ["listed"],
    );
    const result = yield* as(cancelWait({ id: WaitId.make("wait:1") })).pipe(Effect.provide(layer));
    assert.equal(result.wait.state, "cancelled");
    assert.deepEqual(yield* Ref.get(cancelled), ["wait:1"]);
    const missing = yield* as(cancelWait({ id: WaitId.make("wait:missing") })).pipe(
      Effect.provide(layer),
      Effect.flip,
    );
    assert.equal(missing.message, "Wait not found.");
  }),
);
