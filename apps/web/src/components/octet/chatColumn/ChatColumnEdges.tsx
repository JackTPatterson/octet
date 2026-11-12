import type { ChatWidth } from "@t3tools/contracts";
import { useRef, useState, type KeyboardEvent, type PointerEvent } from "react";

import { updateClientSettings, useClientSettings } from "../../../hooks/useSettings";
import { observeResize } from "../../../lib/observeResize";
import { cn } from "~/lib/utils";
import { Tooltip, TooltipTrigger, TooltipPopup } from "../../ui/tooltip";
import {
  chatColumnWidth,
  distinctChatWidths,
  nearestChatWidth,
  stepChatWidth,
} from "./chatColumn.logic";

const STRIP_PX = 12;
/** Clear of the find bar along the top. */
const TOP_INSET_PX = 44;
// The message minimap occupies the first 72px along the left edge.
const MINIMAP_WIDTH_PX = 72;
const LABELS: Record<ChatWidth, string> = {
  comfortable: "Comfortable",
  wide: "Wide",
  full: "Full",
};

export function ChatColumnEdges() {
  const chatWidth = useClientSettings((settings) => settings.chatWidth);
  const [available, setAvailable] = useState(0);
  const [hovered, setHovered] = useState(false);
  const [draggingSide, setDraggingSide] = useState<string | null>(null);
  const dragging = draggingSide !== null;
  const drag = useRef<{
    pointerId: number;
    start: ChatWidth;
    left: number;
  } | null>(null);
  const stopObserving = useRef<(() => void) | null>(null);
  const abort = useRef<(() => void) | null>(null);

  const measure = (node: HTMLDivElement | null) => {
    stopObserving.current?.();
    stopObserving.current = null;
    if (!node) return;
    setAvailable(node.clientWidth);
    stopObserving.current = observeResize(node, () => setAvailable(node.clientWidth));
  };

  const set = (next: ChatWidth) => {
    if (next !== chatWidth) updateClientSettings({ chatWidth: next });
  };

  const endDrag = (revertTo?: ChatWidth) => {
    abort.current?.();
    abort.current = null;
    drag.current = null;
    setDraggingSide(null);
    if (revertTo) updateClientSettings({ chatWidth: revertTo });
  };

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0 || drag.current) return;
    const container = event.currentTarget.parentElement;
    if (!container) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    event.preventDefault();
    const start = chatWidth;
    drag.current = {
      pointerId: event.pointerId,
      start,
      left: container.getBoundingClientRect().left,
    };
    setDraggingSide(event.currentTarget.dataset.side ?? "right");
    // Escape, or leaving the window, puts the width back as it was.
    const cancel = () => endDrag(start);
    const onKeyDown = (key: globalThis.KeyboardEvent) => {
      if (key.key !== "Escape") return;
      key.preventDefault();
      key.stopPropagation();
      cancel();
    };
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("blur", cancel);
    abort.current = () => {
      window.removeEventListener("keydown", onKeyDown, true);
      window.removeEventListener("blur", cancel);
    };
  };

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const active = drag.current;
    if (!active || active.pointerId !== event.pointerId) return;
    // The column is centred, so its width is twice the pointer's distance from the middle.
    const width = 2 * Math.abs(event.clientX - active.left - available / 2);
    set(nearestChatWidth(width, available));
  };

  const onPointerUp = (event: PointerEvent<HTMLDivElement>) => {
    if (drag.current?.pointerId === event.pointerId) endDrag();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const delta = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (delta === 0) return;
    event.preventDefault();
    // The right edge widens with the right arrow, the left edge with the left one.
    const side = event.currentTarget.dataset.side === "left" ? -1 : 1;
    set(stepChatWidth(chatWidth, (delta * side) as -1 | 1, available));
  };

  const column = chatColumnWidth(chatWidth, available);
  const lit = hovered || dragging;
  const strip = (side: "left" | "right") => (
    <Tooltip key={side}>
      <TooltipTrigger
        render={
          <div
            role="separator"
            aria-orientation="vertical"
            aria-label="Conversation width"
            aria-valuetext={LABELS[chatWidth]}
            data-side={side}
            data-testid={`chat-column-edge-${side}`}
            tabIndex={0}
            className="group pointer-events-auto absolute inset-y-0 cursor-col-resize touch-none select-none outline-none"
            style={{
              width: STRIP_PX,
              left:
                side === "left"
                  ? Math.max(0, available / 2 - column / 2 - STRIP_PX - 2)
                  : Math.min(available - STRIP_PX, available / 2 + column / 2 + 2),
            }}
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={onPointerUp}
            onPointerCancel={() => endDrag(drag.current?.start)}
            onLostPointerCapture={() => drag.current && endDrag()}
            onPointerEnter={() => setHovered(true)}
            onPointerLeave={() => setHovered(false)}
            onDoubleClick={() => set("comfortable")}
            onKeyDown={onKeyDown}
          >
            <span
              aria-hidden
              className={cn(
                "pointer-events-none absolute top-1/2 left-1/2 h-11 w-1 -translate-x-1/2 -translate-y-1/2 rounded-full bg-border opacity-0 transition-opacity duration-150 group-focus-visible:bg-primary/60 group-focus-visible:opacity-100",
                lit && "opacity-100",
                dragging && "bg-primary/60",
              )}
            />
          </div>
        }
      />
      <TooltipPopup side="right">
        Drag to resize the conversation. Double-click to reset.
      </TooltipPopup>
    </Tooltip>
  );

  return (
    <div
      ref={measure}
      className="pointer-events-none absolute inset-x-0 bottom-0 z-10"
      style={{ top: TOP_INSET_PX }}
    >
      {/* A window too narrow for more than one width has nothing to drag between. */}
      {distinctChatWidths(available).length > 1 ? (
        <>
          {available / 2 - column / 2 - STRIP_PX - 2 >= MINIMAP_WIDTH_PX || draggingSide === "left"
            ? strip("left")
            : null}
          {strip("right")}
        </>
      ) : null}
    </div>
  );
}
