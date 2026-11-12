import { scopeProjectRef, scopeThreadRef } from "@t3tools/client-runtime/environment";
import type { ScopedThreadRef } from "@t3tools/contracts";
import { useRouter } from "@tanstack/react-router";
import { BotIcon, PlusIcon, SquarePenIcon } from "lucide-react";
import { useEffect, useRef, type CSSProperties, type KeyboardEvent, type MouseEvent } from "react";

import { cn } from "~/lib/utils";
import { readLocalApi } from "../../../localApi";
import {
  buildColorMenuItem,
  cardColorKey,
  colorHex,
  parseColorMenuId,
  setTabColor,
  tabColorKey,
  useOctetColors,
} from "../colors/octetColors";
import { useHandleNewThread } from "../../../hooks/useHandleNewThread";
import { useThreadActions } from "../../../hooks/useThreadActions";
import { useQuietThreadShells } from "../../../state/entities";
import { buildThreadRouteParams } from "../../../threadRoutes";
import { useSidebarLookups } from "../../Sidebar";
import { resolveSidebarThreadStatus, type SidebarThreadStatus } from "../../Sidebar.logic";
import { SidebarProviderStack } from "../../sidebar/SidebarThreadRow";
import { PanelTabCloseButton } from "../../ui/panel-tab-close-button";
import { adjacentTab, agentTabsFor, isSubagentThread, tabAfterClosing } from "./agentTabs.logic";

/** The dot on a tab, by what the agent needs. A quiet agent has none. */
const STATUS_DOT: Partial<Record<SidebarThreadStatus, string>> = {
  working: "bg-info animate-pulse",
  waiting: "bg-muted-foreground/50",
  approval: "bg-amber-500",
  limited: "bg-amber-500",
  input: "bg-indigo-500",
  request: "bg-guest",
  failed: "bg-destructive",
};

/**
 * Octet's agent tabs: the agents on the thread's branch or worktree, along
 * the top of the thread, with a plus for another one there. Drawn with T3's
 * own tab classes (the terminal drawer's) and the sidebar's provider icons.
 *
 * A tab's provider icon is its close button: hovering the tab shows an X in its
 * place, and middle-click closes too. Closing settles the thread, with T3's Undo,
 * and moves to the neighbouring tab. The only tab has nothing to move to, so it
 * keeps its icon. The arrow keys move between tabs.
 */
