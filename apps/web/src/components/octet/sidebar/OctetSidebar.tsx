import { cardColorKey, colorHex, useOctetColors } from "../colors/octetColors";
import { NewWaitButton } from "../waits/NewWaitButton";
import {
  scopedThreadKey,
  scopeProjectRef,
  scopeThreadRef,
} from "@t3tools/client-runtime/environment";
import type { DiscoveredLocalServer, ScopedThreadRef } from "@t3tools/contracts";
import { useAtomValue } from "@effect/atom-react";
import {
  DndContext,
  PointerSensor,
  useDndContext,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { useRouter } from "@tanstack/react-router";
import { SquarePenIcon } from "lucide-react";
import { useRef, useState, type KeyboardEvent, type ReactNode } from "react";

import { cn } from "~/lib/utils";
import { useDiscoveredPortsState } from "../../../portDiscoveryState";
import { previewEnvironment } from "../../../state/preview";
import { useAtomCommand } from "../../../state/use-atom-command";
import { openDiscoveredPort } from "../../preview/openDiscoveredPort";
import { ServicePortsRow } from "./ServicePortsRow";
import { openCommandPalette } from "../../../commandPaletteBus";
import { useComposerDraftStore } from "../../../composerDraftStore";
import { isElectron } from "../../../env";
import { useHandleNewThread } from "../../../hooks/useHandleNewThread";
import { useNowMinute } from "../../../hooks/useNowMinute";
import { useThreadRouteTarget } from "../../../hooks/useThreadRouteTarget";
import type { SidebarProjectSnapshot } from "../../../sidebarProjectGrouping";
import {
  useConnectedEnvironmentIds,
  useEnvironmentConnectionSummaries,
} from "../../../state/environments";
import { useDelegatedUnderParent, useQuietThreadShells } from "../../../state/entities";
import { liveShellEnvironmentIdsAtom } from "../../../state/shell";
import { buildThreadRouteParams, resolveActiveThreadRouteRef } from "../../../threadRoutes";
import { formatRelativeTime } from "../../../timestampFormat";
import type { SidebarThreadSummary } from "../../../types";
import { resolveProjectExpanded, useUiStateStore } from "../../../uiStateStore";
import { ProjectFavicon } from "../../ProjectFavicon";
import { WaitRows, useVisibleWaits } from "../waits/WaitRows";
import { partitionSidebarThreads, threadShellKey, useSidebarLookups } from "../../Sidebar";
import {
  groupSidebarThreadsByProject,
  isSidebarEnvironmentDisconnected,
  resolveSidebarThreadStatus,
  sidebarFolderExpansionKeys,
  useSnoozeWakeClock,
} from "../../Sidebar.logic";
import { ThreadWorktreeIndicator } from "../../ThreadStatusIndicators";
import { SidebarChromeFooter, SidebarChromeHeader } from "../../sidebar/SidebarChrome";
import { SidebarProjectFolderHeader } from "../../sidebar/SidebarProjectFolderHeader";
import { SidebarThreadHeader } from "../../sidebar/SidebarThreadHeader";
import { SidebarProviderStack, ThreadRenameInput } from "../../sidebar/SidebarThreadRow";
import { CollapsibleSectionHeader } from "../../ui/collapsible-section-header";
import { PreviewCard, PreviewCardPopup, PreviewCardTrigger } from "../../ui/preview-card";
import { MiddleTruncate } from "../../ui/middle-truncate";
import { SidebarContent, SidebarGroup, useSidebar } from "../../ui/sidebar";
import { CardDropZone, useCardActions, useCardDrop, type CardDragData } from "./CardActions";
import { STATUS_LABEL } from "./cardStatus";
import { ProjectFilter } from "./ProjectFilter";
import {
  filterBranchCards,
  groupIntoBranchCards,
  projectInScope,
  type BranchCard,
  type CardPlace,
} from "./octetSidebar.logic";

type ProviderEntryMap = Parameters<typeof SidebarProviderStack>[0]["providerEntryByInstanceId"];
type FaviconProject = Parameters<typeof ProjectFavicon>[0]["project"];

const EMPTY_PROVIDER_ENTRIES: ProviderEntryMap = new Map();

function useRouteThreadKey(): string | null {
  const routeTarget = useThreadRouteTarget();
  const draft = useComposerDraftStore((store) =>
    routeTarget?.kind === "draft" ? store.getDraftSession(routeTarget.draftId) : null,
  );
  const ref = resolveActiveThreadRouteRef(routeTarget, draft);
  return ref === null ? null : scopedThreadKey(ref);
}

function relativeAge(thread: SidebarThreadSummary, nowMs: number): string {
  return formatRelativeTime(thread.latestUserMessageAt ?? thread.updatedAt, nowMs)?.value ?? "";
}

/**
 * Octet's sidebar: each project, then one card per branch, then the Waiting
 * and Idle shelves. Native Octet's structure, drawn entirely with T3's
 * sidebar parts; T3's own sidebar stays in `../../Sidebar.tsx`.
 */
export default function OctetSidebar() {
  const {
    serverConfigs,
    projectGroups,
    providerEntriesByEnvironment,
    projectByKey,
    projectDisplayNameByKey,
  } = useSidebarLookups();
  const delegatedUnderParent = useDelegatedUnderParent();
  const threads = useQuietThreadShells();
  const connectedEnvironmentIds = useConnectedEnvironmentIds();
  const environmentConnections = useEnvironmentConnectionSummaries();
  const liveShellEnvironmentIds = useAtomValue(liveShellEnvironmentIdsAtom);
  const nowMinute = useNowMinute();
  const snoozeWakeClock = useSnoozeWakeClock(threads);
  const routeThreadKey = useRouteThreadKey();
  const router = useRouter();
  const { isMobile, setOpenMobile } = useSidebar();
  const { handleNewThread } = useHandleNewThread();
  const projectExpandedById = useUiStateStore((store) => store.projectExpandedById);
  const setProjectExpanded = useUiStateStore((store) => store.setProjectExpanded);
  const persistedScopeKeys = useUiStateStore((store) => store.sidebarProjectScopeKeys);
  const dropCard = useCardDrop();
  // A drag starts after a few pixels, so a click still opens the card.
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));
  const searchInputRef = useRef<HTMLInputElement>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [waitingOpen, setWaitingOpen] = useState(false);
  const [idleOpen, setIdleOpen] = useState(false);
  // Waits come from the first connected environment (the local one, in practice).
  const waitsEnvironmentId = connectedEnvironmentIds[0] ?? null;
  const waits = useVisibleWaits(waitsEnvironmentId);

  const disconnectedEnvironmentIds = new Set(
    environmentConnections
      .filter((environment) =>
        isSidebarEnvironmentDisconnected(
          environment.connectionState,
          liveShellEnvironmentIds.has(environment.environmentId),
        ),
      )
      .map((environment) => environment.environmentId),
  );
  // The project filter: T3's stored scope, ignoring projects that no longer exist.
  const knownProjectKeys = new Set(projectGroups.map((group) => group.projectKey));
  const scopeKeys = persistedScopeKeys.filter((key) => knownProjectKeys.has(key));
  const scopedProjectKeys =
    scopeKeys.length === 0
      ? null
      : new Set(
          projectGroups
            .filter((group) => scopeKeys.includes(group.projectKey))
            .flatMap((group) =>
              group.memberProjectRefs.map((ref) => `${ref.environmentId}:${ref.projectId}`),
            ),
        );
  const partition = partitionSidebarThreads({
    threads,
    scopedProjectKeys,
    delegatedUnderParent,
    serverConfigs,
    connectedEnvironmentIds,
    optimisticDrop: null,
    workingShelfEnabled: false,
    sortActiveBySend: true,
    disconnectedEnvironmentIds,
    clockKey: `${nowMinute}:${snoozeWakeClock}`,
  });
  const isSearching = searchQuery.trim().length > 0;
  // Octet has no pinned section: pinned threads sit on their branch's card.
  const folders = groupSidebarThreadsByProject(
    projectGroups.filter((group) => !group.archived),
    [...partition.pinnedThreads, ...partition.activeThreads],
    () => false,
  )
    .filter((folder) => projectInScope(folder.group.projectKey, scopeKeys))
    .map((folder) => {
      const expansionKeys = sidebarFolderExpansionKeys(folder.group);
      return {
        ...folder,
        expansionKeys,
        // A search shows every match, folded or not.
        collapsed: !isSearching && !resolveProjectExpanded(projectExpandedById, expansionKeys),
        cards: filterBranchCards(
          groupIntoBranchCards(folder.threads, resolveSidebarThreadStatus),
          searchQuery,
        ),
      };
    });
  const matchingCards = folders.flatMap((folder) => folder.cards);

  const openThread = (ref: ScopedThreadRef) => {
    if (isMobile) setOpenMobile(false);
    void router.navigate({ to: "/$environmentId/$threadId", params: buildThreadRouteParams(ref) });
  };
  const openShell = (thread: SidebarThreadSummary) =>
    openThread(scopeThreadRef(thread.environmentId, thread.id));
  const newThreadOnCard = (card: BranchCard<SidebarThreadSummary>) => {
    const newest = card.threads[0]!;
    void handleNewThread(scopeProjectRef(newest.environmentId, newest.projectId), {
      branch: card.branch,
      worktreePath: card.worktreePath,
      envMode: card.worktreePath ? "worktree" : "local",
      startFromOrigin: false,
    });
  };
  const handleSearchKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      setSearchQuery("");
    } else if (event.key === "Enter" && matchingCards[0]) {
      event.preventDefault();
      openShell(matchingCards[0].threads[0]!);
    }
  };
  const nowMs = Date.now();
  const providersFor = (thread: SidebarThreadSummary) =>
    providerEntriesByEnvironment.get(thread.environmentId) ?? EMPTY_PROVIDER_ENTRIES;
  // Shelf rows sit outside their project, so they name it, as T3's rows do.
  const projectFor = (thread: SidebarThreadSummary) => {
    const key = `${thread.environmentId}:${thread.projectId}` as const;
    const project = projectByKey.get(key);
    return project ? { project, name: projectDisplayNameByKey.get(key) ?? null } : null;
  };

  const projectCwdFor = (thread: SidebarThreadSummary) =>
    projectByKey.get(`${thread.environmentId}:${thread.projectId}` as const)?.workspaceRoot ?? null;
  const handleDragEnd = (event: DragEndEvent) => {
    const data = event.active.data.current as CardDragData | undefined;
    const over = event.over ? String(event.over.id) : null;
    if (!data || !over?.startsWith("octet-drop:")) return;
    void dropCard(data, over.slice("octet-drop:".length) as CardPlace);
  };

  return (
    <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
      <SidebarChromeHeader isElectron={isElectron} />
      <SidebarContent
        className="min-h-full"
        fixedHeader={
          <SidebarGroup className="z-[1]">
            <SidebarThreadHeader
              hasProjects={projectGroups.length > 0}
              projectScope={<ProjectFilter groups={projectGroups} scopeKeys={scopeKeys} />}
              onNewProject={() => openCommandPalette({ open: "add-project" })}
              onNewThread={() => {
                if (isMobile) setOpenMobile(false);
                openCommandPalette({ open: "new-thread-in" });
              }}
              newThreadDisabled={projectGroups.length === 0}
              newThreadShortcutLabel={null}
              newThreadInProjectShortcutLabel={null}
              showNewThreadInProjectHint={false}
              searchInputRef={searchInputRef}
              searchQuery={searchQuery}
              onSearchQueryChange={setSearchQuery}
              onSearchKeyDown={handleSearchKeyDown}
              isSearching={isSearching}
              searchResultCount={matchingCards.length}
              activeSearchResultIndex={0}
              onClearSearch={() => setSearchQuery("")}
            />
          </SidebarGroup>
        }
      >
        <SidebarGroup className="flex flex-1 flex-col">
          <CardDropZone place="active">
            <ul className="flex flex-col">
              {folders
                .filter((folder) => !isSearching || folder.cards.length > 0)
                .map((folder) => (
                  <FolderSection
                    key={folder.group.projectKey}
                    group={folder.group}
                    collapsed={folder.collapsed}
                    hiddenThreads={folder.collapsed ? folder.threads : []}
                    onToggle={() => setProjectExpanded(folder.expansionKeys, folder.collapsed)}
                    onNewThread={() =>
                      void handleNewThread(
                        scopeProjectRef(folder.group.environmentId, folder.group.id),
                      )
                    }
                  >
                    {folder.cards.map((card) => (
                      <ActionableCard
                        key={card.key}
                        place="active"
                        projectCwd={projectCwdFor(card.threads[0]!)}
                        card={card}
                        routeThreadKey={routeThreadKey}
                        nowMs={nowMs}
                        providerEntries={providersFor(card.threads[0]!)}
                        onOpen={openShell}
                        onNewThread={() => newThreadOnCard(card)}
                        showServers
                      />
                    ))}
                  </FolderSection>
                ))}
            </ul>
          </CardDropZone>
          {/* T3's shelves: a muted label, a trailing count, a chevron. */}
          <div className="mt-auto pt-2">
            <Shelf
              label="Waiting"
              place="waiting"
              projectCwdFor={projectCwdFor}
              threads={partition.snoozedThreads}
              extraCount={waits.length}
              extra={
                waitsEnvironmentId ? (
                  <WaitRows
                    environmentId={waitsEnvironmentId}
                    waits={waits}
                    onOpenThread={openThread}
                  />
                ) : null
              }
              footer={
                waitsEnvironmentId ? (
                  <div className="flex justify-end px-2 pb-1">
                    <NewWaitButton />
                  </div>
                ) : null
              }
              open={waitingOpen}
              onToggle={() => setWaitingOpen((value) => !value)}
              routeThreadKey={routeThreadKey}
              nowMs={nowMs}
              providersFor={providersFor}
              projectFor={projectFor}
              onOpen={openShell}
            />
            <Shelf
              label="Idle"
              place="idle"
              projectCwdFor={projectCwdFor}
              threads={partition.settledThreads}
              open={idleOpen}
              onToggle={() => setIdleOpen((value) => !value)}
              routeThreadKey={routeThreadKey}
              nowMs={nowMs}
              providersFor={providersFor}
              projectFor={projectFor}
              onOpen={openShell}
            />
          </div>
        </SidebarGroup>
      </SidebarContent>
      <SidebarChromeFooter />
    </DndContext>
  );
}

