import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import { describe, expect, it } from "vite-plus/test";

import { detectProjectRuntime, parseRuntimeVersion } from "./projectRuntime.ts";

const files = (...present: string[]) => (file: string) => Effect.succeed(present.includes(file));
const detect = (dir: string, fn: (file: string) => Effect.Effect<boolean>) =>
  Effect.runPromise(detectProjectRuntime(dir, fn).pipe(Effect.provide(NodeServices.layer)));

describe("parseRuntimeVersion", () => {
  it("reads the first version number", () => {
    expect(parseRuntimeVersion("v25.6.1\n")).toBe("v25.6.1");
    expect(parseRuntimeVersion("Python 3.12.4")).toBe("3.12.4");
    expect(parseRuntimeVersion("rustc 1.83.0 (90b35a623 2024-11-26)")).toBe("1.83.0");
    expect(parseRuntimeVersion("go version go1.23.2 darwin/arm64")).toBe("1.23.2");
  });
  it("reads Swift's own version, not its driver's", () => {
    expect(
      parseRuntimeVersion("Apple Swift version 6.0.2 (swiftlang-6.0.2.1.2)\nTarget: arm64"),
    ).toBe("6.0.2");
    expect(parseRuntimeVersion("Apple Swift driver 1.2.3\nSwift version 6.0.2")).toBe("6.0.2");
  });
  it("is null when there is none", () => {
    expect(parseRuntimeVersion("command not found")).toBeNull();
  });
});

describe("detectProjectRuntime", () => {
  it("prefers a lockfile's runtime over package.json", async () => {
    const found = await detect(
      "/repo/app",
      files("/repo/app/bun.lock", "/repo/app/package.json"),
    );
    expect(found?.runtime.id).toBe("bun");
  });
  it("walks up to a marker, and stops at the repository root", async () => {
    expect((await detect("/repo/a/b", files("/repo/Cargo.toml")))?.root).toBe("/repo");
    expect(
      await detect("/repo/a", files("/repo/.git", "/Cargo.toml")),
    ).toBeNull();
  });
});

describe("readProjectRuntimeVersion", () => {
  it("runs the project's version command in a login shell", async () => {
    const { readProjectRuntimeVersion } = await import("./projectRuntime.ts");
    const ProcessRunner = await import("../processRunner.ts");
    const Layer = await import("effect/Layer");
    const result = await Effect.runPromise(
      readProjectRuntimeVersion(import.meta.dirname).pipe(
        Effect.provide(ProcessRunner.layer.pipe(Layer.provideMerge(NodeServices.layer))),
      ),
    );
    // This repo's package.json names Node.
    expect(result?.id).toBe("node");
    expect(result?.version).toMatch(/^v?\d+\.\d+/);
  });
});
