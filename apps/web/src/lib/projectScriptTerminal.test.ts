import { describe, expect, it } from "vite-plus/test";

import { findReusableProjectScriptTerminal } from "./projectScriptTerminal";

describe("findReusableProjectScriptTerminal", () => {
  it.each([
    {
      name: "reuses the active idle drawer terminal",
      drawerTerminalIds: ["term-1", "term-2"],
      activeTerminalId: "term-2",
      runningTerminalIds: [],
      expected: "term-2",
    },
    {
      name: "falls back to another idle drawer terminal when the active one is busy",
      drawerTerminalIds: ["term-1", "term-2"],
      activeTerminalId: "term-1",
      runningTerminalIds: ["term-1"],
      expected: "term-2",
    },
    {
      name: "finds nothing when every drawer terminal is busy",
      drawerTerminalIds: ["term-1"],
      activeTerminalId: "term-1",
      runningTerminalIds: ["term-1"],
      expected: null,
    },
  ])("$name", ({ expected, ...input }) => {
    expect(findReusableProjectScriptTerminal(input)).toBe(expected);
  });
});
