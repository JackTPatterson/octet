import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import { assert, it } from "@effect/vitest";
import { ProjectId, ThreadId, WaitError, type Wait, type WaitCondition } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as SqlClient from "effect/sql/SqlClient";
import * as TestClock from "effect/testing/TestClock";

import * as SqlitePersistence from "../persistence/Sqlite.ts";
import * as Scheduler from "../scheduling/Scheduler.ts";
import { WaitCheckers, WaitCheckFailed } from "./WaitConditions.ts";
import * as WaitService from "./WaitService.ts";

const iso = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));
const T0 = Date.parse("2026-11-05T12:00:00.000Z");
const origin = {
  threadId: ThreadId.make("thread:1"),
  projectId: ProjectId.make("project:1"),
  cwd: "/work",
};

interface Fakes {
  prState: Ref.Ref<"open" | "closed" | "merged" | "error">;
  urlStatus: Ref.Ref<number | "error">;
  sent: Ref.Ref<ReadonlyArray<Wait>>;
  sendFails: Ref.Ref<boolean>;
}

const makeFakes = Effect.gen(function* () {
  return {
    prState: yield* Ref.make<"open" | "closed" | "merged" | "error">("open"),
    urlStatus: yield* Ref.make<number | "error">(503),
    sent: yield* Ref.make<ReadonlyArray<Wait>>([]),
    sendFails: yield* Ref.make(false),
  } satisfies Fakes;
});

const layerFor = (fakes: Fakes) =>
  WaitService.layer.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(
          WaitCheckers,
          WaitCheckers.of({
            pullRequestState: () =>
              Effect.gen(function* () {
                const state = yield* Ref.get(fakes.prState);
                if (state === "error") return yield* new WaitCheckFailed({ message: "api down" });
                return state;
              }),
            urlStatus: () =>
              Effect.gen(function* () {
                const status = yield* Ref.get(fakes.urlStatus);
                if (status === "error") return yield* new WaitCheckFailed({ message: "refused" });
                return status;
              }),
          }),
        ),
        Layer.succeed(
          WaitService.WaitDispatcher,
          WaitService.WaitDispatcher.of({
            send: (wait) =>
              Ref.get(fakes.sendFails).pipe(
                Effect.flatMap((fails) =>
                  fails
                    ? Effect.fail(new WaitError({ message: "thread gone" }))
                    : Ref.update(fakes.sent, (sent) => [...sent, wait]),
                ),
              ),
          }),
        ),
        Scheduler.layer,
        NodeCrypto.layer,
      ),
    ),
  );

const withService = <A, E>(
  body: (
    service: WaitService.WaitService["Service"],
    fakes: Fakes,
  ) => Effect.Effect<A, E, SqlClient.SqlClient>,
) =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T0);
    const fakes = yield* makeFakes;
    return yield* Effect.gen(function* () {
      const service = yield* WaitService.WaitService;
      return yield* body(service, fakes);
    }).pipe(Effect.provide(layerFor(fakes)));
  }).pipe(Effect.provide(SqlitePersistence.layerMemory));

const prWait = (overrides: Record<string, unknown> = {}) => ({
  title: "the migration PR merged",
  condition: { type: "pull_request_merged", repository: "o/r", number: 9 } as WaitCondition,
  next: "Deploy it",
  origin,
  ...overrides,
});

it.effect("round trips a wait through SQLite", () =>
  withService((service) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create(prWait({ createdBy: "claude" }));
      assert.equal(wait.state, "waiting");
      assert.equal(wait.createdBy, "claude");
      assert.deepEqual(wait.origin, origin);
      assert.deepEqual(wait.condition, prWait().condition);
      assert.equal(wait.createdAt, iso(T0));
      assert.isFalse(wait.autoContinue);
      const { waits } = yield* service.list();
      assert.deepEqual(waits, [wait]);
    }),
  ),
);

