import type { ChatWidth } from "@t3tools/contracts";

/** --chat-content-max-width for each width, in px at the default root size (46rem, 72rem). */
const COLUMN_PX = { comfortable: 736, wide: 1152 } as const;
/** The timeline's and composer's side padding. */
export const CHAT_COLUMN_GUTTER = 24;
/**
 * A drag has two stops: the comfortable column and the full width. "Wide" stays a valid
 * setting (it is in saved settings) and reads as whichever stop it is nearer.
 */
const ORDER: ReadonlyArray<ChatWidth> = ["comfortable", "full"];

/** The column's width for a setting, in a conversation `available` px wide. */
export function chatColumnWidth(width: ChatWidth, available: number): number {
  const full = Math.max(0, available - 2 * CHAT_COLUMN_GUTTER);
  return width === "full" ? full : Math.min(COLUMN_PX[width], full);
}

/**
 * The widths that differ in a conversation `available` px wide. Where two are as wide as
 * each other (the wide column in a narrow window) the later one stands, so a drag skips it.
 */
export function distinctChatWidths(available: number): ReadonlyArray<ChatWidth> {
  return ORDER.filter(
    (width, index) =>
      !ORDER.slice(index + 1).some(
        (later) => chatColumnWidth(later, available) === chatColumnWidth(width, available),
      ),
  );
}

/** The setting whose column is nearest `width`. */
export function nearestChatWidth(width: number, available: number): ChatWidth {
  const choices = distinctChatWidths(available);
  return choices.reduce((best, candidate) =>
    Math.abs(chatColumnWidth(candidate, available) - width) <
    Math.abs(chatColumnWidth(best, available) - width)
      ? candidate
      : best,
  );
}

/** One step wider (+1) or narrower (-1), stopping at the ends. */
export function stepChatWidth(current: ChatWidth, delta: -1 | 1, available: number): ChatWidth {
  const choices = distinctChatWidths(available);
  const index = choices.indexOf(nearestChatWidth(chatColumnWidth(current, available), available));
  return choices[Math.max(0, Math.min(choices.length - 1, index + delta))]!;
}
