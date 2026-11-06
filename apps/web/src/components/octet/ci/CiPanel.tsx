import { selectEnvironmentQueryData } from "@t3tools/client-runtime/state/runtime";
import type {
  EnvironmentId,
  PullRequestRef,
  ScopedThreadRef,
  ThreadLinkedPullRequest,
} from "@t3tools/contracts";

import { cn } from "~/lib/utils";
import { pullRequestEnvironment } from "../../../state/pullRequests";
import { useEnvironmentQuerySelector } from "../../../state/query";
import { ChecksBody } from "../../pullRequest/PullRequestChecksPopover";
import {
  pullRequestChecksState,
  pullRequestChecksStatePresentation,
  summarizePullRequestChecks,
} from "../../pullRequest/pullRequestPresentation";

/**
 * Octet's CI plane: the branch's pull request checks, failures first. Drawn
 * with T3's checks list and presentation, so it reads like the rest of the
 * panel.
 */
export function CiPanel(props: {
  environmentId: EnvironmentId;
  threadRef: ScopedThreadRef;
  /** The thread's linked pull request, else the one on its branch. */
  pullRequest: ThreadLinkedPullRequest | null | undefined;
}) {
  const { pullRequest } = props;
  const reference: PullRequestRef | null = pullRequest
    ? {
        projectId: pullRequest.projectId,
        repository: pullRequest.repository,
        number: pullRequest.number,
      }
    : null;
  const checksAtom =
    reference === null
      ? null
      : pullRequestEnvironment.checks({ environmentId: props.environmentId, input: reference });
  const checks = useEnvironmentQuerySelector(checksAtom, selectEnvironmentQueryData)?.checks ?? null;
  const state = checks ? pullRequestChecksState(checks) : null;
  const presentation = state ? pullRequestChecksStatePresentation(state) : null;

  return (
    <div data-octet-ci-panel="" className="flex h-full min-h-0 flex-col gap-3 overflow-y-auto p-3">
      {pullRequest === null || pullRequest === undefined ? (
        <p className="text-muted-foreground text-sm">
          This branch has no pull request yet, so there is no CI to show. Push it and open one.
        </p>
      ) : checks === null ? (
        <p className="text-muted-foreground text-sm">Loading checks for #{pullRequest.number}…</p>
      ) : (
        <>
          <div className="flex items-center gap-2">
            {presentation ? (
              <presentation.Icon
                aria-hidden
                className={cn("size-4 shrink-0", presentation.toneClassName)}
              />
            ) : null}
            <span className="font-medium text-sm">{presentation?.label ?? "No checks reported"}</span>
            <span className="text-muted-foreground text-xs">#{pullRequest.number}</span>
          </div>
          {checks.length > 0 ? (
            <p className="text-muted-foreground text-xs">{summarizePullRequestChecks(checks)}</p>
          ) : null}
          <ChecksBody checks={checks} threadRef={props.threadRef} />
        </>
      )}
    </div>
  );
}
