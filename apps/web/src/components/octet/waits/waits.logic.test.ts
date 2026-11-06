import { describe, expect, it } from "vite-plus/test";

import {
  describeWaitCondition,
  EMPTY_WAIT_FORM,
  visibleWaits,
  waitAction,
  waitConditionFromForm,
  waitFormFromWait,
  waitFormProblem,
  waitStatusLabel,
  type WaitForm,
  type WaitLike,
} from "./waits.logic";

const wait = (id: string, overrides: Partial<WaitLike> = {}): WaitLike => ({
  id,
  title: `Wait ${id}`,
  condition: { type: "manual" },
  next: "",
  state: "waiting",
  continuedAt: null,
  readyAt: null,
  createdAt: "2026-11-05T10:00:00.000Z",
  createdBy: "you",
  lastResult: null,
  origin: {},
  ...overrides,
});

const baseWait = { ...wait("base"), autoContinue: false };

describe("describeWaitCondition", () => {
  it("says what each condition waits for", () => {
    expect(describeWaitCondition({ type: "pull_request_merged", repository: "acme/app", number: 12 })).toBe(
      "acme/app#12 merged",
    );
    expect(describeWaitCondition({ type: "url_up", url: "https://staging.example.com/health" })).toBe(
      "staging.example.com up",
    );
    expect(describeWaitCondition({ type: "url_up", url: "not a url" })).toBe("not a url up");
    expect(describeWaitCondition({ type: "manual", description: "Legal signs off" })).toBe("Legal signs off");
    expect(describeWaitCondition({ type: "manual" })).toBe("Waiting on you");
  });

  it("formats a date, and falls back to the raw text when it isn't one", () => {
    expect(describeWaitCondition({ type: "date", at: "2026-11-12T15:00:00.000Z" }, "en-US")).toMatch(/Nov 12/);
    expect(describeWaitCondition({ type: "date", at: "soon" })).toBe("soon");
  });
});

describe("visibleWaits", () => {
  it("hides cancelled and already-continued waits, ready ones first, then newest", () => {
    const shown = visibleWaits([
      wait("old", { createdAt: "2026-11-01T00:00:00.000Z" }),
      wait("new", { createdAt: "2026-11-04T00:00:00.000Z" }),
      wait("ready", { state: "ready", createdAt: "2026-10-01T00:00:00.000Z" }),
      wait("cancelled", { state: "cancelled" }),
      wait("sent", { state: "ready", continuedAt: "2026-11-05T11:00:00.000Z" }),
    ]);
    expect(shown.map((entry) => entry.id)).toEqual(["ready", "new", "old"]);
  });
});

describe("waitAction", () => {
  it("offers Continue on a ready wait with a next step", () => {
    expect(waitAction({ state: "ready", condition: { type: "url_up", url: "https://x.dev" }, next: "Deploy" })).toBe(
      "continue",
    );
  });

  it("offers Done on a waiting manual wait only", () => {
    expect(waitAction({ state: "waiting", condition: { type: "manual" }, next: "" })).toBe("done");
    expect(waitAction({ state: "waiting", condition: { type: "date", at: "2026-11-12T00:00:00Z" }, next: "x" })).toBeNull();
  });

  it("offers nothing on a ready wait with nothing to send", () => {
    expect(waitAction({ state: "ready", condition: { type: "manual" }, next: "  " })).toBeNull();
  });
});

describe("waitStatusLabel", () => {
  it("shows the last check's result while waiting", () => {
    expect(waitStatusLabel({ state: "ready", lastResult: "Merged" })).toBe("Ready");
    expect(waitStatusLabel({ state: "waiting", lastResult: "Open" })).toBe("Waiting · Open");
    expect(waitStatusLabel({ state: "waiting", lastResult: null })).toBe("Waiting");
  });
});

describe("wait forms", () => {
  const ctx = { canSendNext: true, hasProject: true };
  const form = (over: Partial<WaitForm>): WaitForm => ({ ...EMPTY_WAIT_FORM, title: "Release", ...over });

  it("needs a title", () => {
    expect(waitFormProblem(form({ title: "  " }), ctx)).toMatch(/waiting for/);
    expect(waitFormProblem(form({}), ctx)).toBeNull();
  });

  it("builds each condition, and rejects the incomplete", () => {
    expect(waitConditionFromForm(form({ kind: "manual", description: " Approved " }))).toEqual({
      type: "manual",
      description: "Approved",
    });
    expect(waitConditionFromForm(form({ kind: "manual" }))).toEqual({ type: "manual" });
    expect(waitConditionFromForm(form({ kind: "date" }))).toBeNull();
    expect(waitConditionFromForm(form({ kind: "date", date: "2026-11-12T15:00" }))).toEqual({
      type: "date",
      at: new Date("2026-11-12T15:00").toISOString(),
    });
    expect(
      waitConditionFromForm(form({ kind: "pull_request_merged", repository: "acme/app", number: "12" })),
    ).toEqual({ type: "pull_request_merged", repository: "acme/app", number: 12 });
    expect(
      waitConditionFromForm(form({ kind: "pull_request_merged", repository: "acme", number: "12" })),
    ).toBeNull();
    expect(
      waitConditionFromForm(form({ kind: "pull_request_merged", repository: "a/b", number: "0" })),
    ).toBeNull();
    expect(waitConditionFromForm(form({ kind: "url_up", url: "https://x.test/up" }))).toEqual({
      type: "url_up",
      url: "https://x.test/up",
    });
    expect(waitConditionFromForm(form({ kind: "url_up", url: "ftp://x.test" }))).toBeNull();
    expect(waitConditionFromForm(form({ kind: "url_up", url: "nope" }))).toBeNull();
  });

  it("explains what is missing", () => {
    expect(waitFormProblem(form({ kind: "date" }), ctx)).toMatch(/date/);
    expect(waitFormProblem(form({ kind: "url_up", url: "x" }), ctx)).toMatch(/URL/);
    const pr = form({ kind: "pull_request_merged", repository: "a/b", number: "3" });
    expect(waitFormProblem(pr, { ...ctx, hasProject: false })).toMatch(/project/);
  });

  it("auto-continue needs a next step and a thread", () => {
    expect(waitFormProblem(form({ autoContinue: true }), ctx)).toMatch(/next step/);
    expect(waitFormProblem(form({ autoContinue: true, next: "Go" }), { ...ctx, canSendNext: false })).toMatch(
      /thread/,
    );
    expect(waitFormProblem(form({ autoContinue: true, next: "Go" }), ctx)).toBeNull();
  });

  it("round-trips a wait into a form", () => {
    const wait = {
      ...baseWait,
      title: "PR",
      condition: { type: "pull_request_merged" as const, repository: "a/b", number: 4 },
      next: "Ship",
      autoContinue: true,
    };
    expect(waitFormFromWait(wait)).toMatchObject({
      title: "PR",
      kind: "pull_request_merged",
      repository: "a/b",
      number: "4",
      next: "Ship",
      autoContinue: true,
    });
    const dated = { ...baseWait, condition: { type: "date" as const, at: "2026-11-12T15:00:00.000Z" }, autoContinue: false };
    const local = waitFormFromWait(dated).date;
    expect(new Date(local).toISOString()).toBe("2026-11-12T15:00:00.000Z");
  });
});
