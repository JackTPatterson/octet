// @effect-diagnostics nodeBuiltinImport:off
// @effect-diagnostics globalTimers:off
// @effect-diagnostics globalDate:off
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { assert, describe, it } from "@effect/vitest";

import { ensurePtyHost, PtyHostClient } from "./client.ts";
import { startPtyHost, type HostPty, type PtyHost } from "./host.ts";
import { ptyHostSocketPath, type SpawnRequest } from "./protocol.ts";
import { RingBuffer } from "./ringBuffer.ts";

class FakePty implements HostPty {
  static nextPid = 1000;
  readonly pid = FakePty.nextPid++;
  readonly written: Array<string> = [];
  readonly sizes: Array<[number, number]> = [];
  killedWith: string | undefined;
  private dataCallbacks: Array<(data: string) => void> = [];
  private exitCallbacks: Array<(event: { exitCode: number; signal?: number | undefined }) => void> = [];

  write(data: string) {
    this.written.push(data);
  }
  resize(cols: number, rows: number) {
    this.sizes.push([cols, rows]);
  }
  kill(signal?: string) {
    this.killedWith = signal ?? "SIGHUP";
    this.exit(0, 1);
  }
  onData(callback: (data: string) => void) {
    this.dataCallbacks.push(callback);
  }
  onExit(callback: (event: { exitCode: number; signal?: number | undefined }) => void) {
    this.exitCallbacks.push(callback);
  }
  print(data: string) {
    for (const callback of this.dataCallbacks) callback(data);
  }
  exit(exitCode: number, signal?: number) {
    for (const callback of this.exitCallbacks) callback({ exitCode, signal });
  }
}

const tempDir = () => NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "pty-host-"));
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(check: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await wait(10);
  }
}

const request = (key: string, overrides: Partial<SpawnRequest> = {}): SpawnRequest => ({
  key,
  shell: "/bin/sh",
  cwd: "/",
  cols: 80,
  rows: 24,
  env: {},
  ...overrides,
});

const collect = () => {
  const chunks: Array<Buffer> = [];
  const exits: Array<{ exitCode: number; signal: number | null }> = [];
  return {
    listener: { onData: (data: Buffer) => chunks.push(data), onExit: (event: { exitCode: number; signal: number | null }) => exits.push(event) },
    text: () => Buffer.concat(chunks).toString("utf8"),
    exits,
  };
};

async function withFakeHost(
  run: (context: { socketPath: string; ptys: Array<FakePty>; host: PtyHost }) => Promise<void>,
  options: { exitRetainMs?: number; idleExitMs?: number; onIdleExit?: () => void; bufferBytes?: number } = {},
) {
  const socketPath = ptyHostSocketPath(tempDir());
  const ptys: Array<FakePty> = [];
  const host = startPtyHost({
    socketPath,
    spawnPty: () => {
      const pty = new FakePty();
      ptys.push(pty);
      return pty;
    },
    ...options,
  });
  await host.listening;
  try {
    await run({ socketPath, ptys, host });
  } finally {
    await host.close();
  }
}

describe("RingBuffer", () => {
  it("keeps only the newest bytes", () => {
    const buffer = new RingBuffer(8);
    buffer.append(Buffer.from("abcdef"));
    buffer.append(Buffer.from("ghij"));
    assert.strictEqual(buffer.contents().toString(), "cdefghij");
    buffer.append(Buffer.from("0123456789"));
    assert.strictEqual(buffer.contents().toString(), "23456789");
    assert.strictEqual(buffer.length, 8);
  });
});

