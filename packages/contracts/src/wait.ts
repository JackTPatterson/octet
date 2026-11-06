import * as Schema from "effect/Schema";

import {
  ForwardCompatibleArray,
  IsoDateTime,
  NonNegativeInt,
  PositiveInt,
  ProjectId,
  ThreadId,
  TrimmedNonEmptyString,
  WaitId,
} from "./baseSchemas.ts";

/**
 * A wait records work that cannot go on until something outside it happens, and the
 * next step to take then. The server checks the condition itself, with no agent
 * running; when it is met the wait becomes `ready` and the work is brought back.
 */

export const WaitCondition = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("date"),
    at: TrimmedNonEmptyString.annotate({ description: "ISO 8601 date and time, with an offset." }),
  }),
  Schema.Struct({
    type: Schema.Literal("pull_request_merged"),
    repository: TrimmedNonEmptyString.annotate({ description: "owner/name." }),
    number: PositiveInt,
    host: Schema.optional(
      TrimmedNonEmptyString.annotate({ description: "Default: this project's host." }),
    ),
  }),
  Schema.Struct({
    type: Schema.Literal("url_up"),
    url: TrimmedNonEmptyString.annotate({ description: "http(s) URL that answers 2xx or 3xx." }),
  }),
  Schema.Struct({
    type: Schema.Literal("manual"),
    description: Schema.optional(
      TrimmedNonEmptyString.annotate({ description: "What the person is to confirm." }),
    ),
  }),
]);
export type WaitCondition = typeof WaitCondition.Type;

export const WaitState = Schema.Literals(["waiting", "ready", "cancelled"]);
export type WaitState = typeof WaitState.Type;

export const WaitOrigin = Schema.Struct({
  threadId: Schema.optional(ThreadId),
  projectId: Schema.optional(ProjectId),
  cwd: Schema.String,
});
export type WaitOrigin = typeof WaitOrigin.Type;

export const Wait = Schema.Struct({
  id: WaitId,
  /** What it waits for, in words: "the API migration PR merged". */
  title: TrimmedNonEmptyString,
  condition: WaitCondition,
  /** What to do then, as it is sent to the thread. Empty when the wait only brings the work back. */
  next: Schema.String,
  createdAt: IsoDateTime,
  /** "you", or the agent that set it. */
  createdBy: TrimmedNonEmptyString,
  origin: WaitOrigin,
  state: WaitState,
  /** Send `next` to the origin thread as soon as the wait is ready. */
  autoContinue: Schema.Boolean,
  lastCheckedAt: Schema.NullOr(IsoDateTime),
  /** What the last check found, e.g. "Open". */
  lastResult: Schema.NullOr(Schema.String),
  /** Consecutive failed checks; they back the next check off. */
  failures: NonNegativeInt,
  /** Null once it is no longer waiting, and for a manual wait. */
  nextCheckAt: Schema.NullOr(IsoDateTime),
  readyAt: Schema.NullOr(IsoDateTime),
  /** Set when `next` was sent to the origin thread. */
  continuedAt: Schema.NullOr(IsoDateTime),
});
export type Wait = typeof Wait.Type;

export const WaitListInput = Schema.Struct({});
export type WaitListInput = typeof WaitListInput.Type;

export const WaitListResult = Schema.Struct({
  waits: ForwardCompatibleArray(Wait),
});
export type WaitListResult = typeof WaitListResult.Type;

export const WaitCreateInput = Schema.Struct({
  title: TrimmedNonEmptyString,
  condition: WaitCondition,
  next: Schema.optional(Schema.String),
  autoContinue: Schema.optional(Schema.Boolean),
  createdBy: Schema.optional(TrimmedNonEmptyString),
  origin: WaitOrigin,
});
export type WaitCreateInput = typeof WaitCreateInput.Type;

export const WaitCancelInput = Schema.Struct({ id: WaitId });
export type WaitCancelInput = typeof WaitCancelInput.Type;

export const WaitResolveInput = Schema.Struct({
  id: WaitId,
  /**
   * `ready` records that it has happened (the way to settle a `manual` wait).
   * `continue` also sends `next` to the origin thread now.
   */
  action: Schema.Literals(["ready", "continue"]),
});
export type WaitResolveInput = typeof WaitResolveInput.Type;

/**
 * Changes to a wait that has not yet been carried on. Only what is given changes.
 * The condition can change only while it is still waiting.
 */
export const WaitUpdateInput = Schema.Struct({
  id: WaitId,
  title: Schema.optional(TrimmedNonEmptyString),
  condition: Schema.optional(WaitCondition),
  next: Schema.optional(Schema.String),
  autoContinue: Schema.optional(Schema.Boolean),
});
export type WaitUpdateInput = typeof WaitUpdateInput.Type;

export const WaitMutationResult = Schema.Struct({ wait: Wait });
export type WaitMutationResult = typeof WaitMutationResult.Type;

export class WaitError extends Schema.TaggedError<WaitError>()("WaitError", {
  message: Schema.String,
  waitId: Schema.optional(WaitId),
  cause: Schema.optional(Schema.Defect()),
}) {}
