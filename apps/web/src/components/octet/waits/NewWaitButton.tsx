import type { WaitOrigin } from "@t3tools/contracts";
import { PlusIcon } from "lucide-react";
import { useState } from "react";

import { useActiveProjectTarget } from "../../../hooks/useActiveProjectTarget";
import { readThreadShell } from "../../../state/entities";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../../ui/tooltip";
import { WaitDialog } from "./WaitDialog";

/**
 * A plus that opens the dialog for a new wait set from the thread in view.
 * For the Waiting shelf's header; renders nothing with no thread open.
 */
export function NewWaitButton(props: { readonly className?: string }) {
  const target = useActiveProjectTarget();
  const [open, setOpen] = useState(false);
  if (target === null) return null;
  const projectId = readThreadShell(target.threadRef)?.projectId;
  const origin: WaitOrigin = {
    cwd: target.cwd,
    threadId: target.threadRef.threadId,
    ...(projectId === undefined ? {} : { projectId }),
  };
  return (
    <>
      <Tooltip>
        <TooltipTrigger
          render={
            <button
              type="button"
              aria-label="Wait for something"
              onClick={() => setOpen(true)}
              className={
                props.className ??
                "flex size-5 shrink-0 cursor-pointer items-center justify-center rounded-md text-sidebar-muted-foreground hover:text-sidebar-foreground"
              }
            />
          }
        >
          <PlusIcon aria-hidden className="size-3.5" />
        </TooltipTrigger>
        <TooltipPopup>Wait for something…</TooltipPopup>
      </Tooltip>
      {open ? (
        <WaitDialog open onOpenChange={setOpen} environmentId={target.environmentId} origin={origin} />
      ) : null}
    </>
  );
}
