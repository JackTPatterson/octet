import * as NodeServices from "@effect/platform-node/NodeServices";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import { describe, expect, it } from "vite-plus/test";

import * as ProcessRunner from "../processRunner.ts";
import { claudeProjectDirectoryName, readRemoteControl } from "./readRemoteControl.ts";

const layer = ProcessRunner.layer.pipe(Layer.provideMerge(NodeServices.layer));

type TestServices = FileSystem.FileSystem | Path.Path | ProcessRunner.ProcessRunner;

const withLog = (
  lines: ReadonlyArray<string>,
  run: (home: string) => Effect.Effect<void, PlatformError.PlatformError, TestServices>,
) =>
  Effect.runPromise(
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const home = yield* fileSystem.makeTempDirectoryScoped();
      const directory = `${home}/.claude/projects/${claudeProjectDirectoryName("/work/my.app")}`;
      yield* fileSystem.makeDirectory(directory, { recursive: true });
      yield* fileSystem.writeFileString(`${directory}/abc.jsonl`, lines.join("\n") + "\n");
      yield* run(home);
    }).pipe(Effect.scoped, Effect.orDie, Effect.provide(layer)),
  );

const read = (home: string, pid?: number) =>
  readRemoteControl({ cwd: "/work/my.app", pid }).pipe(
    Effect.provideService(HostProcess.HomeDirectory, home),
    Effect.provideService(HostProcess.Environment, {}),
  );

const bridge = JSON.stringify({
  type: "system",
  subtype: "bridge_status",
  url: "https://claude.ai/code/session_9",
  // Later than any process start, so the record always counts.
  timestamp: "2099-01-01T00:00:00Z",
});

describe("readRemoteControl", () => {
  it("names a folder's log directory the way Claude does", () => {
    expect(claudeProjectDirectoryName("/Users/me/Developer/my.app")).toBe("-Users-me-Developer-my-app");
  });
  it("is on while the newest session log says so", async () => {
    await withLog([bridge], (home) =>
      Effect.gen(function* () {
        expect(yield* read(home)).toEqual({ active: true, url: "https://claude.ai/code/session_9" });
      }),
    );
  });
  it("is off with no log for the folder", async () => {
    await withLog([bridge], (home) =>
      Effect.gen(function* () {
        const other = yield* readRemoteControl({ cwd: "/elsewhere" }).pipe(
          Effect.provideService(HostProcess.HomeDirectory, home),
          Effect.provideService(HostProcess.Environment, {}),
        );
        expect(other).toEqual({ active: false, url: null });
      }),
    );
  });
  it("ignores a log last written before the process started", async () => {
    await withLog([bridge], (home) =>
      Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const file = `${home}/.claude/projects/${claudeProjectDirectoryName("/work/my.app")}/abc.jsonl`;
        // Written after this process started: it counts.
        expect((yield* read(home, process.pid)).active).toBe(true);
        const longAgo = DateTime.toDateUtc(DateTime.makeUnsafe("2000-01-01"));
        yield* fileSystem.utimes(file, longAgo, longAgo);
        expect((yield* read(home, process.pid)).active).toBe(false);
      }),
    );
  });
});