describe("pty host", () => {
  it("spawns, streams output, and forwards input and resizes", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      const out = collect();
      const result = await client.spawn(request("a"), out.listener);
      assert.strictEqual(result.reattached, false);
      ptys[0]!.print("hello");
      await until(() => out.text() === "hello");
      await client.write("a", "ls\r");
      await client.resize("a", 120, 40);
      assert.deepStrictEqual(ptys[0]!.written, ["ls\r"]);
      assert.deepStrictEqual(ptys[0]!.sizes, [[120, 40]]);
      client.close();
    });
  });

  it("keeps a pty running after its client disconnects, and replays its output on reattach", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const first = await PtyHostClient.connect(socketPath);
      await first.spawn(request("a"), collect().listener);
      ptys[0]!.print("before ");
      first.close();
      await wait(20);
      // Output while nobody is attached still lands in the buffer.
      ptys[0]!.print("while away");

      const second = await PtyHostClient.connect(socketPath);
      const out = collect();
      const result = await second.spawn(request("a"), out.listener);
      assert.strictEqual(result.reattached, true);
      assert.strictEqual(result.pid, ptys[0]!.pid);
      assert.strictEqual(Buffer.from(result.buffer, "base64").toString(), "before while away");
      assert.strictEqual(ptys.length, 1);
      ptys[0]!.print("!");
      await until(() => out.text() === "!");
      second.close();
    });
  });

  it("resizes a live pty to the size the reattaching client asks for", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      await client.spawn(request("a"), collect().listener);
      await client.spawn(request("a", { cols: 100, rows: 30 }), collect().listener);
      assert.deepStrictEqual(ptys[0]!.sizes, [[100, 30]]);
      client.close();
    });
  });

  it("reports exit status, and starts a new pty when the key is spawned again", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      const out = collect();
      await client.spawn(request("a"), out.listener);
      ptys[0]!.exit(3);
      await until(() => out.exits.length === 1);
      assert.deepStrictEqual(out.exits[0], { exitCode: 3, signal: null });
      assert.deepStrictEqual((await client.list())[0]?.exited, { exitCode: 3, signal: null });

      // Reopening a finished terminal gives a fresh shell, not the dead one.
      const fresh = await client.spawn(request("a"), collect().listener);
      assert.strictEqual(fresh.reattached, false);
      assert.strictEqual(ptys.length, 2);
      client.close();
    });
  });

  it("replaces a running pty when asked to, for a terminal restart", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      await client.spawn(request("a"), collect().listener);
      const out = collect();
      const replaced = await client.spawn(request("a", { replace: true }), out.listener);
      assert.strictEqual(replaced.reattached, false);
      await wait(20);
      assert.deepStrictEqual(out.exits, [], "the old pty's exit is not the new one's");
      assert.strictEqual(ptys.length, 2);
      assert.strictEqual(ptys[0]!.killedWith, "SIGHUP");
      assert.strictEqual(replaced.pid, ptys[1]!.pid);
      client.close();
    });
  });

  it("drops an exited pty after the retention window", async () => {
    await withFakeHost(
      async ({ socketPath, ptys }) => {
        const client = await PtyHostClient.connect(socketPath);
        await client.spawn(request("a"), collect().listener);
        ptys[0]!.exit(0);
        await until(() => ptys.length === 1);
        await wait(80);
        assert.deepStrictEqual(await client.list(), []);
        client.close();
      },
      { exitRetainMs: 30 },
    );
  });

  it("kills a pty on request and lists what it runs", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      await client.spawn(request("a"), collect().listener);
      await client.spawn(request("b"), collect().listener);
      assert.deepStrictEqual(
        (await client.list()).map((pty) => pty.key),
        ["a", "b"],
      );
      await client.kill("a", "SIGTERM");
      assert.strictEqual(ptys[0]!.killedWith, "SIGTERM");
      const listed = await client.list();
      assert.deepStrictEqual(listed.find((pty) => pty.key === "a")?.exited, { exitCode: 0, signal: 1 });
      client.close();
    });
  });

  it("stops sending a detached pty's output to that client", async () => {
    await withFakeHost(async ({ socketPath, ptys }) => {
      const client = await PtyHostClient.connect(socketPath);
      const out = collect();
      await client.spawn(request("a"), out.listener);
      await client.detach("a");
      ptys[0]!.print("ignored");
      await wait(30);
      assert.strictEqual(out.text(), "");
      client.close();
    });
  });

  it("answers an unknown key with an error", async () => {
    await withFakeHost(async ({ socketPath }) => {
      const client = await PtyHostClient.connect(socketPath);
      const error = await client.write("missing", "x").catch((caught: unknown) => caught);
      assert.instanceOf(error, Error);
      assert.match((error as Error).message, /No pty with key missing/);
      client.close();
    });
  });

  it("exits on its own only when it has no ptys and no clients", async () => {
    let exited = false;
    await withFakeHost(
      async ({ socketPath, ptys }) => {
        const client = await PtyHostClient.connect(socketPath);
        await client.spawn(request("a"), collect().listener);
        client.close();
        await wait(80);
        assert.strictEqual(exited, false, "a live pty keeps the host up");
        ptys[0]!.exit(0);
        await until(() => exited);
      },
      { idleExitMs: 30, exitRetainMs: 10, onIdleExit: () => (exited = true) },
    );
  });
});

describe("pty host startup", () => {
  it("refuses to take over a socket a live host answers on, but replaces a stale one", async () => {
    await withFakeHost(async ({ socketPath }) => {
      const rival = startPtyHost({ socketPath, spawnPty: () => new FakePty() });
      const error = await rival.listening.catch((caught: unknown) => caught);
      assert.instanceOf(error, Error);
      assert.match((error as Error).message, /already running/);
      await rival.close();
      // The first host still serves.
      const client = await PtyHostClient.connect(socketPath);
      client.close();
    });
    if (process.platform !== "win32") {
      const socketPath = ptyHostSocketPath(tempDir());
      NodeFS.writeFileSync(socketPath, "");
      const host = startPtyHost({ socketPath, spawnPty: () => new FakePty() });
      await host.listening;
      const client = await PtyHostClient.connect(socketPath);
      client.close();
      await host.close();
    }
  });
});

describe("pty host with real terminals", () => {
  const shell = process.platform === "win32" ? "cmd.exe" : "/bin/sh";

  it("runs a detached host that a second client can reattach to", { timeout: 20_000 }, async () => {
    const socketPath = ptyHostSocketPath(tempDir());
    const entry = NodeURL.fileURLToPath(new URL("./main.ts", import.meta.url));
    const first = await ensurePtyHost({ socketPath, entry });
    const out = collect();
    const env = { PATH: process.env.PATH ?? "", TERM: "xterm-256color" };
    const spawned = await first.spawn(
      { key: "real", shell, cwd: NodeOS.tmpdir(), cols: 80, rows: 24, env },
      out.listener,
    );
    await first.write("real", "echo octet-$((40+2))\r");
    await until(() => out.text().includes("octet-42"), 10_000);
    first.close();

    const second = await ensurePtyHost({ socketPath, entry });
    const again = await second.spawn(
      { key: "real", shell, cwd: NodeOS.tmpdir(), cols: 80, rows: 24, env },
      collect().listener,
    );
    assert.strictEqual(again.reattached, true);
    assert.strictEqual(again.pid, spawned.pid);
    assert.include(Buffer.from(again.buffer, "base64").toString(), "octet-42");

    const host = await second.hello();
    await second.kill("real");
    second.close();
    // The host goes away by itself later; don't leave it running after the test.
    try {
      process.kill(host.pid);
    } catch {}
  });
});
