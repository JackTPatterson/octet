# Octet on T3 Code: port plan

This repo is a fork of T3 Code (pingdotgg/t3code, MIT), taken at upstream `7f6f47b27b` on 2026-11-04. The aim is to rebrand it as Octet, so Octet runs everywhere T3 does (Mac, Windows, Linux, web, mobile), and then bring Octet's own features over from the native Swift app (`~/Developer/apps/herd`).

Branches and remotes:
- `upstream` points at pingdotgg/t3code.
- Our work goes on `octet`.
- To take T3's later changes, merge `upstream/main` into `octet`. Keep Octet code in its own files and folders where possible so those merges stay small.

## What comes over

Jack named these. The Swift sources are under `~/Developer/apps/herd`.

| # | Feature | Swift source | Lands in T3 at |
|---|---|---|---|
| 1 | Sidebar: projects, workspace cards, Snoozed/Idle shelves, hover peek | `Octet/Sidebar/SidebarView.swift`, `IdleDock.swift`, `WorkspacePeek.swift`, `Shared/ProjectGrouping.swift`, `Shared/AgentStatus.swift` | `apps/web/src/components/Sidebar.tsx`, `Sidebar.logic.ts`, `components/sidebar/` |
| 2 | Running process list under each workspace: the sidebar's per-workspace agents disclosure, plus the Overview tree in the right panel (subagents, background tasks, monitors, shells, with tree edges, "Finished" fold and stop) | `Octet/Sidebar/WorkspaceAgentsList.swift`; `RuntimeModel.swift`, `RuntimePanel.swift`, `RuntimeRows.swift`, `RuntimeTreeEdges.swift`; process walk in `Octet/Session/SessionStore.swift` ~340–600 | Sidebar row children; Overview surface. Process walk on the server (`ps-list` / `/proc` instead of BSD `ps`), stop with `process.kill` |
| 2b | Running servers under each workspace card: a horizontal row of port buttons with service logos (Next, Expo, Vite, Node, Django, Postgres…), each opening `localhost:<port>` | `PortButton` in `Octet/Sidebar/SidebarView.swift` (~570), `Octet/Terminal/PortsWatcher.swift`, `Shared/ServiceKind.swift` (command-line → logo slug rules) | Server: a ports service (`lsof`/`netstat` per platform, matched to the workspace's process tree). Web: a row under each sidebar workspace row; logos from Simple Icons slugs |
| 3 | Right nav (planes rail, picker, per-window state) | `Octet/Planes/Planes.swift`, `WorkspacePanelState.swift` | `apps/web/src/rightPanelStore.ts`, `components/RightPanelTabs.tsx`. Most planes already exist in T3 as surfaces. Add Octet's: Overview, Todos, CI (not Containers or Tickets, dropped 2026-11-05). **Remove the `terminal` surface**: terminals live only in the bottom drawer (`ThreadTerminalDrawer`). Route `lib/revealThreadTerminal.ts` there, and migrate persisted panel state that holds a terminal surface |
| 4 | Waits, check-ins and reminders (+ `octet-waits` tools for agents) | `Octet/Waits`, `Octet/Idle`, `Shared/Waits.swift`, `CheckIns.swift`, `WorkspaceSleep.swift` | Server: `apps/server/src/waits/` next to `scheduledTasks/`. Agent tools: a toolkit in `apps/server/src/mcp/toolkits/`. UI: sidebar Ready list, sheets |
| 5 | Bottom status bar chips | `Octet/Terminal/StatusBar.swift`, `StatusBarModel.swift`, `FooterStatus.swift`, `Shared/StatusBarItems.swift` | New `components/statusBar/` under the main layout, data from a server service (git, gh, ports, toolchain) |
| 6 | Native terminal view: panes, splits, pane cards | `Octet/Terminal/NativePanes.swift`, `PaneStream.swift` | T3 already draws its terminal with libghostty compiled to WASM (`apps/web/src/terminal/ghostty`). We bring Octet's pane and split behavior, not a renderer |
| 7 | Agent tabs along the top | `Octet/Tabs/TabBarView.swift`, `CompanionSplit.swift`, `SplitDropLayer.swift` | New `components/tabs/` above the main view |
| 8 | Monitor layouts (title-bar picker that arranges windows across displays) | `Octet/Plugins/LayoutPicker.swift`, `Shared/MonitorLayouts.swift` | Desktop only: Electron `screen.getAllDisplays()` + `BrowserWindow.setBounds`, exposed to the web app through the desktop bridge |

## The one structural choice: the engine

Octet's tabs, panes, agent states and the process list all come from the engine (`~/Developer/apps/octet-engine`, our Rust fork of herdr). The engine:
- owns the PTYs, so sessions survive an app restart;
- reports each agent's state (working, blocked, done);
- streams each pane as a replay followed by raw terminal bytes (`pane.stream`).

T3 is built around chat threads that talk to agents through their SDKs. Its terminal is a plain `node-pty` shell per thread.

**Superseded the same day (see below): keep the engine.** Jack's rule was to keep it if it is what keeps sessions alive across restarts and window closes, and it is:
- herdr keeps terminals running in a background server after the client closes, and after a reboot it restores the layout and resumes agent sessions (its README, "detach without stopping work").
- T3's server is a child process of the Electron app (`apps/desktop/src/backend/DesktopBackendManager`). Its node-pty shells die with the app; only their scrollback is saved (`apps/server/src/terminal/Manager.ts`, `persistHistory`).

**First plan (superseded if the lightweight engine below is approved): run herdr next to T3's server.**
- The server starts the engine binary, talks to it over its local socket, and passes workspaces, tabs, panes and agent events to clients through T3's existing WebSocket RPC.
- Pane streams feed T3's Ghostty WASM terminal directly.
- herdr already ships Windows builds, so we don't lose a platform.
- T3's chat threads stay as they are. A tab can be a terminal agent (engine) or a T3 thread.

### Decided 2026-11-04: replace herdr with a small engine of our own

Jack approved this ("lets go with the custom build"). herdr is no longer part of the fork.

Jack asked whether a lightweight engine is worth building instead of keeping herdr. **Recommendation: yes.**

**herdr is large and Octet uses a sliver of it.**
- About 155k lines of Rust.
- The native app calls about 40 of its methods. The most used are `pane.send_text`, `layout.apply`, `pane.process_info`, `workspace.create`, `pane.move` and `pane.read`, plus the `events.subscribe` stream.
- Most of the code is things Octet doesn't need or T3 already has:
  - the TUI, input and config, about 20k lines;
  - its own Ghostty VT binding, about 10k;
  - the CLI, about 9.5k;
  - plugins;
  - worktrees and git refresh, which T3 already does.
- Keeping it means maintaining a Rust fork, shipping a second binary per platform, and keeping a protocol bridge in sync.

**What we actually need, and where it comes from:**

| Need | How herdr does it | Lightweight version |
|---|---|---|
| Shells survive the app closing | Background server process owns the PTYs; `server/handoff.rs` (547 lines) passes PTY file descriptors across engine upgrades | A small detached **pty host** process (Node + `node-pty`, which already does ConPTY on Windows), reached over a local socket. This is the same split VS Code uses (its `ptyHost` with persistent, reconnectable terminals). Keep it tiny and rarely changed, so app and server updates don't kill shells |
| Replay when a client attaches | Its terminal state, then raw bytes (`pane.stream`) | Ring buffer plus a headless emulator for the screen snapshot. Either T3's Ghostty WASM core (`apps/web/src/terminal/ghostty/core.ts`) run headless, or `@xterm/headless` + serialize |
| Agent state (working / blocked / idle / done) | `detect/` pattern-matches the screen tail against 23 per-agent TOML manifests, and `integration/` installs agent hooks (Claude Code settings, OpenCode config…) | Port the TOML manifests as data, unchanged. Prefer hooks where the agent has them (Claude Code hooks, Codex notify), with screen matching as the fallback. This is the part with the most edge cases, so port herdr's corpus tests with it |
| Workspaces, tabs, pane layout tree | `workspace/`, `layout.rs` | A plain model in T3's server, persisted with T3's existing store. Port the types from `Shared/EngineModels.swift` |
| Restore after reboot | `persist/`: saves the layout and resumes agents with their session ids (processes themselves don't survive a reboot in herdr either) | Save the layout plus each pane's agent session id, and resume with `--resume` on start |
| Process info, ports | `pane.process_info` | `pidtree`/`ps-list` (or `/proc`) from the pane's shell PID; listening ports via `lsof`/`netstat` per platform |

**Rough size:**
- About 1–2k lines for the pty host.
- About 6–10k lines in the server for the model, detection, restore and process info.
- That's against 155k lines of Rust, and all of it is TypeScript in the same repo and RPC as T3.

**Risks:**
- **Detection quality.** herdr's detection has years of tuning. Mitigation: port its manifests and its corpus tests.
- **Shells dying on update.** The pty host must stay compatible across app updates or shells die on update. Mitigation: a versioned, minimal protocol, and only restart the host when it truly changed.
- **T3's own background service isn't enough on its own.** T3 can already run its server as a background service (`apps/server/src/cloud/bootService.ts`, launchd/systemd), but the desktop app starts its own server child (`DesktopBackendManager`). That server also restarts on every update, so it can't hold the shells itself.

The herdr repo stays as a reference while porting; nothing gets deleted.

**Alternative: drop the engine and rebuild tabs and agent state on T3's `node-pty`.**
- One process fewer.
- But we'd lose sessions that survive restarts and would have to rewrite agent detection. Not recommended.

## Rebrand and hosted services

Do this before any feature work.
- Rename:
  - packages `@t3tools/*` → `@octet/*`;
  - the app id `com.t3tools.T3Code` → `com.jpxsoftware.octet`;
  - the scheme `t3code://` → `octet://`;
  - env vars `T3CODE_*` → `OCTET_*`;
  - the product name and icons (`scripts/export-brand-icons.ts`).
- Turn off what only works on T3's servers:
  - PostHog analytics (`apps/server/src/telemetry/AnalyticsService.ts`, default host `ingest.t3.codes`);
  - the T3 Connect relay and tunnel (`apps/server/src/cloud/*`);
  - Clerk sign-in (`clerk.t3.codes`);
  - npm self-update (`cloud/npmRelease.ts`).
- Point desktop updates (`apps/desktop/src/updates/DesktopUpdates.ts`) at our own feed.
- `apps/marketing` is T3's site. Drop it; Octet's site is `~/Developer/apps/octet-site`.

## Order

1. Rebrand, turn off hosted services, and get `pnpm dev:desktop` running.
2. Lightweight engine: the detached pty host, then the workspace/tab/pane model, agent-state detection (herdr's manifests + hooks) and restore-after-reboot in the server, exposed over T3's RPC.
3. Agent tabs and the terminal view, with panes from the engine.
4. Sidebar, with the process list under each workspace.
5. Right nav: Octet's planes added to T3's surfaces.
6. Status bar.
7. Waits, check-ins and reminders, plus the agent tools.
8. Monitor layouts.

## Progress

### Sidebar, first slice (2026-11-04)

**Where it lives.**
- `apps/web/src/components/octet/sidebar/` holds `OctetSidebar.tsx`, `octetSidebar.logic.ts`, and unit and browser tests.
- It is mounted in `AppSidebarLayout.tsx`. Setting `localStorage["octet.sidebar"] = "t3"` brings back T3's sidebar.
- T3's own `Sidebar.tsx` only gained `export` on `useSidebarLookups`, `partitionSidebarThreads`, `threadShellKey`, and `SidebarThreadPartitionInput`. `SidebarThreadRow.tsx` exports `SidebarProviderStack`. The sidebar wordmark reads "Octet".

**What's in it.** Everything is drawn with T3's own parts; see the rule below.
- `SidebarThreadHeader` with search. Typing filters the cards; Enter opens the first match.
- `SidebarProjectFolderHeader` for each project.
- **One card per branch/worktree** (decided by Jack), drawn with T3's thread-row surface, title, and meta-line classes:
  - the newest thread's title;
  - the branch's loudest status as T3's label (Working, Approval, Failed…), else its age;
  - the branch and the agent icon.
  - No list of agents inside the card. Jack removed it 2026-11-04, since agents show elsewhere.
- At the bottom, the Waiting shelf (snoozed threads) and the Idle shelf (settled), drawn with T3's `CollapsibleSectionHeader` like "Settled".

**Rule (Jack, 2026-11-04):** every Octet feature uses T3's existing UI components and styles, not native Octet's look, so it blends in.

**Next for the sidebar.**
- The horizontal row of running servers under each card. It needs a ports service on the server.
- Terminal agents from the engine, as rows in the cards.
- Waits in the Waiting shelf.
- Hover peek, context menus (rename, settle, snooze, archive), drag, and the project filter.

### Terminal thread view (2026-11-04)

The setting `threadView` is `"chat" | "terminal"`, default `chat`. It is a project-scoped server setting, so it works like T3's other settings: set globally or overridden per project, under Settings › Threads › New threads › "Thread view".

**Where it's defined.**
- `packages/contracts/src/settings.ts`: the `ThreadView` schema, the project-scoped key, the overrides, and the patch.
- The settings row is `apps/web/src/components/settings/ThreadViewSettings.tsx`, with search id `thread-view`.

**What the terminal view does.**
- `ChatView` reads the thread's resolved project setting. In terminal mode it renders `components/octet/terminal/AgentTerminalView.tsx` in place of the timeline and composer.
- That component is T3's own `ThreadTerminalDrawer` in panel mode, on one thread terminal with the id `octet-agent`.
- If that terminal isn't already running, it opens it in the thread's folder (or worktree) and types the provider's CLI. The commands are in `agentTerminal.logic.ts`:
  - `claude`, or `claude --resume <session>`;
  - `codex`, or `codex resume <session>`;
  - `cursor-agent`;
  - `opencode`.
- The session id comes from the provider thread's `nativeThreadRef.nativeId`, and only plain ids are allowed into the command line.
- It is a normal T3 thread terminal, so it keeps running when you switch threads or views. With `OCTET_PTY_HOST=1`, it also survives server restarts.

**Verified 2026-11-04.**
- Setting Terminal in the settings page saved `threadView` and turned a Codex thread into the Codex CLI in a terminal.
- Tests cover scope resolution (`packages/shared/src/projectSettings.test.ts`) and the command (`agentTerminal.logic.test.ts`).

**Follow-up the same day.**
- `ThreadTerminalDrawer` has a new `hideActions` prop, so the view drops the split, new, and close buttons.
- The view has an inset in the terminal's own colour.
- A header toggle sits in `PanelLayoutControls` as `threadViewControl`, with a terminal icon. It sets a per-thread override in localStorage (`octet:thread-view:<threadKey>`) on top of the global or project setting, and drops the override when it matches the setting again.
- Verified in a browser: the toggle round-trips, and both the ChatView and terminal drawer tests pass.

**Still not done (superseded):** see "Terminal ↔ chat flip" below, which mirrors the CLI's turns into the chat.

### Status bar and right nav, first slice (2026-11-05)

**Status bar.** `apps/web/src/components/octet/statusBar/` holds `OctetStatusBar.tsx` and `octetStatusBar.logic.ts` (with tests). `ChatView` mounts it under the bottom terminal drawer, at 30px, with a hairline above. Everything is T3's own: its `ProviderInstanceIcon` stack, `PullRequestDiffStat`, `PullRequestChecksPopover`, and its muted-text and hover-fill classes. Chips, each hidden until it has something to say:
- **Agent**: the thread's provider and state, from T3's status pill ("Claude Code idle", "needs you" in amber).
- **Branch**: from the VCS status stream.
- **Changes**: changed files and +/− lines; a click opens the Diff surface.
- **CI**: the branch's pull request checks, red with "N failed"; a click opens T3's checks popover.

Added 2026-11-05:
- **Directory**: the last two folders of the git cwd; a click opens Files.
- **Worktree**: the worktree folder, when the thread runs in one.
- **Pull request**: state glyph and `#N`; a click opens it in the panel.
- **Ports**: the servers the thread started (T3's `useThreadDiscoveredPorts`), as `localhost:3000 +2`; a click opens the first in the browser panel.

Added later 2026-11-05: **Runtime version** (below). Not yet: last command (needs shell integration marks in T3's terminal), merge/rebase state, overflow menu, and the right-hand Awake/memory group.

**Right nav.** Terminals live only in the bottom drawer, and the panel gained CI and Overview.
- **Terminal surface removed.** `terminal` is gone from the surface union, the store (`openTerminal`, `splitTerminal`, `activateTerminal`, `closeTerminal`), the launcher, `PersistentThreadTerminalPanel`, the panel's split/new/close shortcuts, the close-confirmation path in `useRightPanelSurfaceClose`, and `focusActivePanelTerminal`. `migratePersistedRightPanelState` drops any saved terminal surface (its shell keeps running). "New terminal" opens a drawer tab; `revealThreadTerminal` opens the drawer. The drawer code is untouched.
- **CI** (`components/octet/ci/CiPanel.tsx`, launcher key C): the branch's pull request checks, failures first, drawn with T3's checks list.
- **Overview** (`components/octet/overview/`, launcher key O): the thread's agent, then what it is running as a tree (subagents, commands, monitors, background tasks) nested by `parentTaskId`, a Stop / Stop all button, and a "Finished" fold of completed subagents. It reads T3's own `pendingBackgroundTasks` and subagent turn items, so it needs no engine. Subagent rows open their thread.
- Not in Overview yet: the thread's shells (T3 terminals) as rows, and per-task stop. T3 stops all of a thread's background work at once; one task can't be stopped alone.
- **TODO** (`components/octet/todos/`, launcher key U): the project's own list (no agent plan section; Jack removed it 2026-11-05). It is `TODO.md` at the project root (also `todo.md`, `Todo.md`, `TODO.markdown`), read and written through T3's project file RPCs and re-read every 2.5s. Tick an item to rewrite only its line; add one with the input, which creates `TODO.md` if there is none. `projectTodos.logic.ts` is a port of native Octet's `ProjectTodos`.
- Not in TODO yet: the personal "Mine" list, the linked issue and waits, reordering and editing items, handing an item to an agent, the source filter, and other agents' plans (T3 only has the thread's own).
- **Decided 2026-11-05 (Jack): no Containers or Tickets planes in the fork.** The right nav is finished with Overview, TODO, CI and T3's own surfaces.

### Agent tabs (2026-11-05)

`components/octet/tabs/` (`AgentTabBar.tsx`, `agentTabs.logic.ts`): a strip under the thread header showing the agents on the current thread's branch or worktree, which are the threads of its sidebar branch card (same `branchCardKey`). Oldest first so tabs hold their place; settled threads, subagents and side chats are left out, except the one in view. A tab has the provider icon, title and a status dot (working, approval, input, failed...). The plus starts another thread on the same branch/worktree. Tabs use the right panel's tab classes.

Refined 2026-11-05 (below). Not yet: drag to reorder, splits (native `CompanionSplit`), and a tab per terminal agent from the engine.

### Waits (2026-11-05)

A wait is work that can't go on until something outside happens; the server checks the condition and brings the work back.

**Server** (`apps/server/src/waits/`, `mcp/toolkits/waits/`, `packages/contracts/src/wait.ts`, migration `080_Waits`):
- Conditions: a date, a pull request merged (via `PullRequestService`), a URL answering 2xx/3xx, or `manual` (settled by a person).
- A poller on the existing 5s scheduler tick checks only due waits, with backoff (5 min growing to 4 h; failures double the gap up to 12 h). When a wait is ready and `autoContinue` is set, `next` is queued to the origin thread (`ThreadManagementService.sendToThread`); otherwise it waits for Continue.
- RPC (`WS_METHODS.waitsSubscribe/List/Create/Cancel/Resolve`); client atoms `serverEnvironment.waitsLive`, `createWait`, `cancelWait`, `resolveWait`.
- Agent tools (`OctetWaitsToolkit`): `wait_for`, `list_waits`, `cancel_wait`. Origin comes from the invoking thread.
- Tests: 25 for the service, checkers and tools; `reconcileV2PreviewMigration.test.ts` lists migration 80.

**Sidebar** (`components/octet/waits/`): the Waiting shelf lists waits under the snoozed threads, counted with them. A row has the title, the condition in words ("acme/app#12 merged", "staging.example.com up", a date), its state, and Continue (ready with a next step) or "It happened" (manual). Hover shows an X to drop it. Clicking opens the origin thread. Waits come from the first connected environment only.

Not yet: a UI to create a wait by hand (agents create them through the MCP tools), check-ins and project jobs, editing a wait, and waits from more than one environment.

#### Waits: create and edit by hand (2026-11-05)

- **Server:** `WS_METHODS.waitsUpdate` / `WaitService.update` (contract `WaitUpdateInput`, client command `serverEnvironment.updateWait`). It edits title, next step, auto-continue and, while still waiting, the condition; a new condition starts its checking over. A cancelled or carried-on wait is refused, and a ready one can't change what it waits for. Create and update share one validator, `waitProblem`.
- **Web** (`components/octet/waits/`): `WaitDialog` makes or edits a wait in T3's `Dialog`, `Input`, `Select`, `Textarea` and `Switch`: title, when (you say so, a date, a pull request merged, a URL answering), then-step, send-at-once. `NewWaitButton` is the plus for the Waiting shelf's header, setting the wait from the thread in view (it is in its own file so `WaitRows` stays free of thread hooks). A `WaitRows` row shows a pencil on hover that opens the dialog to edit. Form rules are in `waits.logic.ts` (`waitFormProblem`, `waitConditionFromForm`).
- **Not wired:** `NewWaitButton` is not yet placed in the sidebar's Waiting shelf header; the sidebar work owns that.
- **Still not done:** check-ins (recurring waits with quiet hours and stall heuristics, `Shared/CheckIns.swift`, about 900 lines) and project jobs, which would need a recurrence column on `waits` and a migration; and waits from more than one environment.

### Running servers under each card (2026-11-05)

`components/octet/sidebar/` gained `ServicePortsRow.tsx`, `serviceKind.logic.ts` (a port of native `ServiceKind`) and `serviceIconPaths.ts` (Simple Icons paths, inlined in the same way as `components/Icons.tsx`, drawn in `currentColor`, no new dependency). Under each branch card, a row of small buttons shows the logo and port of each server started by any thread on that branch. A click opens it in the browser panel (`openDiscoveredPort`).

It reuses T3's discovered-servers query, so it needs no new server service. T3 reports only the listener's process name, so detection is name, then well-known ports (Postgres 5432, Redis 6379…), then runtime, and unknown listeners get a dot. Native Octet also walks parent processes; add that if names prove too coarse.

### Runtime version chip (2026-11-05)

A status-bar chip with the project's toolchain logo and the version that runs in its folder (`v25.6.1`; hover for "Node v25.6.1, the version that runs in this folder").

- **Contract:** `packages/contracts/src/projectRuntime.ts`; RPC `projects.runtimeVersion` (`WS_METHODS.projectsRuntimeVersion`), scope `AuthFilesystemReadScope`. Result is `{ runtime: { id, name, version } | null }`, and it never fails: no marker file or a failing command gives `null`, so the chip hides.
- **Server:** `apps/server/src/projectRuntime/projectRuntime.ts`, a port of native `ProjectRuntime`. It walks up from the thread's folder to the repo root (the folder holding `.git`) for the nearest marker file (bun lockfile, deno, package.json/.nvmrc → Node, Cargo.toml, go.mod, Python files, Package.swift, Gemfile, mix.exs, pubspec.yaml, build.zig, composer.json), then runs the version command in a login shell (`$SHELL -lc`, so nvm/asdf/mise decide the version; plain command on Windows), 10s timeout, cached 5 minutes per runtime and folder.
- **Client:** `projectEnvironment.runtimeVersion` query atom; the chip sits after the Agent chip in `OctetStatusBar`, drawn with `sidebar/serviceIconPaths.ts` (which gained Rust, Swift, Dart and Zig).
- **Tests:** version parsing (Node, Python, Rust, Go, Swift), marker detection, and a real run against this repo.
- Known unrelated failure: `packages/client-runtime` `remote.test.ts` expects the `T3 Code Mobile` client label, which the rebrand changed.

### Remote Control chip, chip order and visibility (2026-11-05)

**Remote Control chip.** A green dot and "Remote" while the Claude Code CLI in a thread's terminal has Remote Control on (the session is open in claude.ai or the Claude app). Click opens the session's claude.ai link.
- **Server:** RPC `projects.remoteControl` (`{ cwd, pid? }` → `{ active, url }`, scope `AuthFilesystemReadScope`), in `apps/server/src/remoteControl/`. `remoteControlLog.ts` is a port of native `RemoteControlLog`: `/remote-control` writes a `bridge_status` record with the link when it connects; running it again turns it off; records from before the process started belong to an earlier run. `readRemoteControl.ts` finds the folder's newest session log under `$CLAUDE_CONFIG_DIR` or `~/.claude/projects/<cwd, every non-alphanumeric as ->/`, reads its last 4 MB, and uses `ps -o lstart= -p <pid>` for the start time (not on Windows). It never fails: anything unreadable means off.
- **Client:** `projectEnvironment.remoteControl` polls every 5s, and only for a Claude thread that has an `octet-agent` terminal (terminal view), passing that terminal's shell pid. It is the folder's newest log, so two Claude sessions in one folder can be confused. Claude accounts with their own config folder aren't searched.

**Chip order and visibility.** Client settings `statusBarItems` (sparse show/hide by chip id, only choices that differ from the default) and `statusBarOrder` (ids in order; unknown ids dropped, missing ones follow in default order). Same shape as `threadDetailsItems`.
- `statusBar/octetStatusBarItems.ts` lists the chips (agent, remoteControl, runtime, directory, branch, worktree, changes, pullRequest, ci, ports) with their groups; a divider is drawn only where the group changes. `OctetStatusBar` builds each chip, then draws them in the saved order.
- Settings › Appearance › "Status bar" (`settings/StatusBarItemsRow.tsx`): a popover with a checkbox and up/down buttons per chip, and a reset. Right-clicking the bar shows a show/hide menu (`StatusBarItemsMenu.tsx`).
- Not done: drag to reorder, per-project chip sets, a "show only when relevant" mode. Reordering is by up/down buttons.
- Known unrelated failures: `promptStashStore.test.ts` (Node 25's global `localStorage` has no `setItem`) and `client-runtime` `remote.test.ts` (rebranded client label).

### Conversation width: drag the column's edges (2026-11-05)

Native Octet's `ChatColumnEdges`, on T3's existing Chat width setting (`chatWidth`: comfortable / wide / full, which sets `--chat-content-max-width`). `components/octet/chatColumn/` (`ChatColumnEdges.tsx`, `chatColumn.logic.ts`), mounted in `ChatView` for chat-view threads (not terminal view, not embedded).
- A strip just outside each edge of the column. Hovering one shows a grip. Dragging moves the column between its widths as the pointer passes them, both edges at once, since the column stays centred: its width is twice the pointer's distance from the middle, snapped to the nearest width. Escape or leaving the window puts the width back as it was when the drag began; a double-click goes back to the default; with a strip focused, the arrow keys step the width (`role="separator"`, `aria-valuetext`). The choice is the Chat width setting, so it holds for every thread and shows in Settings › Appearance.
- Widths in px (46rem, 72rem, and the window minus 24px gutters). In a window too narrow for two of them to differ, the wider name stands and the drag skips the other; with only one left, no strips are drawn.
- Not copied: native's flick prediction, haptic tick and animated change.
- Tests: snap logic (unit) and a browser test that drags, cancels with Escape, steps with the keys and double-clicks.

### Agent tabs, refined (2026-11-05)

`AgentTabBar.tsx` now uses T3's terminal-drawer tab parts.
- **Width:** a tab is `flex-[0_1_14rem]` between `min-w-24` and `max-w-64`, so a lone tab shows its title (it was capped at 11rem) and many tabs shrink together. The open tab is scrolled into view when there are more than fit; the scrollbar is hidden.
- **Close:** the provider icon is T3's `PanelTabCloseButton`, an X on hover. Middle-click closes too. Closing *settles* the thread (it moves to the Idle shelf, with T3's Undo toast), and if it was the open tab, goes first to the tab before it, else after (`tabAfterClosing`). The only tab can't be closed from the strip.
- **Keys:** roving tabindex, and Left/Right move between tabs (wrapping).
- **Status:** a working agent's dot pulses.
- Tests: `agentTabs.logic.test.ts` (neighbour choice, wrapping, which threads make tabs) and the browser test (closing, middle-click, the only tab, arrows, a lone long title).

### Terminal ↔ chat flip, completed (2026-11-05)

The two views are one session with one driver at a time, so a flip is a hand-over, not just a view switch (`components/octet/terminal/`).

**To the chat** (`useThreadViewFlip.ts`):
1. If the CLI is live in the `octet-agent` terminal (its shell has a child process), stop it cleanly: Escape (interrupts a turn), then Ctrl+C twice (the first only arms the exit), and wait up to 6s for it to exit. This is so the SDK never resumes a session the CLI is still writing to.
2. Ask the server to mirror (`threads.mirrorCli`, below). A toast says how many messages came across.
3. Show the chat. Neither step can keep it from showing.

**To the terminal:** a chat turn in progress is interrupted first (and given 400ms to settle), then the terminal view resumes the session. A flip that stopped the CLI marks the thread (`markCliStoppedByFlip`); the terminal view then types the thread's command (`claude --resume <id>`) into the idle shell it finds, once. Nothing else relaunches the CLI: typing the command into a shell we didn't leave idle could land it in the CLI as a prompt.

**Mirroring** (`apps/server/src/project/AgentSessionMirror.ts`, `cliMirror.logic.ts`, `packages/contracts/src/cliMirror.ts`; RPC `threads.mirrorCli`, scope `AuthOrchestrationOperateScope`):
- Reads the end (8 MB, 4000 records) of the session's Claude log (`$CLAUDE_CONFIG_DIR` or `~/.claude/projects/<cwd>/<session>.jsonl`), parses it with the importer's `parseAgentSessionTranscript`, and adds to the thread the user and assistant messages it lacks, as `message.updated` and `turn-item.updated` events with the next ordinals. A log message already in the thread (same role and whitespace-insensitive text, counted so repeats work) is not added, so turns that began in the chat aren't duplicated; ids are stable, so a repeat write is the same message.
- **Adoption.** A thread with no provider session (it only ever ran in the terminal) has none to read, so the session is the folder's newest log written since the terminal launched (`sinceMs`, from `cliLaunches.ts`). The thread then adopts it: a provider thread with that native id, `activeProviderThreadId` set via `thread.metadata-updated`, and a runtime row with `resumeCursor`, as the importer does. The chat then carries on from the CLI's session, and the terminal resumes it. Only Claude Code (`driver: "claudeAgent"`) is read so far; other agents return `unsupported` and flip without copying.
- Not mirrored: tool calls, diffs and thinking, only the conversation's text. Two Claude CLIs in one folder can be confused when finding a new session.

**Defaults and feel:**
- A thread shows the terminal only when its agent has a CLI (`effectiveThreadView`); otherwise it stays a chat, and the header toggle is disabled with a tooltip saying so.
- Shortcut `thread.toggleView`, default `mod+alt+t` (works with the terminal focused), shown in the header toggle's tooltip, which also says when a hand-over is under way and disables the toggle meanwhile.
- The view is remembered per thread (`octet:thread-view:<thread>`), as before.
- Not done: flipping to chat when the CLI needs approval or finishes (T3 can't see the CLI's prompts), keeping the chat's scroll position across a flip, and mirroring tool activity.
- Tests: pure logic (`threadFlip.logic.test.ts`, `cliMirror.logic.test.ts`), the service against a fixture log with a mocked orchestrator (`AgentSessionMirror.test.ts`, including adoption), and the hand-over order in a browser test (`useThreadViewFlip.browser.test.tsx`).
- Unrelated failures seen: `AgentSessionScanner` symlink test, `shared` `usageFormat` DST test, `promptStashStore`, `client-runtime` `remote.test.ts`.

### Status bar: Awake and memory group (2026-11-05)

The right-hand utilities, drawn at the bar's right edge outside the scrolling chips (`isEndGroup`, group `utilities`). Both are chips in the existing show/hide/order menu (`awake`, `memory`), drawn with T3's chip classes.

- **Memory** (`memory`): resident memory of T3's own processes (the server, its terminals and agents, Electron), plus the open terminal count. It reads the existing resource telemetry stream (`useResourceTelemetry`, `groups.allT3.currentRssBytes`), so there is no new server code. Shows "—" until the first sample, or where the connection lacks diagnostics scope. Not ported: the popover listing each terminal with "Go to".
- **Keep awake** (`awake`): a menu of Off / While agents work, on power / While agents work, on battery too, stored as the client setting `keepAwake` (`off | plugged_in | always`, default `plugged_in` as in native). `shouldHoldAwake` holds only while a thread in that environment is working, and in `plugged_in` mode only when the host power snapshot isn't on battery. The client asks the new RPC `server.keepAwake` every 5s; the server (`apps/server/src/keepAwake/`) runs `caffeinate -i -t 20` (idle sleep only, the display may still sleep) and renews it at 10s, so it lapses by itself 20s after the asks stop. macOS only: elsewhere `supported` is false and the chip is hidden. A green dot shows while held.
- **Limits:** the asks come from the status bar, so the host is only held while a thread view is open; with no window, the lease runs out. Remote environments hold their own host's sleep, not this one's.
- Logic and tests: `octetStatusBarUtilities.logic.ts`, `apps/server/src/keepAwake/keepAwakeLease.test.ts`.

### Sidebar polish (2026-11-05)

All in `apps/web/src/components/octet/sidebar/`, drawn with T3's own parts (preview card, menu, thread action menu, dnd-kit, rename input).

- **Hover peek** (`CardPeek.tsx`): pausing on a card opens T3's preview card to the side, listing every thread on the branch (loudest first, with its status) and the worktree path. Clicking one opens it.
- **Context menu**: right-click a card for T3's own thread menu (`useThreadActionMenu`: rename, settle, snooze, archive, pin, copy, and the rest), acting on the card's newest thread. Rename swaps the title for T3's `ThreadRenameInput` (now exported from `SidebarThreadRow.tsx`).
- **Drag** (`CardActions.tsx`): drag a card onto the Idle shelf to settle it, onto Waiting to snooze it (T3's custom snooze dialog asks until when), or from a shelf back onto the projects to bring it back. These act on every thread on the card. Native Octet's sidebar only accepts dragged tabs, so there is no card-to-card reorder; project order is not reordered by drag (T3's project order isn't used by its sidebar).
- **Project filter** (`ProjectFilter.tsx`): a header menu of checkable projects. It uses T3's stored project scope (`sidebarProjectScopeKeys`), so it follows between T3's sidebar and Octet's, and also narrows the shelves.
- **Waits in the Waiting shelf**: already listed (`WaitRows`, from the waits work); unchanged.
- Pure rules (`planCardDrop`, `projectInScope`, `resolveCardRename`, `peekRows`) are in `octetSidebar.logic.ts` with tests.

Not verified by hand: the native context menu and drag in the running Electron app (only unit tests and component browser tests ran), and dropping a card on Waiting end to end. Not done: multi-select, T3's shortcut-based thread jumps, drag to reorder cards.