export function AgentTabBar(props: {
  threadRef: ScopedThreadRef;
  /** Set while the thread in view is an unsent draft: it has no shell yet, so it is shown as a tab of its own. */
  draft?: { projectId: string; branch: string | null; worktreePath: string | null };
}) {
  const { threadRef, draft } = props;
  const shells = useQuietThreadShells();
  const { providerEntriesByEnvironment } = useSidebarLookups();
  const { handleNewThread } = useHandleNewThread();
  const { settleThread } = useThreadActions();
  const router = useRouter();
  const listRef = useRef<HTMLDivElement>(null);
  const activeId = threadRef.threadId;
  const colors = useOctetColors();
  const savedTabs = agentTabsFor(shells, {
    environmentId: threadRef.environmentId,
    id: threadRef.threadId,
  });
  // A draft joins its branch's tabs, last, until its first message makes it a thread.
  const tabs =
    savedTabs ??
    (draft
      ? [
          ...(agentTabsFor(
            [
              ...shells,
              {
                id: activeId,
                environmentId: threadRef.environmentId,
                projectId: draft.projectId,
                branch: draft.branch,
                worktreePath: draft.worktreePath,
                // Newest, so it sorts last.
                createdAt: Date.now(),
              } as (typeof shells)[number],
            ],
            { environmentId: threadRef.environmentId, id: activeId },
          ) ?? []),
        ]
      : null);
  // Keep the open tab in view when there are more than fit.
  useEffect(() => {
    listRef.current
      ?.querySelector<HTMLElement>('[aria-selected="true"]')
      ?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [activeId, tabs?.length]);
  if (!tabs) return null;
  const providerEntries = providerEntriesByEnvironment.get(threadRef.environmentId);
  const here = tabs.find((tab) => tab.id === activeId);

  const open = (shell: (typeof tabs)[number]) => {
    void router.navigate({
      to: "/$environmentId/$threadId",
      params: buildThreadRouteParams(scopeThreadRef(shell.environmentId, shell.id)),
    });
  };
  // T3 keeps one empty draft per project: the plus would reopen the one in view.
  const onEmptyDraft = !shells.some((saved) => saved.id === activeId);
  const addAgent = () => {
    if (!here || onEmptyDraft) return;
    void handleNewThread(scopeProjectRef(here.environmentId, here.projectId), {
      branch: here.branch,
      worktreePath: here.worktreePath,
      envMode: here.worktreePath ? "worktree" : "local",
      startFromOrigin: false,
    });
  };
  const closable = tabs.length > 1;
  const close = (shell: (typeof tabs)[number]) => {
    if (!closable) return;
    // Leave first, so the thread in view is never the one being settled away.
    const next = shell.id === activeId ? tabAfterClosing(tabs, shell.id) : null;
    if (next) open(next);
    // An unsent draft has no thread to settle.
    if (!shells.some((saved) => saved.id === shell.id)) return;
    void settleThread(scopeThreadRef(shell.environmentId, shell.id));
  };
  const onTabKeyDown = (event: KeyboardEvent<HTMLElement>, shell: (typeof tabs)[number]) => {
    const delta = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (delta === 0) return;
    event.preventDefault();
    const next = adjacentTab(tabs, shell.id, delta);
    if (!next) return;
    open(next);
    // The new tab is the same element once the route changes; focus follows it.
    requestAnimationFrame(() =>
      listRef.current
        ?.querySelector<HTMLElement>(`[data-tab-id="${CSS.escape(next.id)}"] [role="tab"]`)
        ?.focus(),
    );
  };

  return (
    <div
      ref={listRef}
      role="tablist"
      aria-label="Agents"
      data-octet-agent-tabs=""
      className="flex h-8 shrink-0 items-center gap-1 overflow-x-auto bg-background px-1 [scrollbar-width:none]"
    >
      {tabs.map((shell) => {
        const active = shell.id === activeId;
        const saved = shells.some((candidate) => candidate.id === shell.id);
        // An unsent draft has no session to read a status from.
        const dot = saved ? STATUS_DOT[resolveSidebarThreadStatus(shell as never)] : undefined;
        const title = shell.title || "New thread";
        const cardKey = cardColorKey(shell);
        const tabKey = tabColorKey(shell);
        const own = colors.tabs[tabKey] ?? null;
        const hue = colorHex(own ?? colors.cards[cardKey]);
        const subagent = saved && isSubagentThread(shell);
        const icon = subagent ? (
          // A helper of another agent: the agent mark, so it reads as a subagent, not another session.
          <BotIcon aria-hidden className="size-3.5 text-muted-foreground" />
        ) : providerEntries && saved ? (
          <SidebarProviderStack
            thread={shell as never}
            providerEntryByInstanceId={providerEntries}
            currentOnly
          />
        ) : saved ? null : (
          // A draft has no provider yet; the compose icon fills the slot.
          <SquarePenIcon aria-hidden className="size-3.5 text-muted-foreground" />
        );
        return (
          <div
            key={shell.id}
            data-tab-id={shell.id}
            className={cn(
              "group/tab flex h-6 min-w-24 max-w-64 flex-[0_1_14rem] items-center gap-1.5 rounded-md px-2 text-xs",
              active
                ? "bg-accent text-foreground"
                : "text-muted-foreground hover:bg-accent/60 hover:text-foreground",
              // The tab's colour (its own, else its card's) washes the tab, more on hover.
              hue &&
                "relative before:pointer-events-none before:absolute before:inset-0 before:rounded-md before:bg-(--octet-hue) before:opacity-15 hover:before:opacity-25",
            )}
            style={hue ? ({ "--octet-hue": hue } as CSSProperties) : undefined}
            onContextMenu={(event: MouseEvent) => {
              // Only the tab's own colour: right-click sets or clears it.
              if (!saved) return;
              event.preventDefault();
              void readLocalApi()
                ?.contextMenu.show([buildColorMenuItem<string>(own, {})], {
                  x: event.clientX,
                  y: event.clientY,
                })
                .then((picked) => {
                  const choice = picked === null ? undefined : parseColorMenuId(picked);
                  if (choice !== undefined) setTabColor(tabKey, choice);
                });
            }}
            onAuxClick={(event: MouseEvent) => {
              if (event.button !== 1) return;
              event.preventDefault();
              close(shell);
            }}
          >
            {closable ? (
              <PanelTabCloseButton
                label={`Close ${title}`}
                tooltip="Close tab (settles the thread)"
                onClick={() => close(shell)}
              >
                {icon}
              </PanelTabCloseButton>
            ) : (
              <span className="flex size-4 shrink-0 items-center justify-center">{icon}</span>
            )}
            <button
              type="button"
              role="tab"
              aria-selected={active}
              tabIndex={active ? 0 : -1}
              title={title}
              onClick={() => open(shell)}
              onKeyDown={(event) => onTabKeyDown(event, shell)}
              className="flex min-w-0 flex-1 cursor-pointer items-center gap-1.5 text-left outline-none focus-visible:underline"
            >
              <span className="min-w-0 truncate">{title}</span>
              {dot ? (
                <span aria-hidden className={cn("size-1.5 shrink-0 rounded-full", dot)} />
              ) : null}
            </button>
          </div>
        );
      })}
      <button
        type="button"
        aria-label="New agent on this branch"
        title={onEmptyDraft ? "A new thread is already open" : "New agent on this branch"}
        disabled={onEmptyDraft}
        onClick={addAgent}
        className="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-md text-muted-foreground hover:bg-accent/60 hover:text-foreground disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
      >
        <PlusIcon aria-hidden className="size-3.5" />
      </button>
    </div>
  );
}
