import { describe, expect, it } from "vite-plus/test";

import { foldRemoteControlLog } from "./remoteControlLog.ts";

const bridge = (timestamp: string, url = "https://claude.ai/code/session_1") =>
  JSON.stringify({ type: "system", subtype: "bridge_status", url, timestamp });
const command = (timestamp: string, name = "remote-control") =>
  JSON.stringify({ type: "system", subtype: "local_command", commandRun: { command: name }, timestamp });

describe("foldRemoteControlLog", () => {
  it("is off with no records, and ignores other lines", () => {
    expect(foldRemoteControlLog('{"type":"user"}\nnot json\n', null)).toEqual({ active: false, url: null });
  });
  it("is on after a bridge_status, with its link", () => {
    expect(foldRemoteControlLog(bridge("2026-11-05T10:00:00Z"), null)).toEqual({
      active: true,
      url: "https://claude.ai/code/session_1",
    });
  });
  it("turns on when the command is followed by its bridge_status", () => {
    const log = [bridge("2026-11-05T10:00:00Z"), command("2026-11-05T10:05:00Z"), command("2026-11-05T10:05:01Z", "rc")];
    // Toggled twice with no reconnect: off.
    expect(foldRemoteControlLog(log.join("\n"), null).active).toBe(false);
    // Toggled once, then reconnected: on.
    expect(
      foldRemoteControlLog([...log.slice(0, 2), bridge("2026-11-05T10:05:02Z")].join("\n"), null).active,
    ).toBe(true);
  });
  it("ignores records from before the process started", () => {
    const since = Date.parse("2026-11-05T11:00:00Z");
    expect(foldRemoteControlLog(bridge("2026-11-05T10:00:00Z"), since).active).toBe(false);
    expect(foldRemoteControlLog(bridge("2026-11-05T11:30:00Z"), since).active).toBe(true);
  });
});