function FolderSection(props: {
  group: SidebarProjectSnapshot;
  collapsed: boolean;
  hiddenThreads: readonly SidebarThreadSummary[];
  onToggle: () => void;
  onNewThread: () => void;
  children: ReactNode;
}) {
  return (
    <>
      <SidebarProjectFolderHeader
        group={props.group}
        collapsed={props.collapsed}
        hiddenThreads={props.hiddenThreads}
        onToggle={props.onToggle}
        onNewThread={props.onNewThread}
        onContextMenu={() => {}}
      />
      {props.collapsed ? null : props.children}
    </>
  );
}

/**
 * One branch, drawn as T3's thread row: the newest thread's title and the
 * branch's loudest status on top, then the branch and the agent.
 */
export function BranchCardRow(props: {
  card: BranchCard<SidebarThreadSummary>;
  routeThreadKey: string | null;
  nowMs: number;
  providerEntries: ProviderEntryMap;
  onOpen: (thread: SidebarThreadSummary) => void;
  onNewThread?: () => void;
  /** Show the servers this branch's threads started, as a row of port buttons. */
  showServers?: boolean;
  /** Servers to draw instead of querying for them (used by the screenshot test). */
  servers?: ReadonlyArray<DiscoveredLocalServer>;
  /** Shown above the title where the row sits outside its project, as T3's rows do. */
  project?: FaviconProject | null;
  projectName?: string | null;
  /** Right-click: T3's thread menu, from `useCardActions`. */
  onContextMenu?: ((position: { x: number; y: number }) => void) | undefined;
  /** Present while the title is being renamed. */
  rename?:
    | {
        title: string;
        onChange: (title: string) => void;
        onCommit: () => void;
        onCancel: () => void;
      }
    | undefined;
  /** Drag wiring, from `useCardActions`. */
  liRef?: ((node: HTMLLIElement | null) => void) | undefined;
  liProps?: { onPointerDown?: React.PointerEventHandler<HTMLLIElement> | undefined } | undefined;
  dragging?: boolean | undefined;
  dragTransform?: { x: number; y: number } | null | undefined;
  /** Content for the hover peek; the card shows no peek without it. */
  peek?: ReactNode | undefined;
}) {
  const { card } = props;
  const newest = card.threads[0]!;
  const active = card.threads.some((thread) => threadShellKey(thread) === props.routeThreadKey);
  const status = STATUS_LABEL[card.status];
  // T3 recedes a quiet row that isn't open.
  const recede = !active && card.status === "ready";
  const colors = useOctetColors();
  const hue = colorHex(colors.cards[cardColorKey(newest)]);
  return (
    <li
      ref={props.liRef}
      data-testid="octet-branch-card"
      data-dragging={props.dragging ? "" : undefined}
      onPointerDown={props.liProps?.onPointerDown}
      style={
        props.dragTransform
          ? { transform: `translate3d(${props.dragTransform.x}px, ${props.dragTransform.y}px, 0)` }
          : undefined
      }
      className={cn(
        "list-none py-0.5 data-[dragging]:relative data-[dragging]:z-50 data-[dragging]:opacity-80 data-[dragging]:shadow-lg",
      )}
    >
      <PeekFrame peek={props.dragging || props.rename ? undefined : props.peek}>
        <div
          role="button"
          tabIndex={0}
          onContextMenu={
            props.onContextMenu
              ? (event) => {
                  event.preventDefault();
                  props.onContextMenu?.({ x: event.clientX, y: event.clientY });
                }
              : undefined
          }
          aria-current={active ? "page" : undefined}
          onClick={() => props.onOpen(newest)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              props.onOpen(newest);
            }
          }}
          style={hue ? ({ "--octet-hue": hue } as React.CSSProperties) : undefined}
          className={cn(
            "group/sidebar-row relative w-full cursor-pointer overflow-hidden rounded-md text-left outline-none select-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring",
            active
              ? "bg-sidebar-row-active text-sidebar-foreground light:ring-1 light:ring-inset light:ring-sidebar-border/70"
              : recede
                ? "text-sidebar-muted-foreground/75 hover:bg-sidebar-row-hover hover:text-sidebar-foreground"
                : "bg-transparent text-sidebar-foreground hover:bg-sidebar-row-hover",
          )}
        >
          {hue ? (
            // A hint of the card's colour over the row's fill: a little more on hover and when open.
            <span
              aria-hidden
              data-testid="octet-card-hue"
              className={cn(
                "pointer-events-none absolute inset-0 transition-opacity",
                active ? "opacity-[0.12]" : "opacity-[0.08] group-hover/sidebar-row:opacity-[0.2]",
              )}
              style={{ backgroundColor: hue }}
            />
          ) : null}
          <div className="relative z-10 px-(--sidebar-row-content-inset) py-(--sidebar-content-inset)">
            {props.project ? (
              <div className="flex h-5 min-w-0 items-center gap-1.5">
                <ProjectFavicon project={props.project} className="size-4 shrink-0" />
                <span className="min-w-0 flex-1 truncate font-normal text-secondary-label text-xs">
                  {props.projectName}
                </span>
              </div>
            ) : null}
            <div className={cn("flex min-w-0 items-center gap-1.5", props.project && "mt-1")}>
              {props.rename ? (
                <ThreadRenameInput
                  title={props.rename.title}
                  onTitleChange={props.rename.onChange}
                  onCommit={props.rename.onCommit}
                  onCancel={props.rename.onCancel}
                />
              ) : (
                <span
                  className={cn(
                    "min-w-0 flex-1 truncate text-start text-sm",
                    recede
                      ? "font-normal text-foreground/75 group-hover/sidebar-row:text-foreground"
                      : "font-medium text-foreground",
                  )}
                >
                  {newest.title}
                </span>
              )}
              <span className="flex shrink-0 items-center gap-1 text-xs tabular-nums text-secondary-label">
                {status ? (
                  <span className={cn("font-medium", status.className)}>{status.label}</span>
                ) : (
                  <span className={cn(props.onNewThread && "group-hover/sidebar-row:hidden")}>
                    {relativeAge(newest, props.nowMs)}
                  </span>
                )}
                {props.onNewThread ? (
                  <button
                    type="button"
                    aria-label="New thread on this branch"
                    title="New thread on this branch"
                    onClick={(event) => {
                      event.stopPropagation();
                      props.onNewThread?.();
                    }}
                    className="hidden size-4 cursor-pointer items-center justify-center text-sidebar-muted-foreground hover:text-sidebar-foreground group-hover/sidebar-row:flex"
                  >
                    <SquarePenIcon className="size-3.5" aria-hidden />
                  </button>
                ) : null}
              </span>
            </div>
            <div className="mt-0.5 flex min-w-0 items-center gap-1.5 text-secondary-label text-xs">
              {newest.branch ? (
                <>
                  <ThreadWorktreeIndicator thread={newest} />
                  <span className="flex min-w-0 flex-1">
                    <MiddleTruncate value={newest.branch} showTitle={false} />
                  </span>
                </>
              ) : (
                <span className="flex-1" />
              )}
              <span
                aria-hidden
                className="pointer-events-none ml-auto inline-flex shrink-0 items-center gap-1"
              >
                <SidebarProviderStack
                  thread={newest}
                  providerEntryByInstanceId={props.providerEntries}
                />
              </span>
            </div>
          </div>
          {props.servers ? (
            <ServicePortsRow servers={props.servers} onOpen={() => {}} />
          ) : props.showServers ? (
            <CardServers card={card} />
          ) : null}
        </div>
      </PeekFrame>
    </li>
  );
}

