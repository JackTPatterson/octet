import {
  type OrchestratorMcpFailure as OrchestratorMcpFailureType,
  OrchestratorMcpFailure,
  type WaitError,
  type WaitOrigin,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";

import * as ThreadManagementService from "../../../orchestration-v2/ThreadManagementService.ts";
import * as ProjectService from "../../../project/ProjectService.ts";
import * as WaitService from "../../../waits/WaitService.ts";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as McpToolAccess from "../../McpToolAccess.ts";
import { type CancelWaitInput, OctetWaitsToolkit, type WaitForInput } from "./tools.ts";

const failed = (error: WaitError): OrchestratorMcpFailureType =>
  new OrchestratorMcpFailure({ code: "invalid_request", message: error.message });

/** Where the work is: the calling thread, its project, and the folder it runs in. */
export const resolveOrigin = Effect.fn("OctetWaits.resolveOrigin")(function* () {
  const scope = yield* McpInvocationContext.McpInvocationContext;
  const threadId = scope.thread?.threadId;
  if (threadId === undefined) return { cwd: "" } satisfies WaitOrigin;
  const threads = yield* ThreadManagementService.ThreadManagementService;
  const shell = yield* threads.getThreadShell(threadId).pipe(Effect.orElseSucceed(() => null));
  if (shell === null) return { threadId, cwd: "" } satisfies WaitOrigin;
  const projects = yield* ProjectService.ProjectService;
  const project = yield* projects
    .getById(shell.projectId)
    .pipe(Effect.orElseSucceed(() => Option.none()));
  const cwd = shell.worktreePath ?? Option.getOrUndefined(project)?.workspaceRoot ?? "";
  return { threadId, projectId: shell.projectId, cwd } satisfies WaitOrigin;
});

export const waitFor = Effect.fn("OctetWaits.waitFor")(function* (input: WaitForInput) {
  const waits = yield* WaitService.WaitService;
  const scope = yield* McpInvocationContext.McpInvocationContext;
  const origin = yield* resolveOrigin();
  return yield* waits
    .create({
      title: input.title,
      condition: input.condition,
      next: input.next,
      autoContinue: input.autoContinue ?? false,
      // The calling agent's provider instance names who set it.
      createdBy: scope.thread?.providerInstanceId ?? scope.client?.label ?? "agent",
      origin,
    })
    .pipe(Effect.mapError(failed));
});

export const listWaits = Effect.fn("OctetWaits.listWaits")(function* () {
  const waits = yield* WaitService.WaitService;
  return yield* waits.list().pipe(Effect.mapError(failed));
});

export const cancelWait = Effect.fn("OctetWaits.cancelWait")(function* (input: CancelWaitInput) {
  const waits = yield* WaitService.WaitService;
  return yield* waits.cancel({ id: input.id }).pipe(Effect.mapError(failed));
});

const handlers = {
  wait_for: McpToolAccess.writes(waitFor),
  list_waits: McpToolAccess.reads(() => listWaits()),
  cancel_wait: McpToolAccess.writes(cancelWait),
} satisfies McpToolAccess.Handlers<typeof OctetWaitsToolkit.tools>;

export const layer = McpToolAccess.toLayer(OctetWaitsToolkit, handlers);
