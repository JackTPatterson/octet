import { describe, expect, it } from "vite-plus/test";

import {
  MCP_COMMAND,
  isMcpCommand,
  providerOffersMcpCommand,
  withMcpCommand,
} from "./mcpCommand.ts";

describe("mcpCommand", () => {
  it("recognises /mcp on its own, whatever the case or spacing", () => {
    expect(isMcpCommand("/mcp")).toBe(true);
    expect(isMcpCommand("  /MCP \n")).toBe(true);
    expect(isMcpCommand("/mcp list")).toBe(false);
    expect(isMcpCommand("tell me about /mcp")).toBe(false);
  });

  it("offers it for Claude and Codex, replacing a provider's own /mcp", () => {
    expect(providerOffersMcpCommand("claudeAgent" as never)).toBe(true);
    expect(providerOffersMcpCommand("codex" as never)).toBe(true);
    expect(providerOffersMcpCommand("opencode" as never)).toBe(false);
    const commands = withMcpCommand([
      { name: "mcp", description: "Claude's interactive /mcp" },
      { name: "review", description: "Review" },
    ]);
    expect(commands).toEqual([{ name: "review", description: "Review" }, MCP_COMMAND]);
  });
});