/** T3's preview card around a row: opens after a pause on hover, to the side. */
function PeekFrame(props: { peek: ReactNode; children: React.ReactElement }) {
  if (!props.peek) return props.children;
  return (
    <PreviewCard>
      <PreviewCardTrigger delay={600} closeDelay={80} render={props.children} />
      <PreviewCardPopup side="right" align="start" sideOffset={8}>
        {props.peek}
      </PreviewCardPopup>
    </PreviewCard>
  );
}

/** A card with everything it can do: T3's menu, rename, drag and peek. */
function ActionableCard(
  props: React.ComponentProps<typeof BranchCardRow> & {
    place: CardPlace;
    projectCwd: string | null;
  },
) {
  const { place, projectCwd, ...rest } = props;
  const actions = useCardActions({ card: props.card, place, projectCwd, onOpen: props.onOpen });
  return (
    <BranchCardRow
      {...rest}
      onContextMenu={actions.onContextMenu}
      rename={actions.rename}
      liRef={actions.liRef}
      liProps={actions.liProps}
      dragging={actions.dragging}
      dragTransform={actions.dragTransform}
      peek={actions.peek}
    />
  );
}

/** The servers started by any thread on the card, each opening in the browser panel. */
function CardServers(props: { card: BranchCard<SidebarThreadSummary> }) {
  const newest = props.card.threads[0]!;
  const { servers } = useDiscoveredPortsState(newest.environmentId);
  const openPreview = useAtomCommand(previewEnvironment.open, { reportFailure: false });
  const threadIds = new Set<string>(props.card.threads.map((thread) => thread.id));
  const mine = servers.filter((server) => {
    const owner = server.terminal?.threadId ?? server.agent?.threadId;
    return owner !== undefined && threadIds.has(owner);
  });
  return (
    <ServicePortsRow
      servers={mine}
      onOpen={(server) => {
        const owner = server.terminal?.threadId ?? server.agent?.threadId;
        const thread = props.card.threads.find((t) => t.id === owner) ?? newest;
        void openDiscoveredPort({
          threadRef: scopeThreadRef(thread.environmentId, thread.id),
          port: server,
          openPreview,
        });
      }}
    />
  );
}

