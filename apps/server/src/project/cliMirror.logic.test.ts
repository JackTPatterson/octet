import { describe, expect, it } from "vite-plus/test";

import { mirrorMessageKey, planCliMirror } from "./cliMirror.logic.ts";

const log = (role: "user" | "assistant", text: string, at = "2026-11-05T10:00:00Z") => ({
  role,
  text,
  createdAt: at,
});

describe("planCliMirror", () => {
  it("adds only what the thread lacks, in order", () => {
    const missing = planCliMirror(
      [
        { role: "user", text: "Fix the bug" },
        { role: "assistant", text: "Fixed it." },
      ],
      [
        log("user", "Fix the bug"),
        log("assistant", "Fixed it."),
        log("user", "Now add a test"),
        log("assistant", "Added."),
      ],
    );
    expect(missing.map((m) => m.text)).toEqual(["Now add a test", "Added."]);
  });
  it("ignores wrapping and whitespace when matching", () => {
    expect(
      planCliMirror([{ role: "user", text: "Fix  the\nbug " }], [log("user", "Fix the bug")]),
    ).toEqual([]);
  });
  it("tells roles apart", () => {
    expect(planCliMirror([{ role: "user", text: "ok" }], [log("assistant", "ok")])).toHaveLength(1);
  });
  it("counts repeats: one existing 'yes' covers one logged 'yes'", () => {
    const missing = planCliMirror(
      [{ role: "user", text: "yes" }],
      [log("user", "yes", "2026-11-05T10:00:00Z"), log("user", "yes", "2026-11-05T10:05:00Z")],
    );
    expect(missing).toHaveLength(1);
    expect(missing[0]!.createdAt).toBe("2026-11-05T10:05:00Z");
  });
  it("skips empty messages, and adds everything to an empty thread", () => {
    expect(planCliMirror([], [log("user", "  "), log("user", "hi")]).map((m) => m.text)).toEqual(["hi"]);
  });
  it("is nothing to do when already mirrored", () => {
    const transcript = [log("user", "a"), log("assistant", "b")];
    expect(planCliMirror(transcript, transcript)).toEqual([]);
  });
});

describe("mirrorMessageKey", () => {
  it("is stable for a message and differs by time, role and repeat", () => {
    const message = log("user", "yes", "2026-11-05T10:00:00Z");
    const key = mirrorMessageKey({ sessionId: "abcdef12-3456", message, occurrence: 0 });
    expect(key).toBe(mirrorMessageKey({ sessionId: "abcdef12-3456", message, occurrence: 0 }));
    expect(key).not.toBe(mirrorMessageKey({ sessionId: "abcdef12-3456", message, occurrence: 1 }));
    expect(key).not.toBe(
      mirrorMessageKey({ sessionId: "abcdef12-3456", message: { ...message, role: "assistant" }, occurrence: 0 }),
    );
  });
});
