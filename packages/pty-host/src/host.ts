// @effect-diagnostics nodeBuiltinImport:off
// @effect-diagnostics globalTimers:off
// Runs detached from the app and the server, so it uses Node built-ins only.
import * as NodeFS from "node:fs";
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
import { RingBuffer } from "./ringBuffer.ts";

/** The slice of node-pty the host uses, so tests can supply a fake. */
export interface HostPty {
  readonly pid: number;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(signal?: string): void;
  onData(callback: (data: string) => void): void;
  onExit(callback: (event: { exitCode: number; signal?: number | undefined }) => void): void;
}

/** Returns the pty, or a promise of it when it needs time to become ready (ConPTY's pid). */
export type HostPtyFactory = (request: SpawnRequest) => HostPty | Promise<HostPty>;

export interface PtyHostOptions {
  readonly socketPath: string;
  readonly spawnPty: HostPtyFactory;
  /** Bytes of output kept per pty for replay. */
  readonly bufferBytes?: number;
  /** How long an exited pty's status stays readable. */
  readonly exitRetainMs?: number;
  /** How long the host waits, with no ptys and no clients, before exiting. */
  readonly idleExitMs?: number;
  readonly onIdleExit?: () => void;
  readonly log?: (message: string) => void;
}

interface Entry {
  readonly key: string;
  readonly pty: HostPty;
  readonly buffer: RingBuffer;
  readonly subscribers: Set<NodeNet.Socket>;
  cols: number;
  rows: number;
  exited: PtyInfo["exited"];
}

const DEFAULT_BUFFER_BYTES = 2 * 1024 * 1024;
const DEFAULT_EXIT_RETAIN_MS = 30_000;
const DEFAULT_IDLE_EXIT_MS = 60_000;

export interface PtyHost {
  readonly listening: Promise<void>;
  close(): Promise<void>;
}