it.effect("waiting becomes ready when the condition is met, without sending", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create(prWait());
      yield* service.runDue();
      const checked = (yield* service.list()).waits[0]!;
      assert.equal(checked.state, "waiting");
      assert.equal(checked.lastResult, "Open");
      assert.isNotNull(checked.lastCheckedAt);
      // A not-yet check schedules the next one, not due yet.
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.lastCheckedAt, checked.lastCheckedAt);

      yield* Ref.set(fakes.prState, "merged");
      yield* TestClock.adjust("10 minutes");
      yield* service.runDue();
      const ready = (yield* service.list()).waits[0]!;
      assert.equal(ready.id, wait.id);
      assert.equal(ready.state, "ready");
      assert.equal(ready.lastResult, "Merged");
      assert.isNotNull(ready.readyAt);
      assert.isNull(ready.nextCheckAt);
      assert.isNull(ready.continuedAt);
      assert.lengthOf(yield* Ref.get(fakes.sent), 0);
    }),
  ),
);

it.effect("autoContinue sends the next step once when it becomes ready", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* Ref.set(fakes.prState, "merged");
      yield* service.create(prWait({ autoContinue: true }));
      yield* service.runDue();
      yield* service.runDue();
      const sent = yield* Ref.get(fakes.sent);
      assert.lengthOf(sent, 1);
      assert.equal(sent[0]!.next, "Deploy it");
      const wait = (yield* service.list()).waits[0]!;
      assert.equal(wait.state, "ready");
      assert.isNotNull(wait.continuedAt);
    }),
  ),
);

it.effect("a failed send leaves the wait ready and unsent, and `continue` retries it", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* Ref.set(fakes.prState, "merged");
      yield* Ref.set(fakes.sendFails, true);
      const { wait } = yield* service.create(prWait({ autoContinue: true }));
      yield* service.runDue();
      const stuck = (yield* service.list()).waits[0]!;
      assert.equal(stuck.state, "ready");
      assert.isNull(stuck.continuedAt);
      assert.include(stuck.lastResult ?? "", "thread gone");

      yield* Ref.set(fakes.sendFails, false);
      const { wait: resolved } = yield* service.resolve({ id: wait.id, action: "continue" });
      assert.isNotNull(resolved.continuedAt);
      assert.lengthOf(yield* Ref.get(fakes.sent), 1);
      // Continuing again does not send twice.
      yield* service.resolve({ id: wait.id, action: "continue" });
      assert.lengthOf(yield* Ref.get(fakes.sent), 1);
    }),
  ),
);

it.effect("failures count up and back the next check off; success resets them", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* Ref.set(fakes.prState, "error");
      yield* service.create(prWait());
      yield* service.runDue();
      const first = (yield* service.list()).waits[0]!;
      assert.equal(first.failures, 1);
      assert.equal(first.lastResult, "api down");
      // 5 minute base doubled once: not due after 9 minutes, due after 10.
      yield* TestClock.adjust("9 minutes");
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.failures, 1);
      yield* TestClock.adjust("2 minutes");
      yield* service.runDue();
      const second = (yield* service.list()).waits[0]!;
      assert.equal(second.failures, 2);
      assert.isAbove(Date.parse(second.nextCheckAt!), Date.parse(first.nextCheckAt!));

      yield* Ref.set(fakes.prState, "open");
      yield* TestClock.adjust("1 hour");
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.failures, 0);
    }),
  ),
);

it.effect("a date wait is ready at its time, and a past one at once", () =>
  withService((service) =>
    Effect.gen(function* () {
      const future = iso(T0 + 3_600_000);
      yield* service.create({
        title: "tomorrow",
        condition: { type: "date", at: future },
        origin,
      });
      yield* service.create({
        title: "already",
        condition: { type: "date", at: iso(T0 - 1000) },
        origin,
      });
      yield* service.runDue();
      const byTitle = (yield* service.list()).waits;
      assert.equal(byTitle.find((w) => w.title === "already")!.state, "ready");
      assert.equal(byTitle.find((w) => w.title === "tomorrow")!.state, "waiting");
      yield* TestClock.adjust("1 hour");
      yield* service.runDue();
      const later = (yield* service.list()).waits;
      assert.equal(later.find((w) => w.title === "tomorrow")!.state, "ready");
    }),
  ),
);

