import type { EnvironmentId, ThreadId, Wait } from "@t3tools/contracts";
import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { HourglassIcon, PencilIcon, XIcon } from "lucide-react";
import { useState } from "react";

import { cn } from "~/lib/utils";
import { serverEnvironment } from "../../../state/server";
import { useEnvironmentQuery } from "../../../state/query";
import { useAtomCommand } from "../../../state/use-atom-command";
import { Button } from "../../ui/button";
import { WaitDialog } from "./WaitDialog";
import {
  describeWaitCondition,
  visibleWaits,
  waitAction,
  waitStatusLabel,
} from "./waits.logic";

const EMPTY_WAITS: readonly Wait[] = [];

/** The waits on an environment that still want attention, ready ones first. */
export function useVisibleWaits(environmentId: EnvironmentId | null): readonly Wait[] {
  const query = useEnvironmentQuery(
    environmentId === null ? null : serverEnvironment.waitsLive({ environmentId, input: {} }),
  );
  const waits = query.data?.waits ?? EMPTY_WAITS;
  return visibleWaits(waits);
}


/**
 * Waits in the Waiting shelf, in T3's sidebar row styling: what it waits for,
 * the condition in words, and what you can do about it (carry on, say it
 * happened, or drop it). A row with an origin thread opens that thread.
 */
export function WaitRows(props: {
  readonly environmentId: EnvironmentId;
  readonly waits: readonly Wait[];
  readonly onOpenThread: (ref: ReturnType<typeof scopeThreadRef>) => void;
}) {
  const resolveWait = useAtomCommand(serverEnvironment.resolveWait, { label: "wait resolve" });
  const cancelWait = useAtomCommand(serverEnvironment.cancelWait, { label: "wait cancel" });
  const [editing, setEditing] = useState<Wait | null>(null);
  if (props.waits.length === 0) return null;
  return (
    <>
    <ul className="flex flex-col" data-octet-waits="">
      {props.waits.map((wait) => {
        const action = waitAction(wait);
        const threadId = wait.origin.threadId;
        const ready = wait.state === "ready";
        return (
          <li key={wait.id} data-octet-wait={wait.id} className="list-none py-0.5">
            <div
              role={threadId ? "button" : undefined}
              tabIndex={threadId ? 0 : undefined}
              onClick={() =>
                threadId && props.onOpenThread(scopeThreadRef(props.environmentId, threadId as ThreadId))
              }
              className={cn(
                "group/sidebar-row relative w-full overflow-hidden rounded-md text-left outline-none select-none",
                threadId && "cursor-pointer hover:bg-sidebar-row-hover",
                !ready && "text-sidebar-muted-foreground/90",
              )}
            >
              <div className="px-(--sidebar-row-content-inset) py-(--sidebar-content-inset)">
                <div className="flex min-w-0 items-center gap-1.5">
                  <HourglassIcon
                    aria-hidden
                    className={cn("size-3.5 shrink-0", ready ? "text-success" : "text-muted-foreground")}
                  />
                  <span className="min-w-0 flex-1 truncate font-medium text-foreground text-sm">
                    {wait.title}
                  </span>
                  <button
                    type="button"
                    aria-label={`Edit wait: ${wait.title}`}
                    title="Edit this wait"
                    onClick={(event) => {
                      event.stopPropagation();
                      setEditing(wait);
                    }}
                    className="hidden size-4 shrink-0 cursor-pointer items-center justify-center text-sidebar-muted-foreground hover:text-sidebar-foreground group-hover/sidebar-row:flex"
                  >
                    <PencilIcon className="size-3" aria-hidden />
                  </button>
                  <button
                    type="button"
                    aria-label={`Drop wait: ${wait.title}`}
                    title="Drop this wait"
                    onClick={(event) => {
                      event.stopPropagation();
                      void cancelWait({ environmentId: props.environmentId, input: { id: wait.id } });
                    }}
                    className="hidden size-4 shrink-0 cursor-pointer items-center justify-center text-sidebar-muted-foreground hover:text-sidebar-foreground group-hover/sidebar-row:flex"
                  >
                    <XIcon className="size-3.5" aria-hidden />
                  </button>
                </div>
                <div className="mt-0.5 flex min-w-0 items-center gap-1.5 text-secondary-label text-xs">
                  <span className="min-w-0 flex-1 truncate">{describeWaitCondition(wait.condition)}</span>
                  <span className={cn("shrink-0 font-medium", ready && "text-success-foreground")}>
                    {waitStatusLabel(wait)}
                  </span>
                </div>
                {action ? (
                  <div className="mt-1">
                    <Button
                      size="xs"
                      variant="outline"
                      onClick={(event) => {
                        event.stopPropagation();
                        void resolveWait({
                          environmentId: props.environmentId,
                          input: { id: wait.id, action: action === "continue" ? "continue" : "ready" },
                        });
                      }}
                    >
                      {action === "continue" ? "Continue" : "It happened"}
                    </Button>
                  </div>
                ) : null}
              </div>
            </div>
          </li>
        );
      })}
    </ul>
    {editing ? (
      <WaitDialog
        key={editing.id}
        open
        onOpenChange={(open) => !open && setEditing(null)}
        environmentId={props.environmentId}
        wait={editing}
      />
    ) : null}
    </>
  );
}
