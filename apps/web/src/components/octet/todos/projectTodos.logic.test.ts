import { describe, expect, it } from "vite-plus/test";

import {
  addingTodo,
  parseProjectTodos,
  settingTodoStatus,
  todoPrompt,
} from "./projectTodos.logic";

const FILE = `# TODO

Some prose that stays.

## Sidebar
- [ ] **Port** the \`sidebar\`
- [x] Rebrand
  wrapped under rebrand
* [~] Status bar
1. [ ] Numbered item

## Later
- [ ] Rebrand
- [ ] Rebrand
`;

describe("parseProjectTodos", () => {
  const { items } = parseProjectTodos(FILE);

  it("reads checkboxes of every bullet style with their marks and headings", () => {
    expect(items.map((item) => [item.text, item.status, item.section])).toEqual([
      ["Port the sidebar", "pending", "Sidebar"],
      ["Rebrand", "completed", "Sidebar"],
      ["Status bar", "in-progress", "Sidebar"],
      ["Numbered item", "pending", "Sidebar"],
      ["Rebrand", "pending", "Later"],
      ["Rebrand", "pending", "Later"],
    ]);
  });

  it("numbers repeated items under one heading, so each keeps its own identity", () => {
    const later = items.filter((item) => item.section === "Later");
    expect(later.map((item) => item.occurrence)).toEqual([0, 1]);
    expect(new Set(items.map((item) => item.id)).size).toBe(items.length);
  });

  it("keeps an item's identity when a line is added above it", () => {
    const before = parseProjectTodos("- [ ] Ship it\n").items[0]!;
    const after = parseProjectTodos("Notes\n\n- [ ] Ship it\n").items[0]!;
    expect(after.line).not.toBe(before.line);
    expect(after.id).toBe(before.id);
  });

  it("ignores empty items and plain bullets", () => {
    expect(parseProjectTodos("- [ ]   \n- not a checkbox\n").items).toEqual([]);
  });
});

describe("settingTodoStatus", () => {
  it("changes only the one line's mark", () => {
    const next = settingTodoStatus("completed", 5, FILE)!;
    expect(next.split("\n")[5]).toBe("- [x] **Port** the `sidebar`");
    expect(next.split("\n").filter((_, index) => index !== 5)).toEqual(
      FILE.split("\n").filter((_, index) => index !== 5),
    );
  });

  it("marks in progress and back to pending", () => {
    expect(settingTodoStatus("in-progress", 5, FILE)!.split("\n")[5]).toBe("- [~] **Port** the `sidebar`");
    expect(settingTodoStatus("pending", 6, FILE)!.split("\n")[6]).toBe("- [ ] Rebrand");
  });

  it("refuses a line that is no longer an item", () => {
    expect(settingTodoStatus("completed", 2, FILE)).toBeNull();
    expect(settingTodoStatus("completed", 99, FILE)).toBeNull();
  });

  it("keeps CRLF line endings", () => {
    const next = settingTodoStatus("completed", 0, "- [ ] a\r\n- [ ] b\r\n")!;
    expect(next).toBe("- [x] a\r\n- [ ] b\r\n");
  });
});

describe("addingTodo", () => {
  it("lands after the last item and its wrapped lines", () => {
    const next = addingTodo("New thing", "- [ ] a\n  wrapped\n\nnotes\n");
    expect(next).toBe("- [ ] a\n  wrapped\n- [ ] New thing\n\nnotes\n");
  });

  it("starts a TODO heading in a file with no items", () => {
    expect(addingTodo("First", "")).toBe("# TODO\n\n- [ ] First\n");
    expect(addingTodo("First", "Just notes\n")).toBe("Just notes\n\n- [ ] First\n");
  });

  it("ignores blank text", () => {
    expect(addingTodo("  \n ", "- [ ] a\n")).toBe("- [ ] a\n");
  });
});

describe("todoPrompt", () => {
  it("tells the agent where to tick the item off", () => {
    expect(todoPrompt({ text: "Fix tests" }, "TODO.md")).toContain('"- [x]"');
  });
});
