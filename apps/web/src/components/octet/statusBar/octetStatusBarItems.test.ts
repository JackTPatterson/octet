import { describe, expect, it } from "vite-plus/test";

import {
  isDefaultStatusBar,
  moveStatusBarItem,
  resolveStatusBarOrder,
  setStatusBarItemVisible,
  visibleStatusBarItems,
} from "./octetStatusBarItems";

describe("resolveStatusBarOrder", () => {
  it("is the default order with nothing saved", () => {
    expect(resolveStatusBarOrder([])[0]).toBe("agent");
    expect(resolveStatusBarOrder([]).at(-1)).toBe("memory");
  });
  it("keeps the saved order, drops unknown and repeated ids, and appends the rest", () => {
    const order = resolveStatusBarOrder(["ci", "nope", "agent", "ci"]);
    expect(order.slice(0, 2)).toEqual(["ci", "agent"]);
    expect(new Set(order).size).toBe(order.length);
    expect(order).toHaveLength(12);
  });
});

describe("moveStatusBarItem", () => {
  it("swaps with a neighbour and stops at the ends", () => {
    expect(moveStatusBarItem([], "branch", -1).slice(3, 5)).toEqual(["branch", "directory"]);
    expect(moveStatusBarItem([], "agent", -1)[0]).toBe("agent");
    expect(moveStatusBarItem([], "memory", 1).at(-1)).toBe("memory");
  });
});

describe("visibility", () => {
  it("stores only what differs from the default", () => {
    expect(setStatusBarItemVisible({}, "ci", false)).toEqual({ ci: false });
    expect(setStatusBarItemVisible({ ci: false }, "ci", true)).toEqual({});
  });
  it("hides chips, keeping the order of the rest", () => {
    const ids = visibleStatusBarItems({ statusBarItems: { agent: false }, statusBarOrder: [] }).map(
      (item) => item.id,
    );
    expect(ids).not.toContain("agent");
    expect(ids[0]).toBe("remoteControl");
  });
  it("knows when the bar is as shipped", () => {
    expect(isDefaultStatusBar({ statusBarItems: {}, statusBarOrder: [] })).toBe(true);
    expect(isDefaultStatusBar({ statusBarItems: {}, statusBarOrder: ["ci"] })).toBe(false);
    expect(isDefaultStatusBar({ statusBarItems: { ci: false }, statusBarOrder: [] })).toBe(false);
  });
});
