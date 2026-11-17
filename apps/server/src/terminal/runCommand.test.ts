import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";

import * as ProcessRunner from "../processRunner.ts";
import { runCommandSpawn, runTerminalCommand, stripTerminalEscapes } from "./runCommand.ts";

describe("runCommandSpawn", () => {
  it("uses a POSIX login shell that merges stderr, and /bin/sh in place of others", () => {
    expect(runCommandSpawn("ls", "darwin", { SHELL: "/bin/zsh" })).toEqual({
      command: "/bin/zsh",
      args: ["-lc", "exec 2>&1\nls"],
    });
    expect(runCommandSpawn("ls", "linux", { SHELL: "/usr/bin/fish" }).command).toBe("/bin/sh");
    expect(runCommandSpawn("ls", "linux", {}).command).toBe("/bin/sh");
    expect(runCommandSpawn("dir", "win32", { ComSpec: "C:\\Windows\\cmd.exe" })).toEqual({
      command: "C:\\Windows\\cmd.exe",
      args: ["/d", "/s", "/c", "dir 2>&1"],
    });
  });
});

describe("stripTerminalEscapes", () => {
  it("drops color and title sequences and normalizes line endings", () => {
    expect(stripTerminalEscapes("\u001b[31mred\u001b[0m\r\n\u001b]0;title\u0007done\r")).toBe(
      "red\ndone\n",
    );
  });
});

describe.skipIf(HostProcess.Platform.defaultValue() === "win32")("runTerminalCommand", () => {
  const run = (command: string) =>
    runTerminalCommand({ cwd: HostProcess.WorkingDirectory.defaultValue(), command }).pipe(
      Effect.provide(ProcessRunner.layer),
      Effect.provide(NodeServices.layer),
    );

  it.live("returns stdout and stderr in order, without color, with the exit code", () =>
    Effect.gen(function* () {
      const result = yield* run("printf 'one\\n'; printf '\\033[31mtwo\\033[0m\\n' >&2; exit 3");
      expect(result.output).toContain("one\ntwo\n");
      expect(result.output).not.toContain("\u001b");
      expect(result.exitCode).toBe(3);
      expect(result.timedOut).toBe(false);
      expect(result.truncated).toBe(false);
    }),
  );

  it.live("closes stdin so a command that reads input finishes", () =>
    Effect.gen(function* () {
      const result = yield* run('read line; echo "got:[$line]"');
      expect(result.output).toContain("got:[]");
    }),
  );
});
