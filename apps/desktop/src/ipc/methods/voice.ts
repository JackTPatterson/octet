// @effect-diagnostics nodeBuiltinImport:off -- This native boundary owns the speech helper process and its streaming pipe.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeReadline from "node:readline";
import * as Electron from "electron";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as DesktopEnvironment from "../../app/DesktopEnvironment.ts";
import * as DesktopIpc from "../DesktopIpc.ts";
import { VOICE_CONTROL_CHANNEL, VOICE_EVENT_CHANNEL } from "../channels.ts";

const Control = Schema.Struct({
  id: Schema.String,
  action: Schema.Literals(["start", "stop", "cancel"]),
});

export const installVoiceInput = Effect.fn("desktop.ipc.installVoiceInput")(function* () {
  const ipc = yield* DesktopIpc.DesktopIpc;
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const platform = yield* HostProcess.Platform;
  let current: {
    id: string;
    owner: number;
    child: ReturnType<typeof NodeChildProcess.spawn>;
    cancel: () => void;
  } | null = null;
  yield* ipc.handle(
    DesktopIpc.makeIpcMethod({
      channel: VOICE_CONTROL_CHANNEL,
      payload: Control,
      result: Schema.Void,
      handler: (input, event) =>
        Effect.sync(() => {
          const owner = event?.sender.id;
          if (owner === undefined) return;
          if (input.action !== "start") {
            if (current?.owner !== owner || current.id !== input.id) return;
            if (input.action === "cancel") current.cancel();
            else current.child.stdin?.write("stop\n");
            return;
          }
          const contents = Electron.webContents.fromId(owner);
          if (!contents || Electron.BrowserWindow.getFocusedWindow()?.webContents.id !== owner)
            return;
          const send = (type: string, text = "") => {
            if (!contents.isDestroyed())
              contents.send(VOICE_EVENT_CHANNEL, { id: input.id, type, text });
          };
          const executable = (
            environment.isPackaged
              ? [NodePath.join(environment.resourcesPath, "voice", "octet-voice")]
              : environment.resolveResourcePathCandidates("voice/octet-voice")
          ).find(NodeFS.existsSync);
          if (platform !== "darwin" || !executable) {
            send("error", "Voice input is available in the macOS desktop build.");
            return;
          }
          current?.cancel();
          const child = NodeChildProcess.spawn(executable, [], { stdio: ["pipe", "pipe", "pipe"] });
          let ended = false;
          const lines = NodeReadline.createInterface({ input: child.stdout });
          const cleanup = () => {
            contents.removeListener("destroyed", cancel);
            contents.removeListener("did-start-navigation", cancel);
            if (current?.child === child) current = null;
          };
          const cancel = () => {
            ended = true;
            child.kill();
            cleanup();
          };
          current = { id: input.id, owner, child, cancel };
          contents.once("destroyed", cancel);
          contents.once("did-start-navigation", cancel);
          child.stderr.resume();
          lines.on("line", (line) => {
            if (ended) return;
            try {
              const value: unknown = JSON.parse(line);
              if (
                typeof value !== "object" ||
                value === null ||
                !("type" in value) ||
                !("text" in value)
              )
                return;
              if (typeof value.type !== "string" || typeof value.text !== "string") return;
              if (
                !["listening", "partial", "level", "final", "error", "cancelled"].includes(
                  value.type,
                )
              )
                return;
              send(value.type, value.text);
              if (["final", "error", "cancelled"].includes(value.type)) ended = true;
            } catch {}
          });
          child.once("error", () => {
            if (!ended) send("error", "Couldn't start voice input.");
            ended = true;
            cleanup();
          });
          child.once("exit", () => {
            if (!ended)
              send(
                "error",
                "Voice input stopped unexpectedly. Check microphone and speech permissions.",
              );
            ended = true;
            lines.close();
            cleanup();
          });
        }),
    }),
  );
  yield* Effect.addFinalizer(() => Effect.sync(() => current?.cancel()));
});
