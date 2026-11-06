import { describe, expect, it } from "vite-plus/test";

import {
  agentChipState,
  agentChipText,
  changesChip,
  changesChipTitle,
  ciChip,
  ciChipText,
  directoryChipLabel,
  portsChip,
  portsChipText,
  worktreeChipLabel,
} from "./octetStatusBar.logic";

describe("agent chip", () => {
  it("maps T3's status labels to what Octet says", () => {
    expect(agentChipState(null)).toBe("idle");
    expect(agentChipState({ label: "Completed" })).toBe("idle");
    expect(agentChipState({ label: "Working" })).toBe("working");
    expect(agentChipState({ label: "Pending Approval" })).toBe("needs-you");
    expect(agentChipState({ label: "Awaiting Input" })).toBe("needs-you");
    expect(agentChipState({ label: "Failed" })).toBe("failed");
  });

  it("reads like the native footer", () => {
    expect(agentChipText("Claude Code", "idle")).toBe("Claude Code idle");
    expect(agentChipText("Codex", "needs-you")).toBe("Codex needs you");
  });
});

describe("changes chip", () => {
  it("is absent with no changed files", () => {
    expect(changesChip(null)).toBeNull();
    expect(changesChip({ files: [], insertions: 0, deletions: 0 })).toBeNull();
  });

  it("counts files and lines", () => {
    const chip = changesChip({ files: [{}, {}, {}, {}, {}], insertions: 155, deletions: 62 });
    expect(chip).toEqual({ files: 5, insertions: 155, deletions: 62 });
    expect(changesChipTitle(chip!)).toBe(
      "5 changed files in the working tree, 155 lines added and 62 removed",
    );
  });
});

describe("CI chip", () => {
  it("is absent with no checks", () => {
    expect(ciChip(null)).toBeNull();
    expect(ciChip([])).toBeNull();
  });

  it("is red when anything failed, and counts them", () => {
    const chip = ciChip([{ status: "success" }, { status: "failure" }, { status: "pending" }]);
    expect(chip?.state).toBe("failed");
    expect(ciChipText(chip!)).toBe("CI 1 failed");
  });

  it("shows progress while checks run", () => {
    const chip = ciChip([{ status: "success" }, { status: "pending" }, { status: "pending" }]);
    expect(chip?.state).toBe("running");
    expect(ciChipText(chip!)).toBe("CI 1/3");
  });

  it("is quiet once everything passed", () => {
    const chip = ciChip([{ status: "success" }, { status: "success" }]);
    expect(chip?.state).toBe("passed");
    expect(ciChipText(chip!)).toBe("CI");
  });
});

describe("directory and worktree chips", () => {
  it("keeps the last two folders", () => {
    expect(directoryChipLabel("/Users/jack/Developer/apps/octet-next")).toBe("apps/octet-next");
    expect(directoryChipLabel("C:\\work\\app")).toBe("work/app");
    expect(directoryChipLabel("/solo")).toBe("solo");
    expect(directoryChipLabel("/")).toBe("/");
  });

  it("names a worktree by its folder, and is absent without one", () => {
    expect(worktreeChipLabel("/Users/jack/.octet-next/worktrees/feat-sidebar")).toBe("feat-sidebar");
    expect(worktreeChipLabel(null)).toBeNull();
    expect(worktreeChipLabel("")).toBeNull();
  });
});

describe("ports chip", () => {
  it("is absent with no servers", () => {
    expect(portsChip([])).toBeNull();
  });

  it("shows the first server and how many more", () => {
    expect(portsChipText(portsChip([{ port: 3000 }])!)).toBe("localhost:3000");
    expect(portsChipText(portsChip([{ port: 3000 }, { port: 5173 }, { port: 8080 }])!)).toBe(
      "localhost:3000 +2",
    );
  });
});
