import type { LimitPool } from "@t3tools/shared/usageLimits";

/** The window closest to its limit: the one worth knowing at a glance. */
export function tightestWindow(pool: LimitPool) {
  return pool.windows.reduce<LimitPool["windows"][number] | null>(
    (worst, window) => (worst === null || window.usedPercent > worst.usedPercent ? window : worst),
    null,
  );
}

export type RingTone = "normal" | "warn" | "critical";

/** Quiet until a limit is close: amber from 75% used, red from 90%. */
export function ringTone(usedPercent: number): RingTone {
  if (usedPercent >= 90) return "critical";
  if (usedPercent >= 75) return "warn";
  return "normal";
}

/** The arc's share of the ring: never empty, so a fresh window still shows a nub. */
export function ringFraction(usedPercent: number): number {
  return Math.max(0.02, Math.min(1, usedPercent / 100));
}
