import type { SidebarThreadSummary } from "../../../types";
import { resolveSidebarThreadStatus } from "../../Sidebar.logic";
import { cn } from "~/lib/utils";
import { STATUS_LABEL } from "./cardStatus";
import { peekRows, type BranchCard } from "./octetSidebar.logic";

/**
 * The hover peek: what is on a card without opening it. Every thread on the
 * branch with its state, and where the branch lives. Drawn in T3's preview
 * card, with the sidebar's own row type.
 */
export function CardPeek(props: {
  card: BranchCard<SidebarThreadSummary>;
  onOpen: (thread: SidebarThreadSummary) => void;
}) {
  const { card } = props;
  const byId = new Map<string, SidebarThreadSummary>(card.threads.map((thread) => [thread.id, thread]));
  const rows = peekRows(card, resolveSidebarThreadStatus);
  return (
    <div data-testid="octet-card-peek" className="flex w-72 flex-col gap-1 p-2 text-xs">
      <div className="truncate px-1 font-medium text-foreground">
        {card.branch ?? "No branch"}
      </div>
      {card.worktreePath ? (
        <div className="truncate px-1 text-secondary-label" title={card.worktreePath}>
          {card.worktreePath}
        </div>
      ) : null}
      <ul className="mt-1 flex flex-col">
        {rows.map((row) => {
          const status = STATUS_LABEL[row.status];
          return (
            <li key={row.id}>
              <button
                type="button"
                onClick={() => {
                  const thread = byId.get(row.id);
                  if (thread) props.onOpen(thread);
                }}
                className="flex w-full min-w-0 cursor-pointer items-center gap-2 rounded-md px-1 py-1 text-left hover:bg-accent"
              >
                <span className="min-w-0 flex-1 truncate text-sm text-foreground">{row.title}</span>
                {status ? (
                  <span className={cn("shrink-0 font-medium", status.className)}>{status.label}</span>
                ) : null}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
