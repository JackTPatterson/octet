import {
  CommandId,
  MessageId,
  PROVIDER_SEND_TURN_MAX_INPUT_CHARS,
  Wait,
  WaitCondition,
  WaitError,
  WaitId,
  WaitOrigin,
  type WaitCancelInput,
  type WaitCreateInput,
  type WaitListResult,
  type WaitMutationResult,
  type WaitResolveInput,
  type WaitUpdateInput,
} from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as SecureRandom from "effect/crypto/SecureRandom";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import * as SqlClient from "effect/sql/SqlClient";
import * as NodeSqliteClient from "@t3tools/shared/nodeSqliteClient";

import * as ThreadManagementService from "../orchestration-v2/ThreadManagementService.ts";
import * as PullRequestService from "../pullRequest/PullRequestService.ts";
import * as Scheduler from "../scheduling/Scheduler.ts";
import {
  checkWaitCondition,
  isManualCondition,
  nextWaitCheckMs,
  parseWaitDate,
  parseWaitUrl,
  URL_CHECK_TIMEOUT_MS,
  WaitCheckers,
  WaitCheckFailed,
} from "./WaitConditions.ts";

const decodeWait = Schema.decodeUnknownEffect(Wait);
const ConditionJson = Schema.fromJsonString(WaitCondition);
const OriginJson = Schema.fromJsonString(WaitOrigin);
const encodeConditionJson = Schema.encodeSync(ConditionJson);
const encodeOriginJson = Schema.encodeSync(OriginJson);
const decodeConditionJson = Schema.decodeUnknownEffect(ConditionJson);
const decodeOriginJson = Schema.decodeUnknownEffect(OriginJson);

/** Sends a wait's next step to the thread it came from. Injectable so the poller tests without threads. */
export class WaitDispatcher extends Context.Service<
  WaitDispatcher,
  {
    readonly send: (wait: Wait) => Effect.Effect<void, WaitError>;
  }
>()("t3/waits/WaitService/WaitDispatcher") {}

export class WaitService extends Context.Service<
  WaitService,
  {
    readonly list: () => Effect.Effect<WaitListResult, WaitError>;
    readonly subscribeList: () => Stream.Stream<WaitListResult, WaitError>;
    readonly create: (input: WaitCreateInput) => Effect.Effect<WaitMutationResult, WaitError>;
    readonly cancel: (input: WaitCancelInput) => Effect.Effect<WaitMutationResult, WaitError>;
    /** `ready` settles it (a manual wait); `continue` also sends `next` to the origin thread. */
    readonly resolve: (input: WaitResolveInput) => Effect.Effect<WaitMutationResult, WaitError>;
    /** Edits a wait that is waiting, or ready but not yet carried on. */
    readonly update: (input: WaitUpdateInput) => Effect.Effect<WaitMutationResult, WaitError>;
    /** Checks every due wait once; the scheduler calls this. Never fails. */
    readonly runDue: () => Effect.Effect<void>;
  }
>()("t3/waits/WaitService") {}

interface WaitRow {
  readonly wait_id: string;
  readonly title: string;
  readonly condition_json: string;
  readonly next: string;
  readonly created_at: string;
  readonly created_by: string;
  readonly origin_json: string;
  readonly state: string;
  readonly auto_continue: number;
  readonly last_checked_at: string | null;
  readonly last_result: string | null;
  readonly failures: number;
  readonly next_check_at: string | null;
  readonly ready_at: string | null;
  readonly continued_at: string | null;
}

const waitError = (message: string, input?: { waitId?: WaitId; cause?: unknown }) =>
  new WaitError({
    message,
    ...(input?.waitId === undefined ? {} : { waitId: input.waitId }),
    ...(input?.cause === undefined ? {} : { cause: input.cause }),
  });

