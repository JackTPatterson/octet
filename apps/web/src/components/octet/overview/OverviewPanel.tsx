import type {
  OrchestrationV2PendingBackgroundTask,
  ScopedThreadRef,
  ThreadId,
} from "@t3tools/contracts";
import { BotIcon, ChevronRightIcon, CircleStopIcon } from "lucide-react";
import { useState } from "react";

import { cn } from "~/lib/utils";
import { PanelEmptyState } from "../../ui/empty";
import { Button } from "../../ui/button";
import { ActivityTree, useActivityForest } from "./ActivityTree";

type PendingTask = OrchestrationV2PendingBackgroundTask;

export function OverviewPanel(props: {
  readonly threadRef: ScopedThreadRef;
  readonly agentTitle: string;
  readonly agentStatus: string;
  readonly tasks: ReadonlyArray<PendingTask>;
  readonly stopDisabled: boolean;
  readonly stopping: boolean;
  readonly onStop: () => Promise<void>;
  readonly onOpenThread: (threadId: ThreadId) => void;
}) {
  const forest = useActivityForest(props.threadRef, props.tasks);
  const [subagentsOpen, setSubagentsOpen] = useState(true);
  const agentCount = forest.live.length + forest.finished.length;
  const working = forest.live.length > 0 || props.tasks.length > 0;

  if (agentCount === 0) {
    return (
      <div data-octet-overview-panel="" className="flex h-full min-h-0 flex-col overflow-y-auto">
        <PanelEmptyState
          icon={<BotIcon />}
          title="No activity yet"
          description="Agents, scripts, and monitors will appear here when they start."
        />
      </div>
    );
  }

  return (
    <div
      data-octet-overview-panel=""
      className="flex h-full min-h-0 flex-col overflow-y-auto px-3 py-2"
    >
      <div className="relative">
        <div className="flex h-12 min-w-0 items-center gap-2.5 px-2">
          <span
            aria-hidden="true"
            className="inline-flex size-6 shrink-0 items-center justify-center rounded-full border border-border/70 bg-muted"
          >
            <BotIcon className="size-3.5 text-muted-foreground" />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-xs font-semibold">{props.agentTitle}</span>
            <span className="block text-2xs text-muted-foreground">{props.agentStatus}</span>
          </span>
          {working ? (
            <Button
              size="xs"
              variant="ghost"
              disabled={props.stopDisabled}
              onClick={() => void props.onStop()}
            >
              <CircleStopIcon aria-hidden className="size-3" />
              {props.stopping ? "Stopping…" : "Stop all"}
            </Button>
          ) : null}
          {agentCount > 0 ? (
            <Button
              size="icon-micro"
              variant="ghost-muted"
              aria-label={`${subagentsOpen ? "Collapse" : "Expand"} agent tree`}
              aria-expanded={subagentsOpen}
              onClick={() => setSubagentsOpen((open) => !open)}
            >
              <ChevronRightIcon className={cn("size-3", subagentsOpen && "rotate-90")} />
            </Button>
          ) : null}
        </div>
        {subagentsOpen ? (
          <ActivityTree
            threadRef={props.threadRef}
            forest={forest}
            onOpenThread={props.onOpenThread}
          />
        ) : null}
      </div>
    </div>
  );
}
