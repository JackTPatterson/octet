import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * The toolchain a folder is built with, and the version that runs there (Node, Rust,
 * Python…). It backs the status bar's runtime chip.
 */
export const ProjectRuntimeVersionInput = Schema.Struct({
  cwd: TrimmedNonEmptyString,
});
export type ProjectRuntimeVersionInput = typeof ProjectRuntimeVersionInput.Type;

export const ProjectRuntimeVersionResult = Schema.Struct({
  /** Null when no marker file names a runtime, or its version could not be read. */
  runtime: Schema.NullOr(
    Schema.Struct({
      id: TrimmedNonEmptyString,
      name: TrimmedNonEmptyString,
      version: TrimmedNonEmptyString,
    }),
  ),
});
export type ProjectRuntimeVersionResult = typeof ProjectRuntimeVersionResult.Type;