it.effect("a url wait becomes ready when it answers", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* service.create({
        title: "site up",
        condition: { type: "url_up", url: "https://example.com" },
        origin,
      });
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.state, "waiting");
      yield* Ref.set(fakes.urlStatus, 200);
      yield* TestClock.adjust("10 minutes");
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.state, "ready");
    }),
  ),
);

it.effect("a cancelled wait is not checked or continued", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* Ref.set(fakes.prState, "merged");
      const { wait } = yield* service.create(prWait({ autoContinue: true }));
      const { wait: cancelled } = yield* service.cancel({ id: wait.id });
      assert.equal(cancelled.state, "cancelled");
      assert.isNull(cancelled.nextCheckAt);
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.state, "cancelled");
      assert.lengthOf(yield* Ref.get(fakes.sent), 0);
      const refused = yield* service.resolve({ id: wait.id, action: "ready" }).pipe(Effect.flip);
      assert.equal(refused._tag, "WaitError");
    }),
  ),
);

it.effect("a manual wait is never checked and is settled by the person", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create({
        title: "Ask Sam",
        condition: { type: "manual" },
        next: "Continue with Sam's answer",
        origin,
      });
      assert.isNull(wait.nextCheckAt);
      yield* TestClock.adjust("2 hours");
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.state, "waiting");
      const { wait: ready } = yield* service.resolve({ id: wait.id, action: "ready" });
      assert.equal(ready.state, "ready");
      assert.lengthOf(yield* Ref.get(fakes.sent), 0);
      const { wait: continued } = yield* service.resolve({ id: wait.id, action: "continue" });
      assert.isNotNull(continued.continuedAt);
      assert.lengthOf(yield* Ref.get(fakes.sent), 1);
    }),
  ),
);

it.effect("refuses waits that cannot work", () =>
  withService((service) =>
    Effect.gen(function* () {
      const reasons = yield* Effect.forEach(
        [
          prWait({ condition: { type: "date", at: "someday" } }),
          prWait({ condition: { type: "url_up", url: "file:///x" } }),
          prWait({ origin: { cwd: "/work" } }),
          prWait({ autoContinue: true, next: "" }),
          prWait({ autoContinue: true, origin: { projectId: origin.projectId, cwd: "/w" } }),
        ],
        (input) => service.create(input).pipe(Effect.flip),
      );
      assert.lengthOf(reasons, 5);
      assert.lengthOf((yield* service.list()).waits, 0);
    }),
  ),
);

it.effect("one wait that cannot be read does not stop the poller or the rest", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      yield* Ref.set(fakes.prState, "merged");
      yield* service.create(prWait());
      yield* sql`INSERT INTO waits (wait_id, title, condition_json, next, created_at, created_by,
          origin_json, state, auto_continue, failures, next_check_at)
        VALUES ('wait:bad', 't', 'not json', '', ${iso(T0)}, 'you', '{}',
          'waiting', 0, 0, ${iso(T0 - 1)})`;
      yield* service.runDue();
      const { waits } = yield* service.list();
      assert.lengthOf(waits, 1);
      assert.equal(waits[0]!.state, "ready");
      const bad = yield* sql<{
        failures: number;
      }>`SELECT failures FROM waits WHERE wait_id = 'wait:bad'`;
      assert.equal(bad[0]!.failures, 1);
    }),
  ),
);

it.effect("subscribers get the list again after each change", () =>
  withService((service) =>
    Effect.gen(function* () {
      const fiber = yield* service
        .subscribeList()
        .pipe(Stream.take(2), Stream.runCollect, Effect.forkChild);
      yield* Effect.yieldNow;
      yield* service.create(prWait());
      const lists = yield* Fiber.join(fiber);
      assert.deepEqual(
        Array.from(lists).map((list) => list.waits.length),
        [0, 1],
      );
    }),
  ),
);

