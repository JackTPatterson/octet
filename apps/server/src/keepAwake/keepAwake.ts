import { spawn, type ChildProcess } from "node:child_process";

import * as Effect from "effect/Effect";

import { isHolding, LEASE_SECONDS, leaseAction } from "./keepAwakeLease.ts";

const supported = process.platform === "darwin";

let current: ChildProcess | null = null;
let spawnedAtMs: number | null = null;

const release = () => {
  current?.kill();
  current = null;
  spawnedAtMs = null;
};

/**
 * Holds the host awake for one more lease, or lets go. macOS only: `caffeinate -i` stops
 * idle sleep and leaves the display free to sleep; `-t` makes the assertion end on its own
 * if the client stops asking, and the old one is killed when its replacement starts.
 */
export const holdAwake = (hold: boolean) =>
  Effect.sync(() => {
    const nowMs = Date.now();
    const action = leaseAction({ hold, supported, nowMs, spawnedAtMs });
    if (action === "release") release();
    if (action === "spawn") {
      const previous = current;
      const next = spawn("caffeinate", ["-i", "-t", String(LEASE_SECONDS)], { stdio: "ignore" });
      next.on("error", () => {
        if (current === next) release();
      });
      next.unref();
      current = next;
      spawnedAtMs = nowMs;
      previous?.kill();
    }
    return { supported, holding: isHolding(spawnedAtMs, nowMs) };
  });

process.once("exit", () => current?.kill());
