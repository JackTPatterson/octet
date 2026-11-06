import { describe, expect, it } from "vite-plus/test";

import { ringFraction, ringTone, tightestWindow } from "./usageRings.logic";

describe("usage rings", () => {
  it("picks the window closest to its limit", () => {
    const pool = { windows: [{ usedPercent: 10 }, { usedPercent: 59 }, { usedPercent: 30 }] };
    expect(tightestWindow(pool as never)?.usedPercent).toBe(59);
    expect(tightestWindow({ windows: [] } as never)).toBeNull();
  });
  it("warns as a limit nears", () => {
    expect(ringTone(59)).toBe("normal");
    expect(ringTone(75)).toBe("warn");
    expect(ringTone(90)).toBe("critical");
  });
  it("keeps a nub of arc for a fresh window", () => {
    expect(ringFraction(0)).toBe(0.02);
    expect(ringFraction(59)).toBeCloseTo(0.59);
    expect(ringFraction(140)).toBe(1);
  });
});
