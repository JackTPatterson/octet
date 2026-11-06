import * as Schema from "effect/Schema";

import { NonNegativeInt, ThreadId } from "./baseSchemas.ts";

/**
 * Brings what was typed into the agent's own CLI (terminal view) into the thread's chat
 * history, so flipping between the two views shows one conversation.
 */
export const ThreadCliMirrorInput = Schema.Struct({
  threadId: ThreadId,
  /**
   * When the terminal started, in ms. Only needed for a thread with no session yet: the
   * CLI's new session is then the folder's newest log written since.
   */
  sinceMs: Schema.optional(NonNegativeInt),
  /**
   * The agent whose CLI ran in the terminal, for a thread with no provider session of its
   * own. Only "claudeAgent" is read so far.
   */
  driver: Schema.optional(Schema.String),
});
export type ThreadCliMirrorInput = typeof ThreadCliMirrorInput.Type;

export const ThreadCliMirrorResult = Schema.Struct({
  /** Messages added to the thread. */
  added: NonNegativeInt,
  /**
   * The CLI's session. A thread that had none now resumes it in the chat, and the terminal
   * resumes it with `--resume`.
   */
  sessionId: Schema.NullOr(Schema.String),
  status: Schema.Literals([
    "mirrored",
    /** The thread's agent has no CLI log this reads (only Claude Code for now). */
    "unsupported",
    /** No session to read: the CLI has not run in this folder since the terminal started. */
    "no_session",
    "no_log",
  ]),
});
export type ThreadCliMirrorResult = typeof ThreadCliMirrorResult.Type;
