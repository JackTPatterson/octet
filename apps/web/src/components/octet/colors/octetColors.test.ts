import { describe, expect, it } from "vite-plus/test";

import {
  buildColorMenuItem,
  cardColorKey,
  parseColorMenuId,
  parseStoredColors,
  resolveTabColor,
} from "./octetColors";

describe("octet colours", () => {
  it("reads stored colours and drops unknown ones", () => {
    expect(parseStoredColors(null)).toEqual({ cards: {}, tabs: {} });
    expect(parseStoredColors("not json")).toEqual({ cards: {}, tabs: {} });
    expect(
      parseStoredColors(JSON.stringify({ cards: { a: "red", b: "mauve" }, tabs: { c: "blue" } })),
    ).toEqual({ cards: { a: "red" }, tabs: { c: "blue" } });
  });
  it("shows a tab's own colour, else its card's", () => {
    const stored = { cards: { card: "green" as const }, tabs: { mine: "pink" as const } };
    expect(resolveTabColor(stored, "mine", "card")).toBe("pink");
    expect(resolveTabColor(stored, "other", "card")).toBe("green");
    expect(resolveTabColor(stored, "other", "nope")).toBeNull();
  });
  it("keys a card by project and branch or worktree", () => {
    const base = { environmentId: "e", projectId: "p", branch: "main", worktreePath: null };
    expect(cardColorKey(base)).toBe("e:p:branch:main");
    expect(cardColorKey({ ...base, worktreePath: "/w" })).toBe("e:p:worktree:/w");
  });
  it("builds the menu and reads a choice back", () => {
    const item = buildColorMenuItem("teal");
    expect(item.children).toHaveLength(9);
    expect(item.children?.find((child) => child.checked)?.id).toBe("color:teal");
    expect(parseColorMenuId("color:teal")).toBe("teal");
    expect(parseColorMenuId("color:none")).toBeNull();
    expect(parseColorMenuId("settle")).toBeUndefined();
    expect(parseColorMenuId("color:mauve")).toBeUndefined();
  });
});