it.effect("the scheduler polls waits on its own", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      yield* Ref.set(fakes.prState, "merged");
      yield* service.create(prWait({ autoContinue: true }));
      yield* TestClock.adjust("6 seconds");
      yield* Effect.yieldNow;
      assert.equal((yield* service.list()).waits[0]!.state, "ready");
      assert.lengthOf(yield* Ref.get(fakes.sent), 1);
    }),
  ),
);

it.effect("update edits the title, next step and condition, and a new condition is checked afresh", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create(prWait());
      yield* service.runDue();
      assert.equal((yield* service.list()).waits[0]!.lastResult, "Open");

      const edited = (yield* service.update({
        id: wait.id,
        title: "  the other PR merged  ",
        next: " Ship it ",
        autoContinue: true,
        condition: { type: "pull_request_merged", repository: "o/r", number: 10 },
      })).wait;
      assert.equal(edited.title, "the other PR merged");
      assert.equal(edited.next, "Ship it");
      assert.isTrue(edited.autoContinue);
      assert.deepEqual(edited.condition, { type: "pull_request_merged", repository: "o/r", number: 10 });
      // Checking starts over, and is due at once.
      assert.isNull(edited.lastCheckedAt);
      assert.isNull(edited.lastResult);
      assert.equal(edited.failures, 0);
      assert.equal(edited.nextCheckAt, iso(T0));

      yield* Ref.set(fakes.prState, "merged");
      yield* service.runDue();
      assert.lengthOf(yield* Ref.get(fakes.sent), 1);
    }),
  ),
);

it.effect("update that leaves the condition alone keeps its check history", () =>
  withService((service) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create(prWait());
      yield* service.runDue();
      const before = (yield* service.list()).waits[0]!;
      const edited = (yield* service.update({
        id: wait.id,
        next: "Different",
        condition: before.condition,
      })).wait;
      assert.equal(edited.next, "Different");
      assert.equal(edited.lastCheckedAt, before.lastCheckedAt);
      assert.equal(edited.nextCheckAt, before.nextCheckAt);
    }),
  ),
);

it.effect("update refuses what a new wait would refuse", () =>
  withService((service) =>
    Effect.gen(function* () {
      const { wait } = yield* service.create(prWait());
      const bad = (input: Parameters<typeof service.update>[0]) =>
        service.update(input).pipe(Effect.flip, Effect.map((error) => error.message));
      assert.include(
        yield* bad({ id: wait.id, condition: { type: "url_up", url: "ftp://x" } }),
        "http or https",
      );
      assert.include(
        yield* bad({ id: wait.id, condition: { type: "date", at: "soon" } }),
        "ISO 8601",
      );
      assert.include(yield* bad({ id: wait.id, next: "", autoContinue: true }), "needs a next step");
    }),
  ),
);

it.effect("update can't touch a cancelled or carried-on wait, nor re-aim a ready one", () =>
  withService((service, fakes) =>
    Effect.gen(function* () {
      const flipped = (input: Parameters<typeof service.update>[0]) =>
        service.update(input).pipe(Effect.flip, Effect.map((error) => error.message));

      const cancelled = (yield* service.create(prWait())).wait;
      yield* service.cancel({ id: cancelled.id });
      assert.include(yield* flipped({ id: cancelled.id, title: "x" }), "cancelled");

      yield* Ref.set(fakes.prState, "merged");
      const ready = (yield* service.create(prWait())).wait;
      yield* service.runDue();
      // A ready wait still takes a new next step, but not a new condition.
      const retitled = (yield* service.update({ id: ready.id, next: "Do this instead" })).wait;
      assert.equal(retitled.next, "Do this instead");
      assert.include(
        yield* flipped({ id: ready.id, condition: { type: "url_up", url: "https://x.test" } }),
        "ready",
      );

      yield* service.resolve({ id: ready.id, action: "continue" });
      assert.include(yield* flipped({ id: ready.id, title: "late" }), "already carried on");
    }),
  ),
);
