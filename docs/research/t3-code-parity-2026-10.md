# T3 Code parity, October 2026

A feature-by-feature comparison of T3 Code (pingdotgg/t3code at e58a4857, 2026-10-16) with Octet after the `feat/t3-parity` branch. **Done** means Octet now has it. **Adapted** means it's there in Octet's terms. **Skipped** means it isn't, with the reason, so each call can be revisited.

T3 Code is a chat app for agents; Octet is a terminal that hosts them. Where the two differ in kind (threads vs workspaces, a web server vs a native app), the Octet column says how the idea was carried over.

## Right panel ("surfaces" in T3 Code, planes in Octet)

| T3 Code | Octet | Notes |
|---|---|---|
| Tabbed right panel, + menu with letter keys | Done | `Octet/Planes/Planes.swift`. Picker keys: O D F G P L T B M |
| Empty panel "Open a surface" launcher | Done | "Open a plane" |
| Tab chip: icon becomes close on hover, middle-click, context menu (Close / Others / Right / All), drag to reorder | Done | |
| Maximize panel | Done | Covers the terminal without resizing it |
| Toggle panel ⌘⌥B | Done | |
| ⌘T new surface, ⌘W close surface | Skipped | Both are Octet's tab shortcuts; the picker and chip close cover them |
| Reopen closed surface ⌘⇧T | Adapted | Palette: Reopen Closed Plane (⌘⇧T is Reopen Closed Tab) |
| Per-thread panel state | Adapted | Per window and kept across launches; Octet has no threads |
| Proactive panels (open Diff/PR on their own) | Adapted | The Overview plane already opens itself for new runtimes |
| Narrow-window sheet | Skipped | The panel resizes; macOS windows rarely get that narrow |
| Panel animation-speed setting | Adapted | Octet's Motion settings |

## Planes

| T3 Code | Octet | Notes |
|---|---|---|
| Diff: scope (changes, uncommitted, latest turn, turn N), base picker, collapse all, stacked/split, wrap, whitespace, file tree, line comments | Done, mostly | Diff plane: Uncommitted / This Branch, fold and collapse all, wrapped lines, line notes sent to the agent, and a button into the full review (split view and staging live there). Hide whitespace changes (kept across launches) and per-turn scope (Latest Turn, Turn N, from Octet's per-turn checkpoints) too |
| Pull request: header, merge with two-click confirm, merge methods, check out, ⋯ menu, title edit, meta, copy checkout, branches, Summary / Timeline / Code, checks popover, reviewers, labels, description, comments, composer, condensed header | Done | Every gh command verified in a dry run (`OCTET_GH_DRY_RUN`) and against gh's help |
| PR Guide tab (agent-written review guide) | Skipped | Needs T3 Code's guide service; "Explain This PR" asks the agent instead |
| Line comments in the PR Code tab, Viewed toggles | Done | Through `gh api` (REST review comments, GraphQL viewed state) |
| Linked pull requests | Adapted | Pull Requests plane (the repo's open PRs) |
| Files: tree, search, breadcrumbs, file preview | Done | Files open in Octet's editor beside the terminal |
| Terminal surface (with splits) | Done | Terminal plane, several allowed; the drawer is the main one |
| Browser: address bar, profiles, local servers, recording | Done, without recording | Browser plane with local servers from Octet's port watcher; profiles as Default / Private (non-persistent). Recording skipped: needs a capture pipeline Octet doesn't have |
| Device: picker, boot, live stream, touch/keys, rail, tools drawer, setup wizard | Done | Native (simctl + AXe, adb) rather than T3 Code's Node hub. iOS verified on a throwaway simulator; Android verified against a fake SDK; the real SDK is installed but an emulator run is still untested |
| Device 3D bezel, iPhone Duo, Android fold | Skipped | T3 Code's own report rates it high effort, low value |
| Floating device mini-player | Done | A floating NSPanel with its own stream view |
| Device hosts over SSH, agent device MCP tools | Skipped | Octet agents already run AXe/adb in a terminal; "Send Screenshot to Agent" covers the common case |

## Around the panel

| T3 Code | Octet | Notes |
|---|---|---|
| Terminal drawer ⌘J, resize, persisted | Done | Kept alive per workspace, agent suggestions kept |
| Drawer splits and terminal groups | Done | ⌘D / ⌘⇧D / ⌘N / ⌘W while a drawer terminal has the keys |
| Thread details card ⌘⇧B | Done | Details card: folder, branch, changes, PR, servers, agents |

## App-wide look

| T3 Code | Octet | Notes |
|---|---|---|
| Button sizes and variants, press scale, lit top edge | Done | `OctetButton`, `OctetIconButton` |
| Toggle / switch, select, segmented, slider pill | Done | `OctetSwitchStyle`, `OctetSelect`, `OctetSegmented` |
| Inputs with inset focus ring | Done | `OctetTextField` |
| Menus/popovers 10pt, glass dialogs, palette, toasts | Done | `octetGlass` |
| Settings layout (nav, breadcrumb, cards, rows, per-row reset, Restore Defaults, `/` search, colour-scheme tiles) | Done | An in-window page; section inventory differs: Octet's own settings |
| Settings search with jump highlight | Already in Octet | |
| Keybindings editor (record, when-clauses) | Done | Settings › Keyboard |
| Left sidebar rows (cards, status, hover actions), project headers | Done | Octet's workspaces and project groups; favicons kept |
| Inbox shelves (Working / Snoozed / Settled), snooze, auto-settle | Adapted | Snoozed and Idle shelves in the sidebar, plus Waits |
| Top bar breadcrumb | Adapted | Octet's title bar shows the workspace and tab |
| Chat: user bubbles, unboxed assistant, work-log rows, floating composer, round send/stop | Done | |
| Changed-files card in chat, revert to turn | Already in Octet | Rewind and the Git plane's checkpoints |
| Diff colours | Kept Octet's | The theme's own green and red, as asked |
| Usage page, Pull Requests page | Done | Full in-window pages with breadcrumbs |
| Connections (remote environments) | Adapted | Peers, Octet's Mac-to-Mac pairing, redone after it |

## Not applicable

T3 Connect, environments and load balancing, Tailscale/WSL backends, provider instance management, scheduled tasks, SnapShots, theme editor/import. These belong to T3 Code's client/server model, or to features Octet doesn't have.