function Shelf(props: {
  label: string;
  place: CardPlace;
  projectCwdFor: (thread: SidebarThreadSummary) => string | null;
  threads: readonly SidebarThreadSummary[];
  /** Rows that are not threads (waits), counted with them and drawn after them. */
  extraCount?: number;
  extra?: ReactNode;
  /** Drawn last, inside the open shelf. */
  footer?: ReactNode;
  open: boolean;
  onToggle: () => void;
  routeThreadKey: string | null;
  nowMs: number;
  providersFor: (thread: SidebarThreadSummary) => ProviderEntryMap;
  projectFor: (
    thread: SidebarThreadSummary,
  ) => { project: FaviconProject; name: string | null } | null;
  onOpen: (thread: SidebarThreadSummary) => void;
}) {
  // A shelf with nothing on it stays out of the way, except while a card is being dragged,
  // when it is the place to drop it.
  const { active } = useDndContext();
  if (props.threads.length + (props.extraCount ?? 0) === 0 && !active) return null;
  return (
    <CardDropZone place={props.place} className="mx-0.5">
      <CollapsibleSectionHeader
        expanded={props.open}
        onClick={props.onToggle}
        data-testid={`octet-${props.label.toLowerCase()}-shelf-toggle`}
        accessory={
          <span className="font-normal tabular-nums">
            {props.threads.length + (props.extraCount ?? 0)}
          </span>
        }
      >
        {props.label}
      </CollapsibleSectionHeader>
      {props.open ? (
        <ul className="flex flex-col">
          {props.threads.map((thread) => {
            const project = props.projectFor(thread);
            return (
              <ActionableCard
                key={threadShellKey(thread)}
                place={props.place}
                projectCwd={props.projectCwdFor(thread)}
                card={{
                  key: threadShellKey(thread),
                  branch: thread.branch,
                  worktreePath: thread.worktreePath,
                  threads: [thread],
                  latestActivityMs: 0,
                  status: resolveSidebarThreadStatus(thread),
                }}
                routeThreadKey={props.routeThreadKey}
                nowMs={props.nowMs}
                providerEntries={props.providersFor(thread)}
                project={project?.project ?? null}
                projectName={project?.name ?? null}
                onOpen={props.onOpen}
              />
            );
          })}
        </ul>
      ) : null}
      {props.open ? props.extra : null}
      {props.open ? props.footer : null}
    </CardDropZone>
  );
}

/** T3's own sidebar stays reachable while Octet's is built: set `octet.sidebar` to `t3`. */
export function prefersT3Sidebar(): boolean {
  try {
    return globalThis.localStorage?.getItem("octet.sidebar") === "t3";
  } catch {
    return false;
  }
}