/** What a wait must satisfy, whether it is being created or edited. Returns the message when it is not valid. */
export function waitProblem(input: {
  readonly condition: WaitCondition;
  readonly next: string;
  readonly autoContinue: boolean;
  readonly origin: WaitOrigin;
}): string | null {
  const { condition, next, autoContinue, origin } = input;
  if (next.length > PROVIDER_SEND_TURN_MAX_INPUT_CHARS) return "The next step is too long.";
  if (condition.type === "date" && parseWaitDate(condition.at) === null) {
    return "The date is not a valid ISO 8601 time.";
  }
  if (condition.type === "url_up" && parseWaitUrl(condition.url) === null) {
    return "The URL must be an http or https URL.";
  }
  if (condition.type === "pull_request_merged" && origin.projectId === undefined) {
    return "Waiting on a pull request needs the project it belongs to.";
  }
  if (autoContinue && next.length === 0) return "Auto-continue needs a next step to send.";
  if (autoContinue && origin.threadId === undefined) {
    return "Auto-continue needs the thread to send the next step to.";
  }
  return null;
}

const isoOf = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));

const toWait = Effect.fn("WaitService.toWait")(function* (row: WaitRow) {
  const condition = yield* decodeConditionJson(row.condition_json);
  const origin = yield* decodeOriginJson(row.origin_json);
  return yield* decodeWait({
    id: row.wait_id,
    title: row.title,
    condition,
    next: row.next,
    createdAt: row.created_at,
    createdBy: row.created_by,
    origin,
    state: row.state,
    autoContinue: row.auto_continue !== 0,
    lastCheckedAt: row.last_checked_at,
    lastResult: row.last_result,
    failures: row.failures,
    nextCheckAt: row.next_check_at,
    readyAt: row.ready_at,
    continuedAt: row.continued_at,
  });
});

const COLUMNS = `wait_id, title, condition_json, next, created_at, created_by, origin_json, state,
  auto_continue, last_checked_at, last_result, failures, next_check_at, ready_at, continued_at`;

