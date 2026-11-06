// @effect-diagnostics nodeBuiltinImport:off
// @effect-diagnostics globalTimers:off
// @effect-diagnostics globalDate:off
import * as NodeChildProcess from "node:child_process";
import * as NodeNet from "node:net";

import {
  encodeLine,
  LineDecoder,
  PTY_HOST_PROTOCOL_MAJOR,
  PTY_HOST_PROTOCOL_MINOR,
  type ClientMessage,
  type HelloResult,
  type HostMessage,
  type PtyInfo,
  type SpawnRequest,
  type SpawnResult,
} from "./protocol.ts";

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
type Request = DistributiveOmit<ClientMessage, "id">;

export interface PtyListener {
  onData(data: Buffer): void;
  onExit(event: { exitCode: number; signal: number | null }): void;
}

/** One connection to the pty host. Listeners are per pty key. */
export class PtyHostClient {
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  private readonly listeners = new Map<string, Set<PtyListener>>();
  private readonly closeCallbacks = new Set<() => void>();

  private readonly socket: NodeNet.Socket;

  private constructor(socket: NodeNet.Socket) {
    this.socket = socket;
    socket.setEncoding("utf8");
    const decoder = new LineDecoder();
    socket.on("data", (chunk: string) => {
      for (const message of decoder.push(chunk)) this.receive(message as HostMessage);
    });
    const fail = () => {
      for (const { reject } of this.pending.values()) reject(new Error("Pty host connection closed"));
      this.pending.clear();
      for (const callback of this.closeCallbacks) callback();
      this.closeCallbacks.clear();
    };
    socket.on("close", fail);
    socket.on("error", fail);
  }

  /** Connects and checks the protocol version. */
  static async connect(socketPath: string): Promise<PtyHostClient> {
    const socket = await new Promise<NodeNet.Socket>((resolve, reject) => {
      const connection = NodeNet.createConnection(socketPath);
      connection.once("connect", () => {
        connection.off("error", reject);
        resolve(connection);
      });
      connection.once("error", reject);
    });
    const client = new PtyHostClient(socket);
    try {
      await client.request({ type: "hello", major: PTY_HOST_PROTOCOL_MAJOR, minor: PTY_HOST_PROTOCOL_MINOR });
    } catch (error) {
      client.close();
      throw error;
    }
    return client;
  }

  private receive(message: HostMessage): void {
    switch (message.type) {
      case "reply": {
        const waiter = this.pending.get(message.id);
        if (!waiter) return;
        this.pending.delete(message.id);
        if (message.ok) waiter.resolve(message.result);
        else waiter.reject(new Error(message.error));
        return;
      }
      case "data": {
        const bytes = Buffer.from(message.b64, "base64");
        for (const listener of this.listeners.get(message.key) ?? []) listener.onData(bytes);
        return;
      }
      case "exit":
        for (const listener of this.listeners.get(message.key) ?? []) {
          listener.onExit({ exitCode: message.exitCode, signal: message.signal });
        }
        return;
    }
  }

  private request(message: Request): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.write(encodeLine({ ...message, id } as ClientMessage));
    });
  }

  /**
   * Starts a pty under `key`, or attaches to the live one already there.
   * Register the listener first so no output between spawn and listen is lost.
   */
  async spawn(request: SpawnRequest, listener: PtyListener): Promise<SpawnResult> {
    this.listen(request.key, listener);
    try {
      return (await this.request({ type: "spawn", ...request })) as SpawnResult;
    } catch (error) {
      this.unlisten(request.key, listener);
      throw error;
    }
  }

  listen(key: string, listener: PtyListener): void {
    let set = this.listeners.get(key);
    if (!set) this.listeners.set(key, (set = new Set()));
    set.add(listener);
  }

  unlisten(key: string, listener: PtyListener): void {
    const set = this.listeners.get(key);
    set?.delete(listener);
    if (set?.size === 0) this.listeners.delete(key);
  }

  write(key: string, data: string): Promise<void> {
    return this.request({ type: "write", key, data }).then(() => undefined);
  }

  resize(key: string, cols: number, rows: number): Promise<void> {
    return this.request({ type: "resize", key, cols, rows }).then(() => undefined);
  }

  kill(key: string, signal?: string): Promise<void> {
    return this.request({ type: "kill", key, ...(signal === undefined ? {} : { signal }) }).then(() => undefined);
  }

  /** Stops receiving a pty's output without stopping the pty. */
  detach(key: string): Promise<void> {
    this.listeners.delete(key);
    return this.request({ type: "detach", key }).then(() => undefined);
  }

  list(): Promise<ReadonlyArray<PtyInfo>> {
    return this.request({ type: "list" }) as Promise<ReadonlyArray<PtyInfo>>;
  }

  hello(): Promise<HelloResult> {
    return this.request({ type: "hello", major: PTY_HOST_PROTOCOL_MAJOR, minor: PTY_HOST_PROTOCOL_MINOR }) as Promise<HelloResult>;
  }

  onClose(callback: () => void): void {
    this.closeCallbacks.add(callback);
  }

  close(): void {
    this.socket.destroy();
  }
}

export interface EnsurePtyHostOptions {
  readonly socketPath: string;
  /** The host entry point, run with `execPath`. */
  readonly entry: string;
  readonly execPath?: string;
  readonly env?: NodeJS.ProcessEnv;
  readonly timeoutMs?: number;
}

/**
 * Connects to the running host, starting a detached one first if none
 * answers. The host is not a child of this process, so it outlives it.
 */
export async function ensurePtyHost(options: EnsurePtyHostOptions): Promise<PtyHostClient> {
  try {
    return await PtyHostClient.connect(options.socketPath);
  } catch {}
  const child = NodeChildProcess.spawn(
    options.execPath ?? process.execPath,
    [options.entry, "--socket", options.socketPath],
    {
      detached: true,
      stdio: "ignore",
      env: { ...(options.env ?? process.env), ELECTRON_RUN_AS_NODE: "1" },
      windowsHide: true,
    },
  );
  child.unref();
  const deadline = Date.now() + (options.timeoutMs ?? 10_000);
  let delay = 25;
  let lastError: unknown;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, delay));
    delay = Math.min(delay * 2, 400);
    try {
      return await PtyHostClient.connect(options.socketPath);
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error(`Pty host did not start at ${options.socketPath}`, { cause: lastError });
}
