// @effect-diagnostics nodeBuiltinImport:off
// @effect-diagnostics globalTimers:off
// @effect-diagnostics globalDate:off
// Entry point of the detached pty host: `node main.ts --socket <path>`.
import * as NodeFS from "node:fs";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";

import { startPtyHost, type HostPty } from "./host.ts";
import type { SpawnRequest } from "./protocol.ts";

type NodePty = typeof import("node-pty");

const require = NodeModule.createRequire(import.meta.url);

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

const socketPath = argument("--socket");
if (!socketPath) {
  process.stderr.write("usage: pty-host --socket <path>\n");
  process.exit(2);
}

const nodePty = require("node-pty") as NodePty;

// Package managers can drop the execute bit from node-pty's spawn helper
// (the server's node-pty adapter does the same repair).
if (process.platform !== "win32") {
  const packageDir = NodePath.dirname(require.resolve("node-pty/package.json"));
  for (const candidate of [
    NodePath.join(packageDir, "build", "Release", "spawn-helper"),
    NodePath.join(packageDir, "prebuilds", `${process.platform}-${process.arch}`, "spawn-helper"),
  ]) {
    try {
      NodeFS.chmodSync(candidate, 0o755);
    } catch {}
  }
}

/** ConPTY reports the pid only once its data pipe is ready. */
async function windowsPid(pty: HostPty): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!(Number.isInteger(pty.pid) && pty.pid > 0)) {
    if (Date.now() > deadline) throw new Error("Windows PTY did not report a pid");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

const spawnPty = async (request: SpawnRequest): Promise<HostPty> => {
  // ConPTY ignores node-pty's `name` for TERM.
  const env =
    process.platform === "win32" && request.env.TERM === undefined
      ? { ...request.env, TERM: "xterm-256color" }
      : { ...request.env };
  const pty = nodePty.spawn(request.shell, [...(request.args ?? [])], {
    name: "xterm-256color",
    cwd: request.cwd,
    cols: request.cols,
    rows: request.rows,
    env,
  });
  if (process.platform === "win32") {
    try {
      await windowsPid(pty);
    } catch (error) {
      pty.kill();
      throw error;
    }
  }
  return pty;
};

const host = startPtyHost({
  socketPath,
  spawnPty,
  onIdleExit: () => process.exit(0),
});

host.listening.catch((error: unknown) => {
  // Another host won the race for this socket; it serves the shells.
  process.stderr.write(`pty-host: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});

// Terminals must survive the parent going away.
process.on("SIGHUP", () => {});
