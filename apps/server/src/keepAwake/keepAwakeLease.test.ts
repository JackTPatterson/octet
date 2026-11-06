import { describe, expect, it } from "vite-plus/test";

import { isHolding, leaseAction, RENEW_AFTER_MS } from "./keepAwakeLease.ts";

const base = { supported: true, nowMs: 100_000 };

describe("leaseAction", () => {
  it("releases when not asked to hold, or where it cannot", () => {
    expect(leaseAction({ ...base, hold: false, spawnedAtMs: 99_000 })).toBe("release");
    expect(leaseAction({ ...base, hold: true, supported: false, spawnedAtMs: null })).toBe("release");
  });
  it("starts an assertion when none is held", () => {
    expect(leaseAction({ ...base, hold: true, spawnedAtMs: null })).toBe("spawn");
  });
  it("leaves a young assertion alone and renews an old one", () => {
    expect(leaseAction({ ...base, hold: true, spawnedAtMs: base.nowMs - (RENEW_AFTER_MS - 1) })).toBe("keep");
    expect(leaseAction({ ...base, hold: true, spawnedAtMs: base.nowMs - RENEW_AFTER_MS })).toBe("spawn");
  });
});

describe("isHolding", () => {
  it("holds until the lease runs out", () => {
    expect(isHolding(null, 1000)).toBe(false);
    expect(isHolding(1000, 1000 + 19_999)).toBe(true);
    expect(isHolding(1000, 1000 + 20_000)).toBe(false);
  });
});
