import { describe, expect, it } from "vite-plus/test";

import { agentTerminalCommand } from "./agentTerminal.logic";

describe("agentTerminalCommand", () => {
  it("starts the provider's CLI, resuming the thread's session", () => {
    expect(agentTerminalCommand("claudeAgent", null)).toBe("claude");
    expect(agentTerminalCommand("claudeAgent", "6f1c2a90-4d3e")).toBe("claude --resume 6f1c2a90-4d3e");
    expect(agentTerminalCommand("codex", "thr_123")).toBe("codex resume thr_123");
    expect(agentTerminalCommand("cursor", "x")).toBe("cursor-agent");
  });

  it("never puts an unsafe session id on the command line", () => {
    expect(agentTerminalCommand("claudeAgent", "abc; rm -rf ~")).toBe("claude");
    expect(agentTerminalCommand("codex", "$(whoami)")).toBe("codex");
  });

  it("leaves a plain shell for providers without a CLI", () => {
    expect(agentTerminalCommand("antigravity", null)).toBeNull();
    expect(agentTerminalCommand(null, null)).toBeNull();
  });
});
