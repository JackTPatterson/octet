import type { ThreadStructure } from "@t3tools/client-runtime/state/shell";
import { DateTime } from "effect";
import { CheckIcon, CircleIcon, CircleDotIcon } from "lucide-react";
import { useState } from "react";
import { cn } from "../../lib/utils";
import { CollapsibleSectionHeader } from "../ui/collapsible-section-header";

export function latestThreadTasks(items: ThreadStructure["turnItems"]) {
  let latest: Extract<ThreadStructure["turnItems"][number], { type: "todo_list" }> | null = null;
  for (const item of items) {
    if (
      item.type === "todo_list" &&
      (latest === null ||
        DateTime.toEpochMillis(item.updatedAt) >= DateTime.toEpochMillis(latest.updatedAt))
    )
      latest = item;
  }
  return latest;
}

export function ThreadTasksCard({
  projection,
}: {
  projection: Pick<ThreadStructure, "turnItems"> | null;
}) {
  const [expanded, setExpanded] = useState(true);
  const tasks = latestThreadTasks(projection?.turnItems ?? []);
  const steps = tasks?.steps ?? [];
  if (steps.length === 0) return null;
  const completed = steps.filter((step) => step.status === "completed").length;

  return (
    <section
      data-thread-tasks-card
      className="dropdown-glass overflow-hidden rounded-2xl px-3 py-2"
    >
      <CollapsibleSectionHeader
        variant="panel"
        expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
        accessory={
          <span className="text-muted-foreground tabular-nums">
            {completed}/{steps.length}
          </span>
        }
      >
        Tasks
      </CollapsibleSectionHeader>
      {expanded ? (
        <ul className="py-1" aria-label="Thread tasks">
          {steps.map((step) => {
            const Icon =
              step.status === "completed"
                ? CheckIcon
                : step.status === "running"
                  ? CircleDotIcon
                  : CircleIcon;
            return (
              <li key={step.id} className="flex min-w-0 items-start gap-2.5 px-2 py-1.5 text-xs">
                <Icon
                  aria-hidden
                  className={cn(
                    "mt-0.5 size-3.5 shrink-0",
                    step.status === "running" ? "text-primary" : "text-muted-foreground",
                  )}
                />
                <span className="sr-only">
                  {step.status === "running"
                    ? "In progress"
                    : step.status === "completed"
                      ? "Completed"
                      : "Pending"}
                  :{" "}
                </span>
                <span
                  className={cn(
                    "min-w-0 break-words",
                    step.status === "completed"
                      ? "text-muted-foreground line-through"
                      : "text-foreground",
                  )}
                >
                  {step.text}
                </span>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
