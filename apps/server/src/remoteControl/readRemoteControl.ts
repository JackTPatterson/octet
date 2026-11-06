import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";

import * as ProcessRunner from "../processRunner.ts";
import { foldRemoteControlLog } from "./remoteControlLog.ts";

/** How much of a session log's end to read; Remote Control records are near the end. */
const TAIL_BYTES = 4 * 1024 * 1024;

/** Claude names a folder's log directory by turning every other character into a dash. */
export const claudeProjectDirectoryName = (cwd: string): string => cwd.replace(/[^a-zA-Z0-9]/g, "-");

/** When a process started, or null where `ps` can't say (Windows) or the process is gone. */
const processStartMs = Effect.fn("RemoteControl.processStart")(function* (pid: number) {
  if ((yield* HostProcess.Platform) === "win32") return null;
  const runner = yield* ProcessRunner.ProcessRunner;
  const output = yield* runner
    .run({
      command: "ps",
      args: ["-o", "lstart=", "-p", String(pid)],
      // lstart prints in the local zone and in English whatever the locale.
      env: { LC_ALL: "C" },
      timeout: "3 seconds",
    })
    .pipe(Effect.orElseSucceed(() => null));
  const at = output && output.code === 0 ? Date.parse(output.stdout.trim()) : Number.NaN;
  return Number.isFinite(at) ? at : null;
});

/**
 * Whether the Claude Code CLI in `cwd` has Remote Control on. It reads the folder's most
 * recently written session log; with `pid`, only one written since that process started.
 * Never fails: anything unreadable means off.
 */
export const readRemoteControl = Effect.fn("RemoteControl.read")(function* (input: {
  readonly cwd: string;
  readonly pid?: number | undefined;
}) {
  const off = { active: false, url: null } as const;
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const environment = yield* HostProcess.Environment;
  const home = yield* HostProcess.HomeDirectory;
  const configDir = environment.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
  const directory = path.join(configDir, "projects", claudeProjectDirectoryName(input.cwd));
  const sinceMs = input.pid === undefined ? null : yield* processStartMs(input.pid);

  return yield* Effect.gen(function* () {
    let newest: { file: string; mtime: number } | null = null;
    for (const name of yield* fileSystem.readDirectory(directory)) {
      if (!name.endsWith(".jsonl")) continue;
      const file = path.join(directory, name);
      const info = yield* fileSystem.stat(file);
      const mtime = info.mtime._tag === "Some" ? info.mtime.value.getTime() : 0;
      if (info.type === "File" && (newest === null || mtime > newest.mtime)) newest = { file, mtime };
    }
    // A log not written since the process started is an earlier run's.
    if (!newest || (sinceMs !== null && newest.mtime < sinceMs)) return off;

    const handle = yield* fileSystem.open(newest.file, { flag: "r" });
    const info = yield* handle.stat;
    const size = Number(info.size);
    const start = Math.max(0, size - TAIL_BYTES);
    yield* handle.seek(BigInt(start), "start");
    const bytes = yield* handle.readAlloc(size - start);
    let text = new TextDecoder().decode(bytes.pipe((o) => (o._tag === "Some" ? o.value : new Uint8Array())));
    // A tail read starts mid-line; drop the partial first line.
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
    return foldRemoteControlLog(text, sinceMs);
  }).pipe(Effect.scoped, Effect.orElseSucceed(() => off));
});
