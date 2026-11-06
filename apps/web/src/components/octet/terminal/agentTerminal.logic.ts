/** The thread terminal that runs the agent's CLI in terminal view. */
export const AGENT_TERMINAL_ID = "octet-agent";

/** Session ids go into a shell command line, so only plain ids are passed through. */
const SAFE_SESSION_ID = /^[A-Za-z0-9._:-]+$/;

/**
 * What to type into a fresh agent terminal: the provider's own CLI, resuming
 * the thread's provider session when there is one. Null for providers with no
 * CLI to start; the terminal then stays a plain shell.
 */
export function agentTerminalCommand(
  driverKind: string | null,
  providerSessionId: string | null,
): string | null {
  const session =
    providerSessionId !== null && SAFE_SESSION_ID.test(providerSessionId) ? providerSessionId : null;
  switch (driverKind) {
    case "claudeAgent":
      return session ? `claude --resume ${session}` : "claude";
    case "codex":
      return session ? `codex resume ${session}` : "codex";
    case "cursor":
      return "cursor-agent";
    case "opencode":
      return "opencode";
    default:
      return null;
  }
}
