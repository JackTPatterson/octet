import type { ContextMenuItem } from "@t3tools/contracts";
import { useSyncExternalStore } from "react";

/**
 * Colours a card or tab can be given by hand, as native Octet's. Stored by id,
 * so the shades can be retuned without losing anyone's choices.
 */
export const OCTET_COLORS = [
  { id: "red", name: "Red", hex: "#E5484D" },
  { id: "orange", name: "Orange", hex: "#F76B15" },
  { id: "yellow", name: "Yellow", hex: "#F5B83D" },
  { id: "green", name: "Green", hex: "#30A46C" },
  { id: "teal", name: "Teal", hex: "#12A5A0" },
  { id: "blue", name: "Blue", hex: "#3B82F6" },
  { id: "purple", name: "Purple", hex: "#8E4EC6" },
  { id: "pink", name: "Pink", hex: "#D6409F" },
] as const;

export type OctetColorId = (typeof OCTET_COLORS)[number]["id"];

/** How strongly a colour washes a row, as native Octet's tab tint. */
export const COLOR_TINT = { rest: 15, hover: 25 } as const;

const STORAGE_KEY = "octet.colors";

interface Stored {
  readonly cards: Readonly<Record<string, OctetColorId>>;
  readonly tabs: Readonly<Record<string, OctetColorId>>;
}

const isColorId = (value: unknown): value is OctetColorId =>
  OCTET_COLORS.some((color) => color.id === value);

function cleanRecord(value: unknown): Record<string, OctetColorId> {
  if (typeof value !== "object" || value === null) return {};
  return Object.fromEntries(Object.entries(value).filter(([, id]) => isColorId(id))) as Record<
    string,
    OctetColorId
  >;
}

export function parseStoredColors(raw: string | null): Stored {
  if (!raw) return { cards: {}, tabs: {} };
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return { cards: cleanRecord(parsed.cards), tabs: cleanRecord(parsed.tabs) };
  } catch {
    return { cards: {}, tabs: {} };
  }
}

let state: Stored | null = null;
const listeners = new Set<() => void>();

function read(): Stored {
  if (state) return state;
  let raw: string | null = null;
  try {
    raw = globalThis.localStorage?.getItem(STORAGE_KEY) ?? null;
  } catch {
    raw = null;
  }
  state = parseStoredColors(raw);
  return state;
}

function write(next: Stored) {
  state = next;
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Colours still hold for this session if storage is full or blocked.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** The key of a branch card (a "workspace"): its project and its branch or worktree. */
export function cardColorKey(thread: {
  readonly environmentId: string;
  readonly projectId: string;
  readonly branch: string | null;
  readonly worktreePath: string | null;
}): string {
  const where = thread.worktreePath ? `worktree:${thread.worktreePath}` : `branch:${thread.branch ?? ""}`;
  return `${thread.environmentId}:${thread.projectId}:${where}`;
}

export const tabColorKey = (thread: { readonly environmentId: string; readonly id: string }) =>
  `${thread.environmentId}:${thread.id}`;

/** A tab shows its own colour, else its card's. */
export function resolveTabColor(
  stored: Stored,
  tabKey: string,
  cardKey: string,
): OctetColorId | null {
  return stored.tabs[tabKey] ?? stored.cards[cardKey] ?? null;
}

function withEntry(
  record: Readonly<Record<string, OctetColorId>>,
  key: string,
  color: OctetColorId | null,
): Record<string, OctetColorId> {
  const next = { ...record };
  if (color === null) delete next[key];
  else next[key] = color;
  return next;
}

export function setCardColor(key: string, color: OctetColorId | null) {
  const current = read();
  write({ ...current, cards: withEntry(current.cards, key, color) });
}

export function setTabColor(key: string, color: OctetColorId | null) {
  const current = read();
  write({ ...current, tabs: withEntry(current.tabs, key, color) });
}

export function useOctetColors(): Stored {
  return useSyncExternalStore(subscribe, read, read);
}

export const colorHex = (id: OctetColorId | null | undefined): string | null =>
  OCTET_COLORS.find((color) => color.id === id)?.hex ?? null;

/** A wash of the colour over whatever is behind it. */
export const colorWash = (hex: string, percent: number): string =>
  `color-mix(in srgb, ${hex} ${percent}%, transparent)`;

/** Menu id for a colour choice; "color:none" clears it. */
export const COLOR_MENU_PREFIX = "color:";

/** The "Color" submenu: a dot per colour, the current one checked. */
export function buildColorMenuItem<T extends string>(
  selected: OctetColorId | null,
  options: { readonly separatorBefore?: boolean } = {},
): ContextMenuItem<T> {
  return {
    id: "color" as T,
    label: "Color",
    icon: "palette",
    ...(options.separatorBefore ? { separatorBefore: true } : {}),
    children: [
      { id: `${COLOR_MENU_PREFIX}none` as T, label: "None", checked: selected === null },
      ...OCTET_COLORS.map((color) => ({
        id: `${COLOR_MENU_PREFIX}${color.id}` as T,
        label: color.name,
        swatch: color.hex,
        checked: selected === color.id,
      })),
    ],
  };
}

/** The colour a "color:…" menu id picks (null clears), or undefined for any other id. */
export function parseColorMenuId(id: string): OctetColorId | null | undefined {
  if (!id.startsWith(COLOR_MENU_PREFIX)) return undefined;
  const value = id.slice(COLOR_MENU_PREFIX.length);
  if (value === "none") return null;
  return isColorId(value) ? value : undefined;
}
