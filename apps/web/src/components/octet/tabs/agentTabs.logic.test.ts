import { describe, expect, it } from "vite-plus/test";

import { adjacentTab, agentTabsFor, tabAfterClosing } from "./agentTabs.logic";

const tab = (id: string) => ({ id });
const tabs = [tab("a"), tab("b"), tab("c")];

describe("tabAfterClosing", () => {
  it("prefers the tab before, then the one after", () => {
    expect(tabAfterClosing(tabs, "b")?.id).toBe("a");
    expect(tabAfterClosing(tabs, "a")?.id).toBe("b");
    expect(tabAfterClosing(tabs, "c")?.id).toBe("b");
  });
  it("has nowhere to go from the only tab, or an unknown one", () => {
    expect(tabAfterClosing([tab("a")], "a")).toBeNull();
    expect(tabAfterClosing(tabs, "z")).toBeNull();
  });
});

describe("adjacentTab", () => {
  it("steps along and wraps round", () => {
    expect(adjacentTab(tabs, "a", 1)?.id).toBe("b");
    expect(adjacentTab(tabs, "c", 1)?.id).toBe("a");
    expect(adjacentTab(tabs, "a", -1)?.id).toBe("c");
  });
});

describe("agentTabsFor", () => {
  const thread = (id: string, extra: Record<string, unknown> = {}) => ({
    id,
    environmentId: "env",
    projectId: "p",
    branch: "main",
    worktreePath: null,
    createdAt: Number(id.replace(/\D/g, "")) || 0,
    ...extra,
  });
  it("lists a branch's live threads oldest first and keeps the one in view", () => {
    const result = agentTabsFor(
      [
        thread("t3"),
        thread("t1"),
        thread("t2", { settledOverride: "settled" }),
        thread("t5", { branch: "other" }),
      ],
      { environmentId: "env", id: "t2" },
    );
    expect(result?.map((t) => t.id)).toEqual(["t1", "t2", "t3"]);
  });
  it("puts each subagent right after the agent that started it", () => {
    const sub = (id: string, parent: string, extra: Record<string, unknown> = {}) =>
      thread(id, { branch: "elsewhere", lineage: { relationshipToParent: "subagent", parentThreadId: parent }, ...extra });
    const result = agentTabsFor(
      [
        thread("t1"),
        thread("t2"),
        sub("t6", "t1"),
        sub("t7", "t6"),
        sub("t8", "t1", { settledOverride: "settled" }),
        thread("t9", { lineage: { sideChat: true } }),
      ],
      { environmentId: "env", id: "t1" },
    );
    expect(result?.map((t) => t.id)).toEqual(["t1", "t6", "t7", "t2"]);
  });
  it("shows a subagent in view even when its parent is elsewhere", () => {
    const orphan = thread("t4", { lineage: { relationshipToParent: "subagent", parentThreadId: "gone" } });
    expect(agentTabsFor([thread("t1"), orphan], { environmentId: "env", id: "t4" })?.map((t) => t.id)).toEqual([
      "t1",
      "t4",
    ]);
  });
});