export const layer = Layer.effect(
  WaitService,
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    const random = yield* SecureRandom.SecureRandom;
    const dispatcher = yield* WaitDispatcher;
    const checkers = yield* WaitCheckers;
    const scheduler = yield* Scheduler.Scheduler;
    const changes = yield* PubSub.sliding<void>(1);
    const notify = PubSub.publish(changes, undefined).pipe(Effect.asVoid);
    const nowMs = DateTime.now.pipe(Effect.map(DateTime.toEpochMillis));

    const selectRows = (where: "all" | "due" | "one", arg?: string) =>
      (where === "all"
        ? sql<WaitRow>`SELECT ${sql.unsafe(COLUMNS)} FROM waits ORDER BY created_at DESC, wait_id ASC`
        : where === "due"
          ? sql<WaitRow>`SELECT ${sql.unsafe(COLUMNS)} FROM waits
              WHERE state = 'waiting' AND next_check_at IS NOT NULL AND next_check_at <= ${arg ?? ""}
              ORDER BY next_check_at ASC`
          : sql<WaitRow>`SELECT ${sql.unsafe(COLUMNS)} FROM waits WHERE wait_id = ${arg ?? ""}`
      ).pipe(NodeSqliteClient.readOnly);

    const loadWait = Effect.fn("WaitService.loadWait")(function* (id: WaitId) {
      const rows = yield* selectRows("one", id).pipe(
        Effect.mapError((cause) => waitError("Could not read the wait.", { waitId: id, cause })),
      );
      const row = rows[0];
      if (row === undefined) return yield* waitError("Wait not found.", { waitId: id });
      return yield* toWait(row).pipe(
        Effect.mapError((cause) => waitError("Could not read the wait.", { waitId: id, cause })),
      );
    });

    const list: WaitService["Service"]["list"] = () =>
      selectRows("all").pipe(
        Effect.flatMap((rows) =>
          // A row that no longer decodes is skipped, not fatal for the whole list.
          Effect.forEach(rows, (row) => toWait(row).pipe(Effect.option)),
        ),
        Effect.map((waits) => ({
          waits: waits.flatMap((wait) => (wait._tag === "Some" ? [wait.value] : [])),
        })),
        Effect.mapError((cause) => waitError("Could not list waits.", { cause })),
      );

    const subscribeList: WaitService["Service"]["subscribeList"] = () =>
      Stream.unwrap(
        Effect.gen(function* () {
          const subscription = yield* PubSub.subscribe(changes);
          return Stream.concat(
            Stream.fromEffect(list()),
            Stream.fromSubscription(subscription).pipe(Stream.mapEffect(() => list())),
          );
        }),
      );

    const create: WaitService["Service"]["create"] = Effect.fn("WaitService.create")(
      function* (input) {
        const condition = input.condition;
        const next = (input.next ?? "").trim();
        const autoContinue = input.autoContinue ?? false;
        const problem = waitProblem({ condition, next, autoContinue, origin: input.origin });
        if (problem !== null) return yield* waitError(problem);
        const bytes = yield* random
          .randomBytes(12)
          .pipe(Effect.mapError((cause) => waitError("Could not create the wait.", { cause })));
        const id = WaitId.make(`wait:${Buffer.from(bytes).toString("hex")}`);
        const now = yield* nowMs;
        const nextCheck = isManualCondition(condition)
          ? null
          : nextWaitCheckMs({ condition, nowMs: now, createdAtMs: now, failures: 0 });
        // A date wait that is already past is due at once.
        const dueAt =
          condition.type === "date" ? Math.max(now, parseWaitDate(condition.at) ?? now) : nextCheck;
        yield* sql`INSERT INTO waits ${sql.insert({
          wait_id: id,
          title: input.title.trim(),
          condition_json: encodeConditionJson(condition),
          next,
          created_at: isoOf(now),
          created_by: input.createdBy ?? "you",
          origin_json: encodeOriginJson(input.origin),
          state: "waiting",
          auto_continue: autoContinue ? 1 : 0,
          last_checked_at: null,
          last_result: null,
          failures: 0,
          next_check_at:
            condition.type === "date" && dueAt !== null
              ? isoOf(dueAt)
              : nextCheck === null
                ? null
                : isoOf(now),
          ready_at: null,
          continued_at: null,
        })}`.pipe(
          Effect.mapError((cause) => waitError("Could not save the wait.", { waitId: id, cause })),
        );
        yield* notify;
        return { wait: yield* loadWait(id) };
      },
    );

    const cancel: WaitService["Service"]["cancel"] = Effect.fn("WaitService.cancel")(
      function* (input) {
        const wait = yield* loadWait(input.id);
        // Only a wait still waiting is cancelled; a ready one has already done its job.
        if (wait.state === "waiting") {
          yield* sql`UPDATE waits SET state = 'cancelled', next_check_at = NULL
            WHERE wait_id = ${input.id} AND state = 'waiting'`.pipe(
            Effect.mapError((cause) =>
              waitError("Could not cancel the wait.", { waitId: input.id, cause }),
            ),
          );
          yield* notify;
        }
        return { wait: yield* loadWait(input.id) };
      },
    );

    const update: WaitService["Service"]["update"] = Effect.fn("WaitService.update")(
      function* (input) {
        const wait = yield* loadWait(input.id);
        if (wait.state === "cancelled") {
          return yield* waitError("The wait was cancelled.", { waitId: input.id });
        }
        if (wait.continuedAt !== null) {
          return yield* waitError("The wait has already carried on.", { waitId: input.id });
        }
        const conditionChanged =
          input.condition !== undefined &&
          encodeConditionJson(input.condition) !== encodeConditionJson(wait.condition);
        if (conditionChanged && wait.state !== "waiting") {
          return yield* waitError("A wait that is ready can't change what it waits for.", {
            waitId: input.id,
          });
        }
        const condition = conditionChanged && input.condition ? input.condition : wait.condition;
        const next = input.next === undefined ? wait.next : input.next.trim();
        const autoContinue = input.autoContinue ?? wait.autoContinue;
        const title = input.title === undefined ? wait.title : input.title.trim();
        const problem = waitProblem({ condition, next, autoContinue, origin: wait.origin });
        if (problem !== null) return yield* waitError(problem, { waitId: input.id });
        const now = yield* nowMs;
        // A new condition starts its checking over, as a new wait would.
        const recheck =
          conditionChanged && wait.state === "waiting"
            ? isManualCondition(condition)
              ? { next_check_at: null }
              : {
                  next_check_at: isoOf(
                    condition.type === "date" ? Math.max(now, parseWaitDate(condition.at) ?? now) : now,
                  ),
                }
            : null;
        yield* (
          recheck === null
            ? sql`UPDATE waits SET title = ${title}, next = ${next},
                auto_continue = ${autoContinue ? 1 : 0}
              WHERE wait_id = ${input.id} AND state != 'cancelled' AND continued_at IS NULL`
            : sql`UPDATE waits SET title = ${title}, next = ${next},
                auto_continue = ${autoContinue ? 1 : 0},
                condition_json = ${encodeConditionJson(condition)},
                last_checked_at = NULL, last_result = NULL, failures = 0,
                next_check_at = ${recheck.next_check_at}
              WHERE wait_id = ${input.id} AND state = 'waiting' AND continued_at IS NULL`
        ).pipe(
          Effect.mapError((cause) =>
            waitError("Could not update the wait.", { waitId: input.id, cause }),
          ),
        );
        yield* notify;
        return { wait: yield* loadWait(input.id) };
      },
    );

    // Sends once: the row is claimed before sending, and released if the send fails.
    const continueWait = Effect.fn("WaitService.continueWait")(function* (id: WaitId) {
      const wait = yield* loadWait(id);
      if (wait.state !== "ready") return yield* waitError("The wait is not ready.", { waitId: id });
      if (wait.next.length === 0) {
        return yield* waitError("The wait has no next step to send.", { waitId: id });
      }
      const now = isoOf(yield* nowMs);
      const claimed = yield* sql<{ wait_id: string }>`UPDATE waits SET continued_at = ${now}
        WHERE wait_id = ${id} AND state = 'ready' AND continued_at IS NULL
        RETURNING wait_id`.pipe(
        Effect.mapError((cause) =>
          waitError("Could not continue the wait.", { waitId: id, cause }),
        ),
      );
      if (claimed.length === 0) return wait;
      yield* dispatcher
        .send(wait)
        .pipe(
          Effect.tapError(() =>
            sql`UPDATE waits SET continued_at = NULL WHERE wait_id = ${id}`.pipe(Effect.ignore),
          ),
        );
      yield* notify;
      return yield* loadWait(id);
    });

    const resolve: WaitService["Service"]["resolve"] = Effect.fn("WaitService.resolve")(
      function* (input) {
        const wait = yield* loadWait(input.id);
        if (wait.state === "cancelled") {
          return yield* waitError("The wait was cancelled.", { waitId: input.id });
        }
        if (wait.state === "waiting") {
          const now = isoOf(yield* nowMs);
          yield* sql`UPDATE waits SET state = 'ready', ready_at = ${now}, next_check_at = NULL,
              last_result = 'Marked done'
            WHERE wait_id = ${input.id} AND state = 'waiting'`.pipe(
            Effect.mapError((cause) =>
              waitError("Could not update the wait.", { waitId: input.id, cause }),
            ),
          );
          yield* notify;
        }
        if (input.action === "continue") yield* continueWait(input.id);
        return { wait: yield* loadWait(input.id) };
      },
    );

    const checkOne = Effect.fn("WaitService.checkOne")(function* (wait: Wait) {
      const now = yield* nowMs;
      const check = yield* checkWaitCondition(wait, now).pipe(
        Effect.provideService(WaitCheckers, checkers),
      );
      const checkedAt = isoOf(now);
      // `AND state = 'waiting'` keeps a wait cancelled mid-check cancelled.
      if (check._tag === "met") {
        yield* sql`UPDATE waits SET state = 'ready', ready_at = ${checkedAt},
            last_checked_at = ${checkedAt}, last_result = ${check.result}, failures = 0,
            next_check_at = NULL
          WHERE wait_id = ${wait.id} AND state = 'waiting'`;
        if (wait.autoContinue && wait.next.length > 0) {
          yield* continueWait(wait.id).pipe(
            Effect.catch((error) =>
              Effect.logWarning("Wait could not continue its thread", {
                waitId: wait.id,
                message: error.message,
              }).pipe(
                Effect.andThen(
                  sql`UPDATE waits SET last_result = ${`${check.result}; could not continue: ${error.message}`}
                    WHERE wait_id = ${wait.id}`,
                ),
              ),
            ),
          );
        }
      } else {
        const failures = check._tag === "failed" ? wait.failures + 1 : 0;
        const nextAt = nextWaitCheckMs({
          condition: wait.condition,
          nowMs: now,
          createdAtMs: Date.parse(wait.createdAt),
          failures,
        });
        yield* sql`UPDATE waits SET last_checked_at = ${checkedAt}, last_result = ${check.result},
            failures = ${failures}, next_check_at = ${isoOf(nextAt)}
          WHERE wait_id = ${wait.id} AND state = 'waiting'`;
      }
    });

    const runDue: WaitService["Service"]["runDue"] = Effect.fn("WaitService.runDue")(
      function* () {
        const now = isoOf(yield* nowMs);
        const rows = yield* selectRows("due", now);
        for (const row of rows) {
          // One bad wait never stops the others, and never the poller.
          yield* toWait(row).pipe(
            Effect.flatMap(checkOne),
            Effect.catchCause((cause) =>
              Effect.logWarning("Wait check failed", { waitId: row.wait_id, cause }).pipe(
                Effect.andThen(
                  sql`UPDATE waits SET failures = failures + 1,
                    next_check_at = ${isoOf(
                      Date.parse(now) +
                        nextWaitCheckMs({
                          condition: { type: "manual" },
                          nowMs: 0,
                          createdAtMs: 0,
                          failures: row.failures + 1,
                        }),
                    )}
                  WHERE wait_id = ${row.wait_id} AND state = 'waiting'`.pipe(Effect.ignore),
                ),
              ),
            ),
          );
        }
        if (rows.length > 0) yield* notify;
      },
      Effect.catchCause((cause) => Effect.logWarning("Wait poll failed", { cause })),
    );

    yield* scheduler.register("waits", runDue());

    return WaitService.of({ list, subscribeList, create, cancel, resolve, update, runDue });
  }),
);

