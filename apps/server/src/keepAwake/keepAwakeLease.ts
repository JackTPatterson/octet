/** How long one assertion lasts, and how old it may get before the next replaces it. */
export const LEASE_SECONDS = 20;
export const RENEW_AFTER_MS = 10_000;

export type LeaseAction = "spawn" | "keep" | "release";

/**
 * What to do with the held assertion. The client asks every few seconds while it wants the
 * host awake, so an assertion is renewed once it is older than RENEW_AFTER_MS and otherwise
 * left to run out by itself (`caffeinate -t`) when the asks stop.
 */
export function leaseAction(input: {
  readonly hold: boolean;
  readonly supported: boolean;
  readonly nowMs: number;
  readonly spawnedAtMs: number | null;
}): LeaseAction {
  if (!input.hold || !input.supported) return "release";
  if (input.spawnedAtMs === null || input.nowMs - input.spawnedAtMs >= RENEW_AFTER_MS) return "spawn";
  return "keep";
}

/** Whether the assertion is still in force at `nowMs`. */
export function isHolding(spawnedAtMs: number | null, nowMs: number): boolean {
  return spawnedAtMs !== null && nowMs - spawnedAtMs < LEASE_SECONDS * 1000;
}
