import type { Wait, WaitCondition } from "@t3tools/contracts";
import type { ProjectId, PullRequestState } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

/** Reading the outside world failed; the wait backs off and tries again. */
export class WaitCheckFailed extends Data.TaggedError("WaitCheckFailed")<{
  readonly message: string;
}> {}

/** What one check of a wait's condition found. */
export type WaitCheck =
  | { readonly _tag: "met"; readonly result: string }
  | { readonly _tag: "notYet"; readonly result: string }
  | { readonly _tag: "failed"; readonly result: string };

/** The outside world a check reads; injectable so conditions test without a network. */
export class WaitCheckers extends Context.Service<
  WaitCheckers,
  {
    readonly pullRequestState: (input: {
      readonly projectId: ProjectId;
      readonly repository: string;
      readonly number: number;
      readonly host?: string | undefined;
    }) => Effect.Effect<PullRequestState, WaitCheckFailed>;
    /** The HTTP status the URL answers, without following redirects. */
    readonly urlStatus: (url: string) => Effect.Effect<number, WaitCheckFailed>;
  }
>()("t3/waits/WaitConditions/WaitCheckers") {}

export const URL_CHECK_TIMEOUT_MS = 10_000;

const describeError = (error: unknown): string =>
  error instanceof Error
    ? error.message
    : typeof error === "object" && error !== null && "message" in error
      ? String((error as { message: unknown }).message)
      : String(error);

/** A date the wait can compare with the clock, or null when it is not a real time. */
export const parseWaitDate = (at: string): number | null => {
  const time = Date.parse(at);
  return Number.isFinite(time) ? time : null;
};

/** Only http(s) URLs are fetched. */
export const parseWaitUrl = (raw: string): URL | null => {
  try {
    const url = new URL(raw);
    return url.protocol === "http:" || url.protocol === "https:" ? url : null;
  } catch {
    return null;
  }
};

/** Whether a person, not the server, settles this condition. */
export const isManualCondition = (condition: WaitCondition): boolean => condition.type === "manual";

/**
 * Checks one condition. Never fails: an error reading the outside world is a
 * `failed` check, which backs the next check off.
 */
export const checkWaitCondition = (
  wait: Pick<Wait, "condition" | "origin">,
  nowMs: number,
): Effect.Effect<WaitCheck, never, WaitCheckers> =>
  Effect.gen(function* () {
    const checkers = yield* WaitCheckers;
    const condition = wait.condition;
    switch (condition.type) {
      case "manual":
        return { _tag: "notYet", result: "Waiting for you to confirm" } satisfies WaitCheck;
      case "date": {
        const at = parseWaitDate(condition.at);
        if (at === null) return { _tag: "failed", result: "Not a valid date" } satisfies WaitCheck;
        return nowMs >= at
          ? ({ _tag: "met", result: "The time has come" } satisfies WaitCheck)
          : ({ _tag: "notYet", result: "Not yet" } satisfies WaitCheck);
      }
      case "pull_request_merged": {
        const projectId = wait.origin.projectId;
        if (projectId === undefined) {
          return {
            _tag: "failed",
            result: "No project to read the pull request from",
          } satisfies WaitCheck;
        }
        const state = yield* checkers
          .pullRequestState({
            projectId,
            repository: condition.repository,
            number: condition.number,
            host: condition.host,
          })
          .pipe(
            Effect.map((value) => ({ _tag: "ok", value }) as const),
            Effect.catchCause((cause) =>
              Effect.succeed({
                _tag: "error",
                message: describeError(Cause.squash(cause)),
              } as const),
            ),
          );
        if (state._tag === "error") {
          return { _tag: "failed", result: state.message } satisfies WaitCheck;
        }
        const label =
          state.value === "merged" ? "Merged" : state.value === "open" ? "Open" : "Closed";
        return state.value === "merged"
          ? ({ _tag: "met", result: label } satisfies WaitCheck)
          : ({ _tag: "notYet", result: label } satisfies WaitCheck);
      }
      case "url_up": {
        if (parseWaitUrl(condition.url) === null) {
          return { _tag: "failed", result: "Not an http(s) URL" } satisfies WaitCheck;
        }
        const status = yield* checkers.urlStatus(condition.url).pipe(
          Effect.map((value) => ({ _tag: "ok", value }) as const),
          Effect.catchCause((cause) =>
            Effect.succeed({ _tag: "error", message: describeError(Cause.squash(cause)) } as const),
          ),
        );
        if (status._tag === "error") {
          return { _tag: "notYet", result: `Not reachable: ${status.message}` } satisfies WaitCheck;
        }
        return status.value >= 200 && status.value < 400
          ? ({ _tag: "met", result: `Up (${status.value})` } satisfies WaitCheck)
          : ({ _tag: "notYet", result: `Answered ${status.value}` } satisfies WaitCheck);
      }
    }
  });

const HOUR = 3_600_000;
const DAY = 86_400_000;
const MAX_BACKOFF_MS = 12 * HOUR;

/**
 * Often while a wait is new, when the thing waited on most often happens soon
 * after; then less and less. A failure doubles the gap, up to 12 hours.
 */
export const waitCheckIntervalMs = (waitingForMs: number, failures: number): number => {
  const base =
    waitingForMs < HOUR
      ? 5 * 60_000
      : waitingForMs < DAY
        ? 15 * 60_000
        : waitingForMs < 7 * DAY
          ? HOUR
          : 4 * HOUR;
  return Math.min(base * 2 ** Math.min(failures, 5), MAX_BACKOFF_MS);
};

/** When to check next; a date wait in the future is checked at that time. */
export const nextWaitCheckMs = (input: {
  readonly condition: WaitCondition;
  readonly nowMs: number;
  readonly createdAtMs: number;
  readonly failures: number;
}): number => {
  if (input.condition.type === "date") {
    const at = parseWaitDate(input.condition.at);
    if (at !== null && at > input.nowMs && input.failures === 0) return at;
  }
  return input.nowMs + waitCheckIntervalMs(input.nowMs - input.createdAtMs, input.failures);
};
