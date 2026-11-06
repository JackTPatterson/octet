// @effect-diagnostics nodeBuiltinImport:off
// @effect-diagnostics globalTimers:off
// @effect-diagnostics globalDate:off
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PtyAdapter from "@t3tools/shared/PtyAdapter";
import { ptyHostSocketPath, PtyHostClient } from "@t3tools/pty-host";

import * as ServerConfig from "../config.ts";
import * as PtyHostAdapter from "./PtyHostAdapter.ts";

// One adapter per "server run": a fresh layer is what a restarted server builds.
const adapterFor = (baseDir: string) =>
  Effect.runPromise(
    Effect.service(PtyAdapter.PtyAdapter).pipe(
      Effect.provide(
        PtyHostAdapter.layer.pipe(
          Layer.provide(ServerConfig.layerTest(process.cwd(), baseDir)),
          Layer.provide(NodeServices.layer),
        ),
      ),
    ),
  );

async function until(check: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe.skipIf(process.platform === "win32")("PtyHostAdapter", () => {
  it("hands a restarted server the terminal it left running, with its output", { timeout: 30_000 }, async () => {
    const baseDir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "pty-adapter-"));
    const spawnInput = {
      key: "thread-1:default",
      shell: "/bin/sh",
      cwd: NodeOS.tmpdir(),
      cols: 80,
      rows: 24,
      env: { PATH: process.env.PATH ?? "", TERM: "xterm-256color" },
    };

    const first = await adapterFor(baseDir);
    const pty = await Effect.runPromise(first.spawn(spawnInput));
    assert.strictEqual(pty.restored, undefined);
    let output = "";
    pty.onData((data) => (output += data));
    pty.write("echo first-run-$((6*7))\r");
    await until(() => output.includes("first-run-42"));

    // A new server process: new adapter, same key.
    const second = await adapterFor(baseDir);
    const again = await Effect.runPromise(second.spawn(spawnInput));
    assert.strictEqual(again.pid, pty.pid);
    assert.include(again.restored?.output ?? "", "first-run-42");

    let laterOutput = "";
    again.onData((data) => (laterOutput += data));
    again.write("echo still-here\r");
    await until(() => laterOutput.includes("still-here"));

    let exited = false;
    again.onExit(() => (exited = true));
    again.kill("SIGKILL");
    await until(() => exited);

    const host = await PtyHostClient.connect(ptyHostSocketPath(baseDir));
    const { pid } = await host.hello();
    host.close();
    try {
      process.kill(pid);
    } catch {}
  });
});
