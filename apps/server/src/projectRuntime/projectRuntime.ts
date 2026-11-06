import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";

import * as ProcessRunner from "../processRunner.ts";

/**
 * What a folder is built with, read from the files in it, and the version that runs
 * there. A port of native Octet's `ProjectRuntime`.
 */
export interface ProjectRuntime {
  readonly id: string;
  readonly name: string;
  /** Run in a login shell at the folder, so version managers apply. */
  readonly versionCommand: ReadonlyArray<string>;
}

const rt = (id: string, name: string, ...versionCommand: string[]): ProjectRuntime => ({
  id,
  name,
  versionCommand,
});

/** Marker files in priority order: a lockfile names the JavaScript runtime before package.json falls back to Node. */
const MARKERS: ReadonlyArray<readonly [files: ReadonlyArray<string>, runtime: ProjectRuntime]> = [
  [["bun.lockb", "bun.lock", "bunfig.toml"], rt("bun", "Bun", "bun", "--version")],
  [["deno.json", "deno.jsonc"], rt("deno", "Deno", "deno", "--version")],
  [["package.json", ".nvmrc", ".node-version"], rt("node", "Node", "node", "--version")],
  [["Cargo.toml"], rt("rust", "Rust", "rustc", "--version")],
  [["go.mod"], rt("go", "Go", "go", "version")],
  [
    ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", ".python-version"],
    rt("python", "Python", "python3", "--version"),
  ],
  [["Package.swift"], rt("swift", "Swift", "swift", "--version")],
  [["Gemfile", ".ruby-version"], rt("ruby", "Ruby", "ruby", "--version")],
  [["mix.exs"], rt("elixir", "Elixir", "elixir", "--short-version")],
  [["pubspec.yaml"], rt("dart", "Dart", "dart", "--version")],
  [["build.zig"], rt("zig", "Zig", "zig", "version")],
  [["composer.json"], rt("php", "PHP", "php", "--version")],
];

/**
 * The runtime for the nearest marker, walking up from `directory` and stopping at the
 * repository root (the folder holding `.git`), so a Node package inside a Rust repo
 * reads as Node. Returns the folder the marker sits in, to run the version command there.
 */
export const detectProjectRuntime = Effect.fn("ProjectRuntime.detect")(function* (
  directory: string,
  fileExists?: (file: string) => Effect.Effect<boolean>,
) {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const has =
    fileExists ?? ((file: string) => fileSystem.exists(file).pipe(Effect.orElseSucceed(() => false)));
  let current = path.resolve(directory);
  for (let depth = 0; depth < 12; depth += 1) {
    for (const [files, runtime] of MARKERS) {
      for (const file of files) {
        if (yield* has(path.join(current, file))) return { runtime, root: current };
      }
    }
    if (yield* has(path.join(current, ".git"))) return null;
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
  return null;
});

/**
 * The first version number in a tool's output: `v25.6.1` from node, `3.12.4` from
 * "Python 3.12.4", `1.83.0` from "rustc 1.83.0 (…)". Swift leads with its driver's
 * version, so its own is read after "Swift version".
 */
export function parseRuntimeVersion(output: string): string | null {
  const marker = "Swift version ";
  const at = output.indexOf(marker);
  const text = at >= 0 ? output.slice(at + marker.length) : output;
  return text.match(/v?\d+\.\d+(\.\d+)?/)?.[0] ?? null;
}

const quote = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;

const CACHE_MS = 5 * 60_000;
const cache = new Map<string, { at: number; value: ProjectRuntimeVersion | null }>();

export interface ProjectRuntimeVersion {
  readonly id: string;
  readonly name: string;
  readonly version: string;
}

/** The runtime a folder is built with and the version that runs there, or null. Never fails. */
export const readProjectRuntimeVersion = Effect.fn("ProjectRuntime.readVersion")(function* (
  directory: string,
) {
  const found = yield* detectProjectRuntime(directory);
  if (!found) return null;
  const key = `${found.runtime.id}|${found.root}`;
  const now = yield* Clock.currentTimeMillis;
  const hit = cache.get(key);
  if (hit && now - hit.at < CACHE_MS) return hit.value;

  const runner = yield* ProcessRunner.ProcessRunner;
  const [tool, ...args] = found.runtime.versionCommand;
  // A login shell, so nvm, asdf, mise and the like decide the version.
  const shell = globalThis.process.env.SHELL || "/bin/sh";
  const isWindows = globalThis.process.platform === "win32";
  const output = yield* runner
    .run({
      command: isWindows ? tool! : shell,
      args: isWindows ? args : ["-lc", found.runtime.versionCommand.map(quote).join(" ")],
      cwd: found.root,
      timeout: "10 seconds",
      maxOutputBytes: 64 * 1024,
      outputMode: "truncate",
    })
    .pipe(Effect.orElseSucceed(() => null));
  const version =
    output && output.code === 0 ? parseRuntimeVersion(`${output.stdout}\n${output.stderr}`) : null;
  const value = version ? { id: found.runtime.id, name: found.runtime.name, version } : null;
  cache.set(key, { at: now, value });
  return value;
});
