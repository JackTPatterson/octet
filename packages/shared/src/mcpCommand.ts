import type { ServerProvider, ServerProviderSlashCommand } from "@t3tools/contracts";

/** Octet's own `/mcp`: the agent CLIs' versions are interactive and don't run headless. */
export const MCP_COMMAND = {
  name: "mcp",
  description: "Show and manage this agent's MCP servers",
} satisfies ServerProviderSlashCommand;

/** Providers whose live sessions report their MCP servers. */
const MCP_COMMAND_DRIVERS: ReadonlySet<string> = new Set(["claudeAgent", "codex"]);

export function providerOffersMcpCommand(driver: ServerProvider["driver"] | undefined): boolean {
  return driver !== undefined && MCP_COMMAND_DRIVERS.has(driver);
}

export function isMcpCommand(prompt: string): boolean {
  return prompt.trim().toLowerCase() === "/mcp";
}

/** The provider's commands with Octet's `/mcp` in place of any of its own. */
export function withMcpCommand(
  commands: ServerProvider["slashCommands"],
): ServerProvider["slashCommands"] {
  return [...commands.filter((command) => command.name !== MCP_COMMAND.name), MCP_COMMAND];
}
