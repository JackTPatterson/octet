import { describe, expect, it } from "vite-plus/test";

import type { SidebarThreadStatus } from "../../Sidebar.logic";
import {
  filterBranchCards,
  groupIntoBranchCards,
  loudestStatus,
  peekRows,
  planCardDrop,
  projectInScope,
  resolveCardRename,
  threadActivityMs,
  type BranchCardThread,
} from "./octetSidebar.logic";

type TestThread = BranchCardThread & { status: SidebarThreadStatus };

const thread = (id: string, overrides: Partial<TestThread> = {}): TestThread =>
  ({
    id,
    environmentId: "env",
    title: `Thread ${id}`,
    branch: "main",
    worktreePath: null,
    updatedAt: "2026-11-04T10:00:00.000Z",
    latestUserMessageAt: null,
    status: "ready",
    ...overrides,
  }) as TestThread;

describe("groupIntoBranchCards", () => {
  it("puts threads on the same branch in one card, newest first", () => {
    const cards = groupIntoBranchCards(
      [
        thread("a", { updatedAt: "2026-11-04T09:00:00.000Z" }),
        thread("b", { updatedAt: "2026-11-04T11:00:00.000Z" }),
        thread("c", { branch: "feat/x", updatedAt: "2026-11-04T10:30:00.000Z" }),
      ],
      (entry) => entry.status,
    );
    expect(cards.map((card) => card.key)).toEqual(["branch:main", "branch:feat/x"]);
    expect(cards[0]!.threads.map((entry) => entry.id)).toEqual(["b", "a"]);
  });

  it("keeps worktrees apart even when they share a branch name", () => {
    const cards = groupIntoBranchCards(
      [thread("a", { worktreePath: "/w/one" }), thread("b", { worktreePath: "/w/two" }), thread("c")],
      (entry) => entry.status,
    );
    expect(cards).toHaveLength(3);
  });

  it("takes the loudest status of its threads", () => {
    const [card] = groupIntoBranchCards(
      [thread("a", { status: "working" }), thread("b", { status: "approval" }), thread("c")],
      (entry) => entry.status,
    );
    expect(card!.status).toBe("approval");
    expect(loudestStatus(["ready", "working"])).toBe("working");
    expect(loudestStatus(["working", "failed"])).toBe("failed");
    expect(loudestStatus([])).toBe("ready");
  });

  it("orders by a thread's latest message when it is newer than its last update", () => {
    const quiet = thread("a", {
      updatedAt: "2026-11-04T08:00:00.000Z",
      latestUserMessageAt: "2026-11-04T12:00:00.000Z",
    });
    expect(threadActivityMs(quiet)).toBe(Date.parse("2026-11-04T12:00:00.000Z"));
  });
});

describe("filterBranchCards", () => {
  it("keeps cards with a thread matching every word, in titles or branch", () => {
    const cards = groupIntoBranchCards(
      [
        thread("a", { title: "Fix login redirect" }),
        thread("b", { title: "Ship pricing page", branch: "feat/pricing" }),
      ],
      (entry) => entry.status,
    );
    expect(filterBranchCards(cards, "login fix").map((card) => card.key)).toEqual(["branch:main"]);
    expect(filterBranchCards(cards, "pricing").map((card) => card.key)).toEqual(["branch:feat/pricing"]);
    expect(filterBranchCards(cards, "  ")).toHaveLength(2);
  });
});

describe("planCardDrop", () => {
  it("settles on Idle and snoozes on Waiting", () => {
    expect(planCardDrop("active", "idle")).toBe("settle");
    expect(planCardDrop("active", "waiting")).toBe("snooze");
    expect(planCardDrop("waiting", "idle")).toBe("settle");
  });
  it("brings a shelved card back", () => {
    expect(planCardDrop("idle", "active")).toBe("unsettle");
    expect(planCardDrop("waiting", "active")).toBe("unsnooze");
  });
  it("ignores a drop where the card already is", () => {
    expect(planCardDrop("idle", "idle")).toBe("none");
    expect(planCardDrop("active", "active")).toBe("none");
  });
});

describe("projectInScope", () => {
  it("lets everything through with no filter", () => {
    expect(projectInScope("a", [])).toBe(true);
  });
  it("lets only chosen projects through", () => {
    expect(projectInScope("a", ["a", "b"])).toBe(true);
    expect(projectInScope("c", ["a", "b"])).toBe(false);
  });
});

describe("resolveCardRename", () => {
  it("rejects an empty title, ignores an unchanged one, trims the rest", () => {
    expect(resolveCardRename({ title: "  ", originalTitle: "x" })).toEqual({ action: "reject-empty" });
    expect(resolveCardRename({ title: "x", originalTitle: "x" })).toEqual({ action: "noop" });
    expect(resolveCardRename({ title: " y ", originalTitle: "x" })).toEqual({
      action: "commit",
      title: "y",
    });
  });
});

describe("peekRows", () => {
  it("lists the loudest thread first, keeping order among equals", () => {
    const [a, b, c] = [thread("a"), thread("b", { status: "approval" }), thread("c")];
    const [card] = groupIntoBranchCards([a, b, c], (t) => t.status);
    const rows = peekRows(card!, (t) => (t as TestThread).status);
    expect(rows.map((row) => row.id)[0]).toBe("b");
    expect(rows).toHaveLength(3);
  });
});