/** Sends `next` to the thread the wait was set from, once; the same ids replay safely. */
export const layerDispatcher = Layer.effect(
  WaitDispatcher,
  Effect.gen(function* () {
    const threads = yield* ThreadManagementService.ThreadManagementService;
    return WaitDispatcher.of({
      send: Effect.fn("WaitDispatcher.send")((wait) => {
        const { threadId, projectId } = wait.origin;
        if (threadId === undefined || projectId === undefined) {
          return Effect.fail(waitError("The wait has no thread to continue.", { waitId: wait.id }));
        }
        return threads
          .sendToThread({
            projectId,
            threadId,
            commandId: CommandId.make(`wait:${wait.id}`),
            messageId: MessageId.make(`wait-message:${wait.id}`),
            text: wait.next,
            attachments: [],
            mode: "queue",
            createdBy: "system",
            creationSource: "server",
          })
          .pipe(
            Effect.asVoid,
            Effect.mapError((cause) =>
              waitError(`Could not send the next step: ${cause.message}`, {
                waitId: wait.id,
                cause,
              }),
            ),
          );
      }),
    });
  }),
);

/** Reads pull requests through the server's source-control service and URLs with fetch. */
export const layerCheckers = Layer.effect(
  WaitCheckers,
  Effect.gen(function* () {
    const pullRequests = yield* PullRequestService.PullRequestService;
    return WaitCheckers.of({
      pullRequestState: Effect.fn("WaitCheckers.pullRequestState")((input) =>
        pullRequests
          .summary({
            projectId: input.projectId,
            repository: input.repository,
            number: input.number,
            ...(input.host === undefined ? {} : { host: input.host }),
          })
          .pipe(
            Effect.map((summary) => summary.state),
            Effect.mapError((cause) => new WaitCheckFailed({ message: cause.message })),
          ),
      ),
      urlStatus: Effect.fn("WaitCheckers.urlStatus")((url) =>
        Effect.tryPromise({
          try: async (signal) => {
            // @effect-diagnostics-next-line globalFetchInEffect:off -- One status read with a hard timeout; no response body is kept.
            const response = await fetch(url, {
              method: "GET",
              redirect: "manual",
              signal: AbortSignal.any([signal, AbortSignal.timeout(URL_CHECK_TIMEOUT_MS)]),
            });
            void response.body?.cancel();
            return response.status;
          },
          catch: (cause) =>
            new WaitCheckFailed({
              message: cause instanceof Error ? cause.message : String(cause),
            }),
        }),
      ),
    });
  }),
);
