import { assert, it } from "@effect/vitest";
import { ProjectId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  checkWaitCondition,
  nextWaitCheckMs,
  parseWaitUrl,
  waitCheckIntervalMs,
  WaitCheckers,
  WaitCheckFailed,
} from "./WaitConditions.ts";

const NOW = Date.parse("2026-11-05T12:00:00.000Z");
const origin = { projectId: ProjectId.make("project:1"), cwd: "/work" };

const checkers = (overrides: Partial<WaitCheckers["Service"]> = {}) =>
  Layer.succeed(
    WaitCheckers,
    WaitCheckers.of({
      pullRequestState: () => Effect.succeed("open"),
      urlStatus: () => Effect.succeed(200),
      ...overrides,
    }),
  );

const run = (
  condition: Parameters<typeof checkWaitCondition>[0]["condition"],
  layer: Layer.Layer<WaitCheckers>,
  withOrigin: Parameters<typeof checkWaitCondition>[0]["origin"] = origin,
) => checkWaitCondition({ condition, origin: withOrigin }, NOW).pipe(Effect.provide(layer));

it.effect("a date is met once now has reached it", () =>
  Effect.gen(function* () {
    const before = yield* run({ type: "date", at: "2026-11-05T12:00:01.000Z" }, checkers());
    assert.equal(before._tag, "notYet");
    const at = yield* run({ type: "date", at: "2026-11-05T12:00:00.000Z" }, checkers());
    assert.equal(at._tag, "met");
    const bad = yield* run({ type: "date", at: "someday" }, checkers());
    assert.equal(bad._tag, "failed");
  }),
);

it.effect("a pull request is met only when merged", () =>
  Effect.gen(function* () {
    const condition = { type: "pull_request_merged", repository: "o/r", number: 4 } as const;
    for (const [state, tag] of [
      ["open", "notYet"],
      ["closed", "notYet"],
      ["merged", "met"],
    ] as const) {
      const check = yield* run(
        condition,
        checkers({ pullRequestState: () => Effect.succeed(state) }),
      );
      assert.equal(check._tag, tag);
    }
  }),
);

it.effect("a pull request read that errors or has no project is a failed check", () =>
  Effect.gen(function* () {
    const condition = { type: "pull_request_merged", repository: "o/r", number: 4 } as const;
    const errored = yield* run(
      condition,
      checkers({
        pullRequestState: () => Effect.fail(new WaitCheckFailed({ message: "rate limited" })),
      }),
    );
    assert.deepEqual(errored, { _tag: "failed", result: "rate limited" });
    const defect = yield* run(
      condition,
      checkers({ pullRequestState: () => Effect.die(new Error("boom")) }),
    );
    assert.equal(defect._tag, "failed");
    const orphan = yield* run(condition, checkers(), { cwd: "/work" });
    assert.equal(orphan._tag, "failed");
  }),
);

it.effect("a url is up on 2xx and 3xx and not yet otherwise", () =>
  Effect.gen(function* () {
    const condition = { type: "url_up", url: "https://example.com/health" } as const;
    for (const [status, tag] of [
      [200, "met"],
      [204, "met"],
      [302, "met"],
      [404, "notYet"],
      [503, "notYet"],
    ] as const) {
      const check = yield* run(condition, checkers({ urlStatus: () => Effect.succeed(status) }));
      assert.equal(check._tag, tag, `status ${status}`);
    }
    const down = yield* run(
      condition,
      checkers({ urlStatus: () => Effect.fail(new WaitCheckFailed({ message: "ECONNREFUSED" })) }),
    );
    assert.equal(down._tag, "notYet");
    const notHttp = yield* run({ type: "url_up", url: "file:///etc/passwd" }, checkers());
    assert.equal(notHttp._tag, "failed");
  }),
);

it("parseWaitUrl accepts only http and https", () => {
  assert.isNotNull(parseWaitUrl("http://a.test"));
  assert.isNotNull(parseWaitUrl("https://a.test/x"));
  assert.isNull(parseWaitUrl("ftp://a.test"));
  assert.isNull(parseWaitUrl("nope"));
});

it("check interval grows with age and doubles per failure up to the cap", () => {
  const minute = 60_000;
  const hour = 60 * minute;
  assert.equal(waitCheckIntervalMs(10 * minute, 0), 5 * minute);
  assert.equal(waitCheckIntervalMs(2 * hour, 0), 15 * minute);
  assert.equal(waitCheckIntervalMs(2 * 24 * hour, 0), hour);
  assert.equal(waitCheckIntervalMs(30 * 24 * hour, 0), 4 * hour);
  assert.equal(waitCheckIntervalMs(10 * minute, 1), 10 * minute);
  assert.equal(waitCheckIntervalMs(10 * minute, 3), 40 * minute);
  assert.equal(waitCheckIntervalMs(30 * 24 * hour, 9), 12 * hour);
});

it("a future date is checked at that time, a past one by the interval", () => {
  const at = "2026-11-06T12:00:00.000Z";
  const condition = { type: "date", at } as const;
  assert.equal(
    nextWaitCheckMs({ condition, nowMs: NOW, createdAtMs: NOW, failures: 0 }),
    Date.parse(at),
  );
  assert.equal(
    nextWaitCheckMs({ condition, nowMs: Date.parse(at) + 1, createdAtMs: NOW, failures: 0 }),
    Date.parse(at) + 1 + 4 * 3_600_000 * 0 + waitCheckIntervalMs(Date.parse(at) + 1 - NOW, 0),
  );
});
