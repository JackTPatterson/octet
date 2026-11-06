// @effect-diagnostics nodeBuiltinImport:off
// Octet: terminals run in the detached pty host (packages/pty-host), so they
// outlive this server. A spawn with a known key attaches to the running
// terminal instead of starting a new one.
import * as NodeCrypto from "node:crypto";
import * as NodeURL from "node:url";

import * as Config from "effect/Config";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PtyAdapter from "@t3tools/shared/PtyAdapter";
import { ensurePtyHost, ptyHostSocketPath, PtyHostClient, type PtyListener } from "@t3tools/pty-host";

import * as ServerConfig from "../config.ts";
import * as NodePtyAdapter from "./NodePtyAdapter.ts";

class HostPtyProcess implements PtyAdapter.PtyProcess {
  pid = 0;
  restored: { readonly output: string } | undefined;
  private exitEvent: PtyAdapter.PtyExitEvent | undefined;
  private readonly dataListeners = new Set<(data: string) => void>();
  private readonly exitListeners = new Set<(event: PtyAdapter.PtyExitEvent) => void>();
  // Output arrives in chunks that can split a UTF-8 sequence.
  private readonly decoder = new TextDecoder("utf-8");
  readonly key: string;
  private readonly host: () => PtyHostClient | null;

  constructor(key: string, host: () => PtyHostClient | null) {
    this.key = key;
    this.host = host;
  }

  readonly listener: PtyListener = {
    onData: (bytes) => {
      const text = this.decoder.decode(bytes, { stream: true });
      if (text.length === 0) return;
      for (const listener of this.dataListeners) listener(text);
    },
    onExit: ({ exitCode, signal }) => this.exit({ exitCode, signal }),
  };

  exit(event: PtyAdapter.PtyExitEvent): void {
    if (this.exitEvent) return;
    this.exitEvent = event;
    for (const listener of this.exitListeners) listener(event);
    this.exitListeners.clear();
  }

  private send(action: (client: PtyHostClient) => Promise<void>): void {
    const client = this.host();
    if (!client || this.exitEvent) return;
    action(client).catch(() => {});
  }

  write(data: string): void {
    this.send((client) => client.write(this.key, data));
  }

  resize(cols: number, rows: number): void {
    this.send((client) => client.resize(this.key, cols, rows));
  }

  kill(signal?: string): void {
    this.send((client) => client.kill(this.key, process.platform === "win32" ? undefined : signal));
  }

  onData(callback: (data: string) => void): () => void {
    this.dataListeners.add(callback);
    return () => {
      this.dataListeners.delete(callback);
    };
  }

  onExit(callback: (event: PtyAdapter.PtyExitEvent) => void): () => void {
    if (this.exitEvent) {
      callback(this.exitEvent);
      return () => {};
    }
    this.exitListeners.add(callback);
    return () => {
      this.exitListeners.delete(callback);
    };
  }
}

const make = Effect.fn("PtyHostAdapter.make")(function* () {
  const config = yield* ServerConfig.ServerConfig;
  const socketPath = ptyHostSocketPath(config.baseDir);
  const entry = NodeURL.fileURLToPath(import.meta.resolve("@t3tools/pty-host/main"));
  const live = new Map<string, HostPtyProcess>();
  let client: PtyHostClient | null = null;
  let connecting: Promise<PtyHostClient> | null = null;

  const connect = (): Promise<PtyHostClient> => {
    if (client) return Promise.resolve(client);
    if (connecting) return connecting;
    const attempt = ensurePtyHost({ socketPath, entry })
      .then((connected) => {
        client = connected;
        connected.onClose(() => {
          client = null;
          void reattachAll();
        });
        return connected;
      })
      .finally(() => {
        connecting = null;
      });
    connecting = attempt;
    return attempt;
  };

  // The host restarted or the socket dropped: pick the terminals back up.
  // A terminal the host no longer has has ended.
  const reattachAll = async () => {
    if (live.size === 0) return;
    let connected: PtyHostClient;
    try {
      connected = await connect();
    } catch {
      for (const pty of live.values()) pty.exit({ exitCode: 1, signal: null });
      live.clear();
      return;
    }
    const running = new Set((await connected.list().catch(() => [])).map((pty) => pty.key));
    for (const [key, pty] of live) {
      if (!running.has(key)) {
        live.delete(key);
        pty.exit({ exitCode: 1, signal: null });
        continue;
      }
      connected.listen(key, pty.listener);
    }
  };

  return PtyAdapter.PtyAdapter.of({
    spawn: Effect.fn("PtyHostAdapter.spawn")(function* (input) {
      const key = input.key ?? `anonymous:${NodeCrypto.randomUUID()}`;
      const pty = new HostPtyProcess(key, () => client);
      // A restart reuses the key; the old process object stops listening.
      const previous = live.get(key);
      if (previous) client?.unlisten(key, previous.listener);
      const env: Record<string, string> = {};
      for (const [name, value] of Object.entries(input.env)) {
        if (value !== undefined) env[name] = value;
      }
      const result = yield* Effect.tryPromise({
        try: async () => {
          const connected = await connect();
          return connected.spawn(
            {
              key,
              shell: input.shell,
              ...(input.args === undefined ? {} : { args: input.args }),
              cwd: input.cwd,
              cols: input.cols,
              rows: input.rows,
              env,
              ...(input.replace === true ? { replace: true } : {}),
            },
            pty.listener,
          );
        },
        catch: (cause) => new PtyAdapter.PtySpawnError({ adapter: "pty-host", shell: input.shell, cause }),
      });
      pty.pid = result.pid;
      if (result.reattached) {
        pty.restored = { output: Buffer.from(result.buffer, "base64").toString("utf8") };
      }
      live.set(key, pty);
      pty.onExit(() => {
        if (live.get(key) !== pty) return;
        live.delete(key);
        client?.unlisten(key, pty.listener);
      });
      if (result.exited) pty.exit(result.exited);
      return pty;
    }),
  });
});

export const layer = Layer.effect(PtyAdapter.PtyAdapter, make());

/**
 * The pty host while Octet's engine is being built: on with OCTET_PTY_HOST=1,
 * otherwise T3's in-process node-pty.
 */
type SelectedLayer = Layer.Layer<
  PtyAdapter.PtyAdapter,
  never,
  ServerConfig.ServerConfig | FileSystem.FileSystem | Path.Path
>;

export const layerSelected = Layer.unwrap(
  Effect.gen(function* () {
    const enabled = yield* Config.Boolean("OCTET_PTY_HOST").pipe(Config.withDefault(false));
    const selected: SelectedLayer = enabled ? layer : NodePtyAdapter.layer;
    return selected;
  }),
);
