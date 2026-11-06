import { describe, expect, it } from "vite-plus/test";

import {
  agentHasCli,
  cliIsLive,
  effectiveThreadView,
  mirrorNotice,
  otherThreadView,
  shouldRelaunchCli,
  STOP_CLI_KEYS,
} from "./threadFlip.logic";

const session = (status: string, hasRunningSubprocess: boolean) => ({
  state: { hasRunningSubprocess, summary: { status } },
});

describe("effectiveThreadView", () => {
  it("shows the terminal only for an agent that has a CLI", () => {
    expect(effectiveThreadView("terminal", "claudeAgent")).toBe("terminal");
    // A subagent's thread stays the chat.
    expect(effectiveThreadView("terminal", "claudeAgent", true)).toBe("chat");
    expect(effectiveThreadView("terminal", "codex")).toBe("terminal");
    expect(effectiveThreadView("terminal", "someApiOnlyAgent")).toBe("chat");
    expect(effectiveThreadView("terminal", null)).toBe("chat");
    expect(effectiveThreadView("chat", "someApiOnlyAgent")).toBe("chat");
  });
  it("knows which agents have a CLI, and flips", () => {
    expect(agentHasCli("opencode")).toBe(true);
    expect(agentHasCli("nope")).toBe(false);
    expect(otherThreadView("chat")).toBe("terminal");
    expect(otherThreadView("terminal")).toBe("chat");
  });
});

describe("cliIsLive", () => {
  it("is a running terminal whose shell has a child process", () => {
    expect(cliIsLive(session("running", true))).toBe(true);
    expect(cliIsLive(session("running", false))).toBe(false);
    expect(cliIsLive(session("exited", true))).toBe(false);
    expect(cliIsLive(null)).toBe(false);
  });
});

describe("shouldRelaunchCli", () => {
  it("types the command only into an idle shell, and not twice in a row", () => {
    expect(shouldRelaunchCli({ terminalRunning: true, cliLive: false, msSinceLastLaunch: null })).toBe(true);
    expect(shouldRelaunchCli({ terminalRunning: true, cliLive: true, msSinceLastLaunch: null })).toBe(false);
    expect(shouldRelaunchCli({ terminalRunning: false, cliLive: false, msSinceLastLaunch: null })).toBe(false);
    expect(shouldRelaunchCli({ terminalRunning: true, cliLive: false, msSinceLastLaunch: 1000 })).toBe(false);
    expect(shouldRelaunchCli({ terminalRunning: true, cliLive: false, msSinceLastLaunch: 9000 })).toBe(true);
  });
});

describe("hand-off details", () => {
  it("stops the CLI with an interrupt, then Ctrl+C twice", () => {
    expect(STOP_CLI_KEYS.map((key) => key.data)).toEqual(["\u001b", "\u0003", "\u0003"]);
  });
  it("words what the mirror brought in", () => {
    expect(mirrorNotice(0)).toBeNull();
    expect(mirrorNotice(1)).toBe("Added 1 message from the CLI to the chat.");
    expect(mirrorNotice(5)).toBe("Added 5 messages from the CLI to the chat.");
  });
});
