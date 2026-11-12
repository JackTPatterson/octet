import { useProjectTodoFile } from "./useProjectTodoFile";
import { AuthFilesystemWriteScope, type ScopedThreadRef } from "@t3tools/contracts";
import { useState, type KeyboardEvent } from "react";

import { cn } from "~/lib/utils";
import { projectEnvironment } from "../../../state/projects";
import { useEnvironmentScope } from "../../../state/session";
import { useAtomCommand } from "../../../state/use-atom-command";
import { Checkbox } from "../../ui/checkbox";
import { CollapsibleSectionHeader } from "../../ui/collapsible-section-header";
import { Input } from "../../ui/input";
import {
  addingTodo,
  parseProjectTodos,
  settingTodoStatus,
  type ProjectTodoItem,
} from "./projectTodos.logic";

export function TodosPanel(props: {
  readonly threadRef: ScopedThreadRef;
  readonly projectRoot: string | null;
  readonly variant?: "panel" | "card";
}) {
  const { environmentId } = props.threadRef;
  const card = props.variant === "card";
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
        ? settingTodoStatus(
            fresh.status === "completed" ? "pending" : "completed",
            fresh.line,
            file.contents,
          )
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
    <div
      data-octet-todos-panel=""
      className={cn(
        "flex min-h-0 flex-col px-3 py-2",
        card ? "dropdown-glass overflow-hidden rounded-2xl" : "h-full overflow-y-auto",
      )}
    >
      <section data-todos-section="project">
        <CollapsibleSectionHeader
          variant="panel"
          expanded={projectOpen}
          onClick={() => setProjectOpen((value) => !value)}
          accessory={
            <span className="text-muted-foreground tabular-nums">
              {card ? `${open.length} open` : `${file.fileName} · ${open.length}`}
            </span>
          }
        >
          {card ? "TODO" : "Project"}
        </CollapsibleSectionHeader>
        {projectOpen ? (
          <div className="mt-1">
            {props.projectRoot === null ? (
              <p className="px-2 py-1 text-muted-foreground text-xs">
                Open a project to keep a TODO list for it.
              </p>
            ) : list.items.length === 0 && file.loaded ? (
              <p className="px-2 py-1 text-muted-foreground text-xs">
                No items in {file.fileName} yet. Add one below
                {canWrite ? "" : " (needs write access)"}.
              </p>
            ) : null}
            {open.length > 0 ? (
              <ul className={card ? "py-1" : "rounded-lg border border-border/60 bg-card/30 p-1"}>
                {open.map(row)}
              </ul>
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
                  accessory={
                    <span className="text-muted-foreground tabular-nums">{done.length}</span>
                  }
                >
                  Done
                </CollapsibleSectionHeader>
                {doneOpen ? (
                  <ul
                    className={
                      card ? "mt-1" : "mt-1 rounded-lg border border-border/60 bg-card/30 p-1"
                    }
                  >
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
