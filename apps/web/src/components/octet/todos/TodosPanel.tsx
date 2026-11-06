import { AuthFilesystemWriteScope, type EnvironmentId, type ScopedThreadRef } from "@t3tools/contracts";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";

import { cn } from "~/lib/utils";
import { projectEnvironment } from "../../../state/projects";
import { useEnvironmentQuery } from "../../../state/query";
import { useEnvironmentScope } from "../../../state/session";
import { useAtomCommand } from "../../../state/use-atom-command";
import { Checkbox } from "../../ui/checkbox";
import { CollapsibleSectionHeader } from "../../ui/collapsible-section-header";
import { Input } from "../../ui/input";
import {
  PROJECT_TODO_FILE_NAMES,
  addingTodo,
  parseProjectTodos,
  settingTodoStatus,
  type ProjectTodoItem,
} from "./projectTodos.logic";

const REFRESH_MS = 2_500;

function useTodoFileRead(environmentId: EnvironmentId, cwd: string | null, relativePath: string) {
  return useEnvironmentQuery(
    cwd === null
      ? null
      : projectEnvironment.readFile({
          environmentId,
          input: { cwd, relativePath, allowMissing: true },
        }),
  );
}

/** The project's list: the first of the usual names that exists, else where a new one would go. */
function useProjectTodoFile(environmentId: EnvironmentId, cwd: string | null) {
  const queries = [
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[0]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[1]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[2]),
    useTodoFileRead(environmentId, cwd, PROJECT_TODO_FILE_NAMES[3]),
  ];
  const index = queries.findIndex((query) => query.data && query.data.exists !== false);
  const found = index >= 0 ? queries[index]! : null;
  const refreshAll = useRef(() => {});
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- polls the file while the panel is mounted, as agents and editors tick items elsewhere
  useEffect(() => {
    refreshAll.current = () => queries.forEach((query) => query.refresh());
  });
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- polls the file while the panel is mounted, as agents and editors tick items elsewhere
  useEffect(() => {
    if (cwd === null) return;
    const timer = setInterval(() => refreshAll.current(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [cwd]);
  return {
    fileName: index >= 0 ? PROJECT_TODO_FILE_NAMES[index]! : PROJECT_TODO_FILE_NAMES[0],
    contents: found?.data?.contents ?? "",
    loaded: queries.every((query) => !query.isPending) || found !== null,
    refresh: () => refreshAll.current(),
  };
}

/**
 * Octet's TODO plane: the project's own list (`TODO.md`) you can tick and
 * add to. Rows, checkboxes, the input and the
 * section headers are T3's own.
 */
export function TodosPanel(props: {
  readonly threadRef: ScopedThreadRef;
  /** The project's root, where `TODO.md` lives. */
  readonly projectRoot: string | null;
}) {
  const { environmentId } = props.threadRef;
  const canWrite = useEnvironmentScope(environmentId, AuthFilesystemWriteScope);
  const writeFile = useAtomCommand(projectEnvironment.writeFile, { reportFailure: false });
  const file = useProjectTodoFile(environmentId, props.projectRoot);
  const [projectOpen, setProjectOpen] = useState(true);
  const [doneOpen, setDoneOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const list = parseProjectTodos(file.contents);
  const open = list.items.filter((item) => item.status !== "completed");
  const done = list.items.filter((item) => item.status === "completed");

  const save = async (next: string | null): Promise<void> => {
    if (next === null || props.projectRoot === null) {
      setError("That item changed on disk. Refreshing.");
      file.refresh();
      return;
    }
    setSaving(true);
    setError(null);
    const result = await writeFile({
      environmentId,
      input: { cwd: props.projectRoot, relativePath: file.fileName, contents: next },
    });
    setSaving(false);
    if (result._tag === "Failure") setError(`Couldn't save ${file.fileName}.`);
    file.refresh();
  };

  const toggle = (item: ProjectTodoItem) => {
    // Find it again by who it is, since the file may have changed since this row drew.
    const fresh = parseProjectTodos(file.contents).items.find((entry) => entry.id === item.id);
    void save(
      fresh
        ? settingTodoStatus(fresh.status === "completed" ? "pending" : "completed", fresh.line, file.contents)
        : null,
    );
  };

  const add = () => {
    const text = draft.trim();
    if (text.length === 0) return;
    setDraft("");
    void save(addingTodo(text, file.contents));
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      add();
    }
  };

  const row = (item: ProjectTodoItem) => (
    <li key={item.id}>
      <label
        className={cn(
          "flex min-h-8 min-w-0 items-start gap-2.5 rounded-md px-2 py-1.5 text-xs transition-colors",
          canWrite && "cursor-pointer hover:bg-accent/50",
        )}
      >
        <Checkbox
          className="mt-px"
          checked={item.status === "completed"}
          indeterminate={item.status === "in-progress"}
          disabled={!canWrite || saving}
          onCheckedChange={() => toggle(item)}
        />
        <span
          className={cn(
            "min-w-0 flex-1 break-words",
            item.status === "completed" ? "text-muted-foreground line-through" : "text-foreground",
          )}
        >
          {item.text}
        </span>
        {item.section ? (
          <span className="shrink-0 text-3xs text-muted-foreground">{item.section}</span>
        ) : null}
      </label>
    </li>
  );

  return (
    <div data-octet-todos-panel="" className="flex h-full min-h-0 flex-col overflow-y-auto px-3 py-2">
      <section data-todos-section="project">
        <CollapsibleSectionHeader
          variant="panel"
          expanded={projectOpen}
          onClick={() => setProjectOpen((value) => !value)}
          accessory={
            <span className="text-muted-foreground tabular-nums">
              {file.fileName} · {open.length}
            </span>
          }
        >
          Project
        </CollapsibleSectionHeader>
        {projectOpen ? (
          <div className="mt-1">
            {props.projectRoot === null ? (
              <p className="px-2 py-1 text-muted-foreground text-xs">
                Open a project to keep a TODO list for it.
              </p>
            ) : list.items.length === 0 && file.loaded ? (
              <p className="px-2 py-1 text-muted-foreground text-xs">
                No items in {file.fileName} yet. Add one below{canWrite ? "" : " (needs write access)"}.
              </p>
            ) : null}
            {open.length > 0 ? (
              <ul className="rounded-lg border border-border/60 bg-card/30 p-1">{open.map(row)}</ul>
            ) : null}
            {canWrite && props.projectRoot !== null ? (
              <div className="mt-2">
                <Input
                  size="compact"
                  value={draft}
                  disabled={saving}
                  placeholder="Add an item…"
                  aria-label="Add a TODO item"
                  onChange={(event) => setDraft(event.target.value)}
                  onKeyDown={onKeyDown}
                />
              </div>
            ) : null}
            {error ? <p className="px-2 pt-1 text-destructive text-xs">{error}</p> : null}
            {done.length > 0 ? (
              <div className="mt-2">
                <CollapsibleSectionHeader
                  variant="panel"
                  expanded={doneOpen}
                  onClick={() => setDoneOpen((value) => !value)}
                  accessory={<span className="text-muted-foreground tabular-nums">{done.length}</span>}
                >
                  Done
                </CollapsibleSectionHeader>
                {doneOpen ? (
                  <ul className="mt-1 rounded-lg border border-border/60 bg-card/30 p-1">
                    {done.map(row)}
                  </ul>
                ) : null}
              </div>
            ) : null}
          </div>
        ) : null}
      </section>
    </div>
  );
}
