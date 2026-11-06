import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Whether the Claude Code CLI running in a thread's terminal has Remote Control on
 * (the session is open in claude.ai or the Claude app), read from its session log.
 */
export const ProjectRemoteControlInput = Schema.Struct({
  /** The folder Claude runs in; its session logs are under that folder's project directory. */
  cwd: TrimmedNonEmptyString,
  /** The terminal's shell process. Log records from before it started belong to an earlier run. */
  pid: Schema.optional(Schema.Int.check(Schema.isGreaterThan(0))),
});
export type ProjectRemoteControlInput = typeof ProjectRemoteControlInput.Type;

export const ProjectRemoteControlResult = Schema.Struct({
  active: Schema.Boolean,
  /** The session's claude.ai link, while active. */
  url: Schema.NullOr(Schema.String),
});
export type ProjectRemoteControlResult = typeof ProjectRemoteControlResult.Type;
