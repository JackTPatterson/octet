import {
  TERMINAL_RUN_COMMAND_MAX_OUTPUT_BYTES,
  TERMINAL_RUN_COMMAND_TIMEOUT_MS,
  TerminalRunCommandError,
  type TerminalRunCommandInput,
  type TerminalRunCommandResult,
} from "@t3tools/contracts";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";

import * as ProcessRunner from "../processRunner.ts";

const POSIX_SHELLS: ReadonlySet<string> = new Set(["sh", "bash", "zsh", "dash", "ksh"]);

// CSI and OSC sequences: color, cursor movement, titles, hyperlinks.
const ANSI_SEQUENCE = /\u001b\[[0-?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g;

export function stripTerminalEscapes(text: string): string {
  return text.replace(ANSI_SEQUENCE, "").replace(/\r\n?/g, "\n");
}

/**
 * The user's shell where it can merge stderr into stdout in order; `/bin/sh` for the others
 * (fish, nushell), whose syntax for that differs. Windows runs `cmd.exe`.
 */
export function runCommandSpawn(
  command: string,
  platform: NodeJS.Platform,
  env: NodeJS.ProcessEnv,
): { readonly command: string; readonly args: ReadonlyArray<string> } {
  if (platform === "win32") {
    return { command: env.ComSpec ?? "cmd.exe", args: ["/d", "/s", "/c", `${command} 2>&1`] };
  }
  const userShell = env.SHELL;
  const shell =
    userShell !== undefined && POSIX_SHELLS.has(userShell.split("/").at(-1) ?? "")
      ? userShell
      : "/bin/sh";
  return { command: shell, args: ["-lc", `exec 2>&1\n${command}`] };
}

/** Runs a composer `!command` once, without a terminal, and returns what it printed. */
export const runTerminalCommand = Effect.fn("terminal.runCommand")(function* (
  input: TerminalRunCommandInput,
) {
  const runner = yield* ProcessRunner.ProcessRunner;
  const env = yield* HostProcess.Environment;
  const spawn = runCommandSpawn(input.command, yield* HostProcess.Platform, env);
  // Kept here as well: a timed-out run discards the runner's own buffers.
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  let truncated = false;
  const result = yield* runner
    .run({
      command: spawn.command,
      args: spawn.args,
      cwd: input.cwd,
      env: { ...env, TERM: "dumb", PAGER: "cat", GIT_PAGER: "cat" },
      // Closed, so a command that asks for input ends instead of waiting out the timeout.
      stdin: "",
      timeout: TERMINAL_RUN_COMMAND_TIMEOUT_MS,
      timeoutBehavior: "timedOutResult",
      maxOutputBytes: TERMINAL_RUN_COMMAND_MAX_OUTPUT_BYTES,
      outputMode: "truncate",
      onStdoutChunk: (chunk) => {
        const room = TERMINAL_RUN_COMMAND_MAX_OUTPUT_BYTES - bytes;
        if (chunk.byteLength > room) truncated = true;
        if (room <= 0) return;
        const kept = chunk.byteLength > room ? chunk.subarray(0, room) : chunk;
        chunks.push(kept);
        bytes += kept.byteLength;
      },
    })
    .pipe(
      Effect.mapError(
        (cause) => new TerminalRunCommandError({ cwd: input.cwd, detail: cause.message }),
      ),
    );
  const stdout = Buffer.concat(chunks, bytes).toString("utf8");
  const output = [stdout, result.stderr].filter((part) => part.length > 0).join("\n");
  return {
    output: stripTerminalEscapes(output),
    exitCode: result.code === null ? null : Number(result.code),
    timedOut: result.timedOut,
    truncated: truncated || result.stdoutTruncated || result.stderrTruncated,
  } satisfies TerminalRunCommandResult;
});