export function startPtyHost(options: PtyHostOptions): PtyHost {
  const bufferBytes = options.bufferBytes ?? DEFAULT_BUFFER_BYTES;
  const exitRetainMs = options.exitRetainMs ?? DEFAULT_EXIT_RETAIN_MS;
  const idleExitMs = options.idleExitMs ?? DEFAULT_IDLE_EXIT_MS;
  const log = options.log ?? (() => {});
  const entries = new Map<string, Entry>();
  const clients = new Set<NodeNet.Socket>();
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let closed = false;

  const send = (socket: NodeNet.Socket, message: HostMessage) => {
    if (!socket.destroyed) socket.write(encodeLine(message));
  };

  const scheduleIdleCheck = () => {
    if (idleTimer !== undefined) clearTimeout(idleTimer);
    idleTimer = undefined;
    if (closed || entries.size > 0 || clients.size > 0) return;
    idleTimer = setTimeout(() => {
      if (entries.size > 0 || clients.size > 0) return;
      log("idle, exiting");
      void close().then(() => options.onIdleExit?.());
    }, idleExitMs);
  };

  const info = (entry: Entry): PtyInfo => ({
    key: entry.key,
    pid: entry.pty.pid,
    cols: entry.cols,
    rows: entry.rows,
    exited: entry.exited,
  });

  const spawning = new Map<string, Promise<HostPty>>();

  const spawn = async (socket: NodeNet.Socket, request: SpawnRequest): Promise<SpawnResult> => {
    // A second spawn for a key that is still starting attaches to the same pty.
    const starting = spawning.get(request.key);
    if (starting) await starting.catch(() => undefined);
    const existing = entries.get(request.key);
    if (existing && (request.replace === true || existing.exited !== null)) {
      // The old pty's status stays with the clients that had it; this key now
      // names a new one.
      entries.delete(request.key);
      // Its exit must not reach listeners of the new pty, which share the key.
      existing.subscribers.clear();
      if (existing.exited === null) existing.pty.kill();
    } else if (existing) {
      existing.subscribers.add(socket);
      if (existing.cols !== request.cols || existing.rows !== request.rows) {
        existing.pty.resize(request.cols, request.rows);
        existing.cols = request.cols;
        existing.rows = request.rows;
      }
      return {
        pid: existing.pty.pid,
        reattached: true,
        buffer: existing.buffer.contents().toString("base64"),
        exited: existing.exited,
      };
    }
    const pending = Promise.resolve(options.spawnPty(request));
    spawning.set(request.key, pending);
    let pty: HostPty;
    try {
      pty = await pending;
    } finally {
      spawning.delete(request.key);
    }
    const entry: Entry = {
      key: request.key,
      pty,
      buffer: new RingBuffer(bufferBytes),
      subscribers: new Set([socket]),
      cols: request.cols,
      rows: request.rows,
      exited: null,
    };
    entries.set(request.key, entry);
    pty.onData((data) => {
      const bytes = Buffer.from(data, "utf8");
      entry.buffer.append(bytes);
      const b64 = bytes.toString("base64");
      for (const subscriber of entry.subscribers) send(subscriber, { type: "data", key: entry.key, b64 });
    });
    pty.onExit(({ exitCode, signal }) => {
      entry.exited = { exitCode, signal: signal ?? null };
      for (const subscriber of entry.subscribers) {
        send(subscriber, { type: "exit", key: entry.key, exitCode, signal: signal ?? null });
      }
      setTimeout(() => {
        if (entries.get(entry.key) === entry) entries.delete(entry.key);
        scheduleIdleCheck();
      }, exitRetainMs).unref();
    });
    log(`spawned ${request.key} pid ${pty.pid}`);
    return { pid: pty.pid, reattached: false, buffer: "", exited: null };
  };

  const live = (key: string): Entry => {
    const entry = entries.get(key);
    if (!entry) throw new Error(`No pty with key ${key}`);
    return entry;
  };

  const handle = (socket: NodeNet.Socket, message: ClientMessage): unknown => {
    switch (message.type) {
      case "hello":
        if (message.major !== PTY_HOST_PROTOCOL_MAJOR) {
          throw new Error(`Protocol ${message.major} is not supported by host ${PTY_HOST_PROTOCOL_MAJOR}`);
        }
        return {
          major: PTY_HOST_PROTOCOL_MAJOR,
          minor: PTY_HOST_PROTOCOL_MINOR,
          pid: process.pid,
        } satisfies HelloResult;
      case "spawn":
        return spawn(socket, message);
      case "write": {
        const entry = live(message.key);
        if (entry.exited === null) entry.pty.write(message.data);
        return undefined;
      }
      case "resize": {
        const entry = live(message.key);
        if (entry.exited === null) {
          entry.pty.resize(message.cols, message.rows);
          entry.cols = message.cols;
          entry.rows = message.rows;
        }
        return undefined;
      }
      case "kill": {
        const entry = live(message.key);
        if (entry.exited === null) entry.pty.kill(message.signal);
        return undefined;
      }
      case "detach":
        entries.get(message.key)?.subscribers.delete(socket);
        return undefined;
      case "list":
        return [...entries.values()].map(info);
    }
  };

  const server = NodeNet.createServer((socket) => {
    clients.add(socket);
    scheduleIdleCheck();
    socket.setEncoding("utf8");
    const decoder = new LineDecoder();
    socket.on("data", (chunk: string) => {
      for (const raw of decoder.push(chunk)) {
        const message = raw as ClientMessage;
        if (typeof message !== "object" || message === null || typeof message.id !== "number") continue;
        // Replies may finish out of order; spawn waits for a pid on Windows.
        Promise.resolve()
          .then(() => handle(socket, message))
          .then(
            (result) =>
              send(socket, { type: "reply", id: message.id, ok: true, ...(result === undefined ? {} : { result }) }),
            (error: unknown) =>
              send(socket, {
                type: "reply",
                id: message.id,
                ok: false,
                error: error instanceof Error ? error.message : String(error),
              }),
          );
      }
    });
    const drop = () => {
      clients.delete(socket);
      for (const entry of entries.values()) entry.subscribers.delete(socket);
      scheduleIdleCheck();
    };
    socket.on("close", drop);
    socket.on("error", drop);
  });

  const listening = (async () => {
    if (process.platform !== "win32" && NodeFS.existsSync(options.socketPath)) {
      // Replace only a socket nobody answers on: a live host keeps its shells.
      if (await answers(options.socketPath)) {
        throw new Error(`A pty host is already running at ${options.socketPath}`);
      }
      try {
        NodeFS.unlinkSync(options.socketPath);
      } catch {}
    }
    await listen();
  })();
  listening.catch(() => {});

  function listen(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.socketPath, () => {
      server.off("error", reject);
      if (process.platform !== "win32") NodeFS.chmodSync(options.socketPath, 0o600);
      scheduleIdleCheck();
      resolve();
    });
    });
  }

  const close = async () => {
    if (closed) return;
    closed = true;
    if (idleTimer !== undefined) clearTimeout(idleTimer);
    for (const client of clients) client.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  };

  return { listening, close };
}

/** Whether something accepts connections on `socketPath`. */
function answers(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = NodeNet.createConnection(socketPath);
    probe.once("connect", () => {
      probe.destroy();
      resolve(true);
    });
    probe.once("error", () => resolve(false));
  });
}
