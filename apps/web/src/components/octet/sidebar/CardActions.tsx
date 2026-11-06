import { useDraggable, useDroppable } from "@dnd-kit/core";
import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import { AuthOrchestrationOperateScope } from "@t3tools/contracts";
import { useAtomValue } from "@effect/atom-react";
import { useState, type ReactNode } from "react";

import { cn } from "~/lib/utils";
import { useThreadActionMenu } from "../../../hooks/useThreadActionMenu";
import { useThreadActions } from "../../../hooks/useThreadActions";
import { readEnvironmentScope } from "../../../state/session";
import { threadEnvironment } from "../../../state/threads";
import { useOrchestrationCommand } from "../../../state/use-orchestration-command";
import type { SidebarThreadSummary } from "../../../types";
import { canShareWithGuestAtom } from "../../chat/guestShareAvailability";
import { requestCustomSnooze } from "../../CustomSnoozeDialog";
import { toastManager } from "../../ui/toast";
import { cardColorKey, setCardColor, useOctetColors } from "../colors/octetColors";
import { CardPeek } from "./CardPeek";
import {
  planCardDrop,
  resolveCardRename,
  type BranchCard,
  type CardPlace,
} from "./octetSidebar.logic";

export interface CardDragData {
  readonly card: BranchCard<SidebarThreadSummary>;
  readonly place: CardPlace;
}

/** The ids of the places a card can be dropped. */
export const dropId = (place: CardPlace) => `octet-drop:${place}`;

/** A place that takes dropped cards: the Idle and Waiting shelves, and the project list. */
export function CardDropZone(props: { place: CardPlace; className?: string; children: ReactNode }) {
  const { setNodeRef, isOver, active } = useDroppable({ id: dropId(props.place) });
  const from = (active?.data.current as CardDragData | undefined)?.place;
  // Only light up for a drop that would do something.
  const accepts = isOver && from !== undefined && planCardDrop(from, props.place) !== "none";
  return (
    <div
      ref={setNodeRef}
      data-drop-active={accepts ? "" : undefined}
      className={cn(
        "rounded-md transition-colors data-[drop-active]:bg-sidebar-row-hover data-[drop-active]:ring-1 data-[drop-active]:ring-inset data-[drop-active]:ring-ring/50",
        props.className,
      )}
    >
      {props.children}
    </div>
  );
}

/**
 * Moving a dragged card: settle or snooze every thread on it, or bring them
 * back. The same thread actions T3's context menu runs.
 */
export function useCardDrop() {
  const { settleThread, unsettleThread, snoozeThread, unsnoozeThread } = useThreadActions();
  return async (data: CardDragData, to: CardPlace) => {
    const plan = planCardDrop(data.place, to);
    if (plan === "none") return;
    let snoozedUntil: string | null = null;
    if (plan === "snooze") {
      const choice = await requestCustomSnooze();
      if (!choice) return;
      snoozedUntil = choice.snoozedUntil;
    }
    for (const thread of data.card.threads) {
      const ref = scopeThreadRef(thread.environmentId, thread.id);
      const result = await (plan === "settle"
        ? settleThread(ref)
        : plan === "unsettle"
          ? unsettleThread(ref)
          : plan === "unsnooze"
            ? unsnoozeThread(ref)
            : snoozeThread(ref, snoozedUntil!));
      if (result._tag === "Failure" && !isAtomCommandInterrupted(result)) {
        const error = squashAtomCommandFailure(result);
        toastManager.add({
          type: "error",
          title: "Could not move the card",
          description: error instanceof Error ? error.message : "An error occurred.",
        });
        return;
      }
    }
  };
}

/**
 * What a card does beyond opening: T3's thread menu on right-click (rename,
 * settle, snooze, archive and the rest, on the card's newest thread), an
 * inline rename, a drag to a shelf, and a hover peek of its threads.
 */
export function useCardActions(props: {
  card: BranchCard<SidebarThreadSummary>;
  place: CardPlace;
  projectCwd: string | null;
  onOpen: (thread: SidebarThreadSummary) => void;
}) {
  const { card } = props;
  const newest = card.threads[0]!;
  const threadRef = scopeThreadRef(newest.environmentId, newest.id);
  const [renamingTitle, setRenamingTitle] = useState<string | null>(null);
  const canShareWithGuest = useAtomValue(canShareWithGuestAtom(newest.environmentId));
  const updateThreadMetadata = useOrchestrationCommand(threadEnvironment.updateMetadata, {
    reportFailure: false,
  });
  const colors = useOctetColors();
  const colorKey = cardColorKey(newest);
  const { openMenu } = useThreadActionMenu({
    color: {
      selected: colors.cards[colorKey] ?? null,
      onSelect: (choice) => setCardColor(colorKey, choice),
    },
    threadRef,
    projectCwd: props.projectCwd,
    onStartRename: () => {
      if (!readEnvironmentScope(newest.environmentId, AuthOrchestrationOperateScope)) return;
      setRenamingTitle(newest.title);
    },
    canShareWithGuest,
  });
  const drag = useDraggable({
    id: `octet-card:${props.place}:${card.key}:${newest.id}`,
    data: { card, place: props.place } satisfies CardDragData,
  });
  const commitRename = () => {
    const title = renamingTitle ?? "";
    setRenamingTitle(null);
    const resolution = resolveCardRename({ title, originalTitle: newest.title });
    if (resolution.action === "reject-empty") {
      toastManager.add({ type: "warning", title: "Thread title cannot be empty" });
      return;
    }
    if (resolution.action === "noop") return;
    void updateThreadMetadata({
      environmentId: newest.environmentId,
      input: { threadId: newest.id, title: resolution.title },
    }).then((result) => {
      if (result._tag === "Failure" && !isAtomCommandInterrupted(result)) {
        const error = squashAtomCommandFailure(result);
        toastManager.add({
          type: "error",
          title: "Failed to rename thread",
          description: error instanceof Error ? error.message : "An error occurred.",
        });
      }
    });
  };
  return {
    onContextMenu: openMenu,
    rename:
      renamingTitle === null
        ? undefined
        : {
            title: renamingTitle,
            onChange: setRenamingTitle,
            onCommit: commitRename,
            onCancel: () => setRenamingTitle(null),
          },
    liRef: drag.setNodeRef,
    // Pointer only: the row itself is the keyboard target, so no dnd-kit key handling.
    liProps: { onPointerDown: drag.listeners?.onPointerDown as React.PointerEventHandler<HTMLLIElement> | undefined },
    dragging: drag.isDragging,
    dragTransform: drag.transform,
    peek: <CardPeek card={card} onOpen={props.onOpen} />,
  };
}
