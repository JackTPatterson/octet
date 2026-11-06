/**
 * A project's own todo list: the markdown checkboxes in `TODO.md` at its
 * root, ported from native Octet's `ProjectTodos`. A file rather than a
 * server, so every agent can read and tick it with no setup, it's versioned
 * with the code, and any editor can change it. Edits touch only the line
 * they're about, so the rest of the file (prose, headings, an item's wrapped
 * lines) stays as written.
 */

export type TodoStatus = "pending" | "in-progress" | "completed";

export interface ProjectTodoItem {
  /** The item's line in the file, 0-based: where writes go, checked against the text first. */
  readonly line: number;
  /** The first line's text, with markdown emphasis taken off. */
  readonly text: string;
  readonly status: TodoStatus;
  /** The `#` heading it sits under, if any. */
  readonly section: string | null;
  /** Which of the items with this heading and text it is, from the top. */
  readonly occurrence: number;
  /**
   * Who it is from its content, not its line, so an edit above it doesn't
   * make it a different row. Ticking it keeps it; rewording it makes it new.
   */
  readonly id: string;
}

export interface ProjectTodoList {
  readonly items: readonly ProjectTodoItem[];
}

/** Names looked for at the project root, in order. */
export const PROJECT_TODO_FILE_NAMES = ["TODO.md", "todo.md", "Todo.md", "TODO.markdown"] as const;

// `- [ ] text`, `* [x] text`, `1. [~] text`, indented or not.
const ITEM = /^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX~/-])(\]\s+)(.*)$/u;
const HEADING = /^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/u;

export function todoIdentity(section: string | null, text: string, occurrence: number): string {
  return `${section ?? ""}\u001f${text}\u001f${occurrence}`;
}

function statusOf(mark: string): TodoStatus {
  if (mark === "x" || mark === "X") return "completed";
  if (mark === "~" || mark === "/" || mark === "-") return "in-progress";
  return "pending";
}

/** Emphasis and code marks off, so `**Fix the thing** (high)` reads plainly. */
function clean(text: string): string {
  return text.replaceAll("**", "").replaceAll("__", "").replaceAll("`", "").trim();
}

function linesOf(contents: string): string[] {
  const all = contents.split("\n");
  if (contents.endsWith("\n")) all.pop();
  return all.map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line));
}

function join(lines: readonly string[], like: string): string {
  const newline = like.includes("\r\n") ? "\r\n" : "\n";
  const body = lines.join(newline);
  return like.endsWith("\n") || like === "" ? body + newline : body;
}

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

/** The first line index after the item on `line` and the lines wrapped under it. */
function endOfItem(all: readonly string[], line: number): number {
  let end = line + 1;
  while (end < all.length) {
    const next = all[end]!;
    if (isBlank(next) || !/^\s/u.test(next) || ITEM.test(next)) break;
    end += 1;
  }
  return end;
}

export function parseProjectTodos(contents: string): ProjectTodoList {
  const items: ProjectTodoItem[] = [];
  let section: string | null = null;
  linesOf(contents).forEach((line, index) => {
    const heading = HEADING.exec(line);
    if (heading) {
      section = clean(heading[1]!);
      return;
    }
    const parts = ITEM.exec(line);
    if (!parts) return;
    const text = clean(parts[4]!);
    if (text.length === 0) return;
    const occurrence = items.filter((item) => item.section === section && item.text === text).length;
    items.push({
      line: index,
      text,
      status: statusOf(parts[2]!),
      section,
      occurrence,
      id: todoIdentity(section, text, occurrence),
    });
  });
  return { items };
}

/**
 * The file with the item on `line` marked `status`; null when that line isn't
 * an item any more (the file changed underneath).
 */
export function settingTodoStatus(
  status: TodoStatus,
  line: number,
  contents: string,
): string | null {
  const all = linesOf(contents);
  const parts = line >= 0 && line < all.length ? ITEM.exec(all[line]!) : null;
  if (!parts) return null;
  const mark = status === "completed" ? "x" : status === "in-progress" ? "~" : " ";
  all[line] = `${parts[1]}${mark}${parts[3]}${parts[4]}`;
  return join(all, contents);
}

/**
 * The file with a new open item: after the last item when there is one, so it
 * lands in the list, else at the end under a `# TODO` heading.
 */
export function addingTodo(text: string, contents: string): string {
  const clean1 = text.trim().replaceAll("\n", " ");
  if (clean1.length === 0) return contents;
  const all = contents === "" ? [] : linesOf(contents);
  let last = -1;
  all.forEach((line, index) => {
    if (ITEM.test(line)) last = index;
  });
  if (last >= 0) {
    all.splice(endOfItem(all, last), 0, `- [ ] ${clean1}`);
  } else {
    while (all.length > 0 && isBlank(all[all.length - 1]!)) all.pop();
    if (all.length === 0) all.push("# TODO", "");
    else all.push("");
    all.push(`- [ ] ${clean1}`);
  }
  const result = join(all, contents);
  return result.endsWith("\n") ? result : `${result}\n`;
}

/** What an agent is told when an item is handed to it. */
export function todoPrompt(item: Pick<ProjectTodoItem, "text">, fileName: string): string {
  return `Work on this item from ${fileName}: ${item.text}\n\nWhen it's done, tick it off in ${fileName} by changing its "- [ ]" to "- [x]".`;
}
