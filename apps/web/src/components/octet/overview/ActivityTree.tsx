import { useAtomValue } from "@effect/atom-react";
import { scopedThreadKey } from "@t3tools/client-runtime/environment";
import type {
  OrchestrationV2PendingBackgroundTask,
  ScopedThreadRef,
  ThreadId,
} from "@t3tools/contracts";
import { ChevronRightIcon } from "lucide-react";
import { useState } from "react";

import { cn } from "~/lib/utils";
import { environmentThreadDetails } from "../../../state/threads";
import { OverviewAgentTree } from "./OverviewAgentTree";
import {
  agentsOnly,
  buildOverviewActivityTree,
  isLiveNode,
  type OverviewActivity,
  type OverviewNode,
} from "./overview.logic";

const EMPTY: readonly never[] = [];

export interface ActivityForest {
  /** Agents and tasks still working, with whatever they started. */
  readonly live: readonly OverviewNode<OverviewActivity>[];
  /** Agents that have finished, newest first. */
  readonly finished: readonly OverviewNode<OverviewActivity>[];
}

/** A thread's agents, scripts and monitors as a forest, split into live and finished. */
export function useActivityForest(
  threadRef: ScopedThreadRef,
  tasks: ReadonlyArray<OrchestrationV2PendingBackgroundTask>,
): ActivityForest {
  const atom = environmentThreadDetails.threadAtom(threadRef);
  const turnItems = useAtomValue(atom, (thread) => thread?.projection.turnItems ?? EMPTY);
  const runs = useAtomValue(atom, (thread) => thread?.projection.runs ?? EMPTY);
  // Tolerate a stubbed atom (tests): anything but a list reads as empty.
  const forest = buildOverviewActivityTree(
    Array.isArray(turnItems) ? turnItems : EMPTY,
    tasks,
    Array.isArray(runs) ? runs : EMPTY,
  );
  return { live: forest.filter(isLiveNode), finished: forest.filter((node) => !isLiveNode(node)) };
}

/** The live tree, then finished agents folded into one "Finished" row. */
export function ActivityTree(props: {
  readonly threadRef: ScopedThreadRef;
  readonly forest: ActivityForest;
  readonly onOpenThread: (threadId: ThreadId) => void;
  readonly density?: "default" | "compact";
  /** Open the Finished group when there is nothing live to show above it. */
  readonly expandFinishedWhenIdle?: boolean;
  /** Agents only; shells and monitors are shown elsewhere. */
  readonly agentsOnly?: boolean;
}) {
  const live = props.agentsOnly ? agentsOnly(props.forest.live) : props.forest.live;
  const finished = props.agentsOnly ? agentsOnly(props.forest.finished) : props.forest.finished;
  const [finishedOpen, setFinishedOpen] = useState<boolean | null>(null);
  const open = finishedOpen ?? (props.expandFinishedWhenIdle === true && live.length === 0);
  const compact = props.density === "compact";
  const tree = (nodes: readonly OverviewNode<OverviewActivity>[]) => (
    <OverviewAgentTree
      nodes={nodes}
      sourceRef={props.threadRef}
      rootRef={props.threadRef}
      ancestors={[scopedThreadKey(props.threadRef)]}
      onOpenThread={props.onOpenThread}
      density={props.density}
      agentsOnly={props.agentsOnly}
    />
  );
  return (
    <>
      {live.length > 0 ? tree(live) : null}
      {finished.length > 0 ? (
        <div data-overview-finished="" className={live.length > 0 ? "mt-1" : undefined}>
          <button
            type="button"
            aria-expanded={open}
            onClick={() => setFinishedOpen(!open)}
            className={cn(
              "flex w-full cursor-pointer items-center gap-1.5 rounded-md text-xs",
              open
                ? "bg-accent text-accent-foreground"
                : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
              compact ? "h-7 px-1.5" : "h-8 px-2",
            )}
          >
            <ChevronRightIcon
              aria-hidden
              className={cn("size-3 transition-transform", open && "rotate-90")}
            />
            Finished
            <span className="tabular-nums text-muted-foreground/70">{finished.length}</span>
          </button>
          {open ? tree(finished) : null}
        </div>
      ) : null}
    </>
  );
}
