import { describe, expect, it } from "vite-plus/test";

import {
  formatFootprint,
  keepAwakeChipLabel,
  memoryChipTitle,
  shouldHoldAwake,
} from "./octetStatusBarUtilities.logic";

describe("shouldHoldAwake", () => {
  it("never holds with no agent working, or when off", () => {
    expect(shouldHoldAwake({ mode: "always", workingAgents: 0, onBattery: "false" })).toBe(false);
    expect(shouldHoldAwake({ mode: "off", workingAgents: 3, onBattery: "false" })).toBe(false);
  });
  it("holds on power in plugged_in mode, and on battery only in always mode", () => {
    expect(shouldHoldAwake({ mode: "plugged_in", workingAgents: 1, onBattery: "false" })).toBe(true);
    expect(shouldHoldAwake({ mode: "plugged_in", workingAgents: 1, onBattery: "unknown" })).toBe(true);
    expect(shouldHoldAwake({ mode: "plugged_in", workingAgents: 1, onBattery: "true" })).toBe(false);
    expect(shouldHoldAwake({ mode: "always", workingAgents: 1, onBattery: "true" })).toBe(true);
  });
});

describe("labels", () => {
  it("names each mode as native Octet does", () => {
    expect(["off", "plugged_in", "always"].map((m) => keepAwakeChipLabel(m as never))).toEqual([
      "Off",
      "Auto",
      "Agents",
    ]);
  });
  it("prints megabytes below a gigabyte and gigabytes above", () => {
    expect(formatFootprint(851_968_000)).toBe("812.5 MB");
    expect(formatFootprint(1_470_000_000)).toBe("1.37 GB");
  });
  it("titles the memory chip, with its terminal count", () => {
    expect(memoryChipTitle(null, 1)).toBe("Memory use is loading\n1 terminal open");
    expect(memoryChipTitle(1_048_576, 2)).toBe("Octet and its processes use 1.0 MB\n2 terminals open");
  });
});
