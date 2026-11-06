// @effect-diagnostics nodeBuiltinImport:off
// The pty host outlives server versions, so this wire format stays small and
// plain: newline-delimited JSON, terminal bytes as base64.
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

/** Bump only for breaking changes; a new major runs as a separate host. */
export const PTY_HOST_PROTOCOL_MAJOR = 1;
export const PTY_HOST_PROTOCOL_MINOR = 0;

export interface SpawnRequest {
  readonly key: string;
  readonly shell: string;
  readonly args?: ReadonlyArray<string>;
  readonly cwd: string;
  readonly cols: number;
  readonly rows: number;
  readonly env: Readonly<Record<string, string>>;
  /** Start a new pty even if one is running under this key (it is killed). */
  readonly replace?: boolean;
}

export type ClientMessage =
  | { readonly id: number; readonly type: "hello"; readonly major: number; readonly minor: number }
  | ({ readonly id: number; readonly type: "spawn" } & SpawnRequest)
  | { readonly id: number; readonly type: "write"; readonly key: string; readonly data: string }
  | {
      readonly id: number;
      readonly type: "resize";
      readonly key: string;
      readonly cols: number;
      readonly rows: number;
    }
  | { readonly id: number; readonly type: "kill"; readonly key: string; readonly signal?: string }
  | { readonly id: number; readonly type: "detach"; readonly key: string }
  | { readonly id: number; readonly type: "list" };

export interface PtyInfo {
  readonly key: string;
  readonly pid: number;
  readonly cols: number;
  readonly rows: number;
  readonly exited: { readonly exitCode: number; readonly signal: number | null } | null;
}

export type HostMessage =
  | {
      readonly type: "reply";
      readonly id: number;
      readonly ok: true;
      readonly result?: unknown;
    }
  | { readonly type: "reply"; readonly id: number; readonly ok: false; readonly error: string }
  | { readonly type: "data"; readonly key: string; readonly b64: string }
  | {
      readonly type: "exit";
      readonly key: string;
      readonly exitCode: number;
      readonly signal: number | null;
    };

export interface HelloResult {
  readonly major: number;
  readonly minor: number;
  readonly pid: number;
}

/** What `spawn` answers: whether it attached to a live pty, and what that pty printed so far. */
export interface SpawnResult {
  readonly pid: number;
  readonly reattached: boolean;
  /** Recent output (base64) when reattaching; empty for a new pty. */
  readonly buffer: string;
  readonly exited: PtyInfo["exited"];
}

/**
 * Where the host listens. One per user and protocol major, so a newer
 * incompatible host never takes over an older one's shells.
 */
export function ptyHostSocketPath(
  baseDir: string,
  major: number = PTY_HOST_PROTOCOL_MAJOR,
): string {
  if (process.platform === "win32") {
    const user = NodeOS.userInfo().username.replace(/[^A-Za-z0-9_-]/g, "_");
    return `\\\\.\\pipe\\octet-next-pty-host-${user}-v${major}`;
  }
  return NodePath.join(baseDir, `pty-host-v${major}.sock`);
}

/** Splits a byte stream into newline-terminated JSON messages. */
export class LineDecoder {
  private pending = "";

  push(chunk: string): Array<unknown> {
    this.pending += chunk;
    const messages: Array<unknown> = [];
    let newline = this.pending.indexOf("\n");
    while (newline !== -1) {
      const line = this.pending.slice(0, newline);
      this.pending = this.pending.slice(newline + 1);
      if (line.length > 0) {
        try {
          messages.push(JSON.parse(line));
        } catch {
          // A malformed line is dropped; the next one still parses.
        }
      }
      newline = this.pending.indexOf("\n");
    }
    return messages;
  }
}

export const encodeLine = (message: ClientMessage | HostMessage): string =>
  `${JSON.stringify(message)}\n`;
