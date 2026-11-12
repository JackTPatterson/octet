import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeURL from "node:url";

// oxlint-disable-next-line t3code/no-global-process-runtime -- Native speech builds only on a macOS build host.
if (process.platform === "darwin") {
  const source = NodeURL.fileURLToPath(new URL("../native/voice/main.swift", import.meta.url));
  const directory = NodeURL.fileURLToPath(new URL("../resources/voice/", import.meta.url));
  NodeFS.mkdirSync(directory, { recursive: true });
  const slices = ["arm64", "x86_64"].map((arch) => `${directory}octet-voice-${arch}`);
  try {
    for (const [index, arch] of ["arm64", "x86_64"].entries()) {
      NodeChildProcess.execFileSync(
        "xcrun",
        ["swiftc", "-O", "-target", `${arch}-apple-macosx13.0`, source, "-o", slices[index]],
        { stdio: "inherit" },
      );
    }
    NodeChildProcess.execFileSync(
      "xcrun",
      ["lipo", "-create", ...slices, "-output", `${directory}octet-voice`],
      {
        stdio: "inherit",
      },
    );
  } finally {
    for (const slice of slices) NodeFS.rmSync(slice, { force: true });
  }
}
