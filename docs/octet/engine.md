# Octet engine design

This replaces herdr. Decided 2026-11-04; the reasoning is in `port-plan.md`. The engine has two parts.

1. **The pty host.** A small, detached Node process that owns every terminal. It outlives the app and the server, so shells keep running when the window closes or the server restarts for an update.
2. **The engine service.** Lives in `apps/server`: workspaces, tabs and the pane layout, agent state, process info, and restore after a reboot. It restarts freely with the server, because the shells live in the host.

## 1. Pty host (`packages/pty-host`)

### Where it plugs in

T3 creates every terminal through one interface, `PtyAdapter` in `packages/shared/src/PtyAdapter.ts`:
- `spawn` returns a `PtyProcess` with `write`, `resize`, `kill`, `onData` and `onExit`.
- Today `apps/server/src/terminal/NodePtyAdapter.ts` backs it with node-pty, in the server process.

A new `PtyHostAdapter` layer implements the same interface by talking to the host, so T3's own terminals survive too, not just Octet's panes.

To reattach, `PtySpawnInput` gets one optional field:
- **`key`:** a stable id, e.g. `threadId:terminalId` for T3's terminals or the pane id for Octet's.
- If the host already has a live pty under that key, `spawn` attaches to it instead of starting a shell.
- The returned process reports `reattached: true` along with the host's output buffer.
- The terminal manager (`apps/server/src/terminal/Manager.ts`, `trySpawn` ~2337) then replaces its cold history with that buffer instead of replaying the file it saved. The host saw every byte while the server was down, so its buffer is newer.

### Process and transport

- **Launch.** The server starts the host on first use with `child_process.spawn(process.execPath, [hostEntry], { detached: true, stdio: "ignore" }).unref()`. Electron's Node is used with `ELECTRON_RUN_AS_NODE=1`.
- **Socket.** A Unix socket at `<baseDir>/pty-host.sock`, or a named pipe `\\.\pipe\octet-next-pty-host-<user>` on Windows. Only the current user can open it (mode 0600, and a per-user pipe name).
- **Single instance.** A lock file holding the pid and protocol version. A second host started by a race exits once the first one answers.
- **Wire format.** Newline-delimited JSON. Output bytes travel as base64 in `data` frames; this is simple and fast enough for terminal throughput.
  - Requests: `hello {protocol}`, `spawn {key, shell, args, cwd, cols, rows, env}`, `write {key, data}`, `resize {key, cols, rows}`, `kill {key, signal}`, `list`, `detach {key}`.
  - Events: `data {key, b64}`, `exit {key, exitCode, signal}`.
- **Buffer.** Each pty keeps a ring buffer of its recent output (default 2 MB, matching the manager's history byte limit). It is sent on attach, so a client that reconnects sees what happened while it was away.
- **Lifetime.**
  - The host exits by itself when it has no ptys and no clients for 60 s.
  - Exited ptys are kept for 30 s after exit, so the server can read the exit status.
  - It never exits while a pty is alive.

### Compatibility rule

The host must survive app updates, so its protocol is versioned and kept minimal.
- A newer server speaks to an older host if the protocol major version matches.
- When the major changes, the server starts a new host under a new socket name and leaves the old one running until its last pty exits. Updating Octet never kills a running shell.

### Platforms

- node-pty covers macOS, Linux, and Windows via ConPTY.
- The socket path vs named pipe is the only per-platform code.
- Web and mobile clients don't run a host. They reach a desktop or headless server, which runs it.

## 2. Engine service (`apps/server/src/engine`)

| Piece | What it does | Ported from |
|---|---|---|
| Model | Workspaces, tabs and a pane split tree; numbers, labels, focus. Persisted with the server's store | `Shared/EngineModels.swift` (Octet), herdr `workspace/`, `layout.rs` |
| Agent state | `idle / working / blocked / done / unknown` per pane. Hooks first (Claude Code hooks, Codex notify), screen matching as fallback | herdr `src/detect/manifests/*.toml` (23 agents, copied as data) and its corpus tests; herdr `src/integration` for hook installation |
| Screen reading | The bottom lines of a pane for detection and `pane.read` | A headless emulator fed from the host's stream: T3's Ghostty WASM core (`apps/web/src/terminal/ghostty/core.ts`), or `@xterm/headless` |
| Process info | Each pane's foreground process, cwd, child tree, and listening ports | `ps`/`/proc` walk from the shell pid; `lsof`/`netstat` for ports (Octet `SessionStore.swift` ~340–600, `PortsWatcher.swift`) |
| Restore after reboot | Save the layout and each pane's agent session id. On start, recreate the panes and resume agents (`claude --resume <id>`, etc.) | herdr `persist/`, `agent_resume.rs` |
| API | Effect RPC methods and events in `packages/contracts`, over T3's WebSocket. Shapes follow the ~40 herdr methods the native app used (`pane.send_text`, `pane.read`, `pane.process_info`, `workspace.create`, `tab.*`, `events.subscribe`…) | — |

## Build order

1. **Done (2026-11-04):** `packages/pty-host`, with 13 tests including a real detached host that a second client reattaches to.
2. **Done (2026-11-04):** `apps/server/src/terminal/PtyHostAdapter.ts`, on with `OCTET_PTY_HOST=1` (`PtyHostAdapter.layerSelected` in `server.ts`); otherwise T3's node-pty.
   - The terminal manager passes the key `threadId:terminalId`.
   - Only the first start of a key in a server's life may reattach. Any later start (restart, reopen, new environment) sends `replace`, because it follows a stop.
   - A reattached terminal's host output replaces its saved history.
   - Tested end to end in `PtyHostAdapter.test.ts`: a second adapter (a restarted server) gets the same pid and the earlier output.
3. Model, API, and the tabs/terminal UI.
4. Agent state, then process info and ports, then restore after a reboot.

## Still open in the host

- **Packaging.** The host entry is `main.ts`, which Node 26 runs directly by stripping types. Packaged builds need it bundled to a `.js` next to the server, with node-pty unpacked from the asar archive.
- **Windows is untested.** The named pipe, ConPTY pid wait and `TERM` code paths are written but haven't run on Windows.
- **The host has no log file yet.** Its stdio goes to `/dev/null`.
