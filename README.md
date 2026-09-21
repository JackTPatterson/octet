# Herd

A native macOS terminal for running coding agents side by side: Herd's
persistent session server runs every terminal and agent, a GPU terminal engine
renders it, and Herd draws native chrome (project sidebar, top tabs, agent
state and vendor hues). Claude Code subagents open as named background tabs showing
their live transcript. Design and scope: [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 14+, Xcode 26/27, `xcodegen` (`brew install xcodegen`)
- The terminal engine framework in `Vendor/` (prebuilt, not checked in).
- The session server binary in `Vendor/engine/herd-engine`, copied there by
  `scripts/fetch-engine.sh` (from the Homebrew install by default, or from a
  path you pass). The build bundles it into Herd.app as
  `Contents/MacOS/herd-engine`, so users install nothing else.

## Build and run

```sh
scripts/fetch-engine.sh
xcodegen generate
xcodebuild -project Herd.xcodeproj -scheme Herd -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Herd.app
```

Tests: `xcodebuild -project Herd.xcodeproj -scheme HerdCore -derivedDataPath build/DerivedData test`

Herd runs its own named session (`herd-engine --session herd`) with a managed
config in `~/Library/Application Support/Herd/terminal.toml`, so a standalone
session elsewhere is unaffected. Workspaces persist in that session across
relaunches.

## Subagent tabs

The palette action **Install Subagent Tabs Hook** (or
`Herd.app/Contents/MacOS/herd-cli install-subagent-hook [agent]`) adds a
`PreToolUse` hook for `Agent|Task` to each installed agent's own config
(`~/.claude/settings.json`, `~/.codex/hooks.json`), keeping a
`.herd-backup` beside it. Agents share the hook format, so supporting another
one is a row in `SubagentHookInstaller.specs`. The hook does nothing outside
Herd panes. Reinstall after moving Herd.app, since it stores the herd-cli path.

## Agents

Nothing in Herd is tied to one vendor. Agents keep their config in
`~/.<agent>`, with `skills/` and a prompts folder, so Herd discovers whichever
are installed (Claude Code, Codex, Qwen, Kiro, Copilot, …) and treats them
alike: the shared library installs into each, the slash menu reads each one's
own commands, recovery resumes each with its own resume command, and a
capability flag decides whether Herd drives its `mcp` and `plugin` CLIs.

## Command palette

⌘P (or ⌘⇧P, or click the title bar search) opens a palette that
fuzzy-searches everything:

| Filter | Prefix | Contents |
| --- | --- | --- |
| Actions | `>` | every command (tabs, panes, workspaces, worktrees, sidebar, terminal config, Claude hook), with shortcuts |
| Workspaces | `%` | all workspaces with project, branch, and agent state |
| Tabs | `#` | tabs across all workspaces, including subagent tabs |
| Agents | `@` | running agents; jumps to their pane |
| Projects | `/` | folders under ~/Developer, ~/Projects, ~/code, ~/src; opens or focuses a workspace |
| Plugins | `!` | session plugin actions and panes, enable/disable, logs, unlink/uninstall, install from GitHub, link a local folder |

↑↓ or ⌃N/⌃P to move, ↩ to run, ⇥ to cycle filters, esc to close. With an empty
query it shows your 3 most recent picks first. Rename Tab/Workspace and New
Worktree ask for text inline.

## Plugins

Herd runs session plugins (event hooks, startup commands, panes, link
handlers) unchanged, since the session server owns them. The palette's `!`
filter adds what the server's hidden text UI would otherwise provide: invoke
plugin actions (with the focused workspace/tab/pane as context), open plugin
panes, enable/disable, browse run logs, and install from GitHub after
reviewing the install preview in a confirmation dialog. Plugins that only
render into the server's text sidebar have no effect in Herd; Herd's native
sidebar covers that.

## Session recovery

Herd journals every agent pane it sees (agent, session id, working folder,
workspace and tab labels) to `~/Library/Application Support/Herd/agent-sessions.json`.
Session ids come from the session server's integration when one is installed
(Settings → Agents & Recovery), and otherwise from the agents' own files:
Claude's transcripts under `~/.claude/projects`, Codex's `session_meta`
rollouts under `~/.codex/sessions`.

When a shutdown, crash, or session server restart kills sessions that were running the
last time Herd looked, a panel in the bottom right lists them and resumes the
ones you pick with `claude --resume <id>` / `codex resume <id>` in their own
workspaces, recreating a workspace that is gone. Each row can also copy its
resume command. The palette's **Recover Agent Sessions…** lists past sessions
at any time. Settings → Agents & Recovery turns the offer off.

## Marketplace

⌘⇧M (or the palette's **Marketplace…**) opens one window for every agent on
the machine:

| Section | Source | Installs into |
| --- | --- | --- |
| MCP Servers | `claude mcp list`, `codex mcp list` | `claude mcp add` / `codex mcp add`, from one definition |
| Plugins | `<cli> plugin list --json --available` across all configured marketplaces | `<cli> plugin install` |
| Skills | `~/.agents/skills/<name>/SKILL.md` | symlinked into each agent's `skills/` |
| Prompts | `~/.agents/prompts/<name>.md` | symlinked into `~/.claude/commands` and `~/.codex/prompts` |

A chip per agent shows where each item is installed; clicking it adds or
removes it there. Skills and prompts are vendor-neutral: they live once in the
shared library and are linked into each agent, so an edit reaches all of them.
Herd can adopt skills and prompts an agent already had, import a folder of
prompt files, and send a prompt straight to a running agent
(the session server's `agent.prompt`).

### Hot swap

New MCP servers and plugins only load when an agent starts, so after a change
the Marketplace offers **Reload Agents**: each running agent is relaunched in
its own tab with `--resume`, keeping the conversation. Agents whose session id
Herd doesn't know yet, or whose tab is split across panes, are skipped and
named. Also in the palette as **Reload Running Agents**.

## Slash menu

Typing `/` at an empty agent prompt opens Herd's own command menu instead of
the agent's in-terminal list: the agent's built-ins, your own and the
project's prompt files, and every installed plugin's commands, fuzzy
searchable. Herd replaces the prompt for these, so ↩ **runs** the command;
⌘↩ types it without running, and esc passes through what you typed.

Commands with arguments open a submenu filled from what the machine actually
has: `/mcp` lists your configured servers, `/model` your agent's models (and
each model's reasoning levels), `/resume` the sessions Herd can resume,
`/agents` and `/output-style` what's on disk. Prompt files in folders nest as
`/git` → `amend`, and a plugin with several commands gets its own submenu. →
opens one, ← goes back. A command that still wants free text is always typed,
never run blind.

Settings → Agents & Recovery turns the menu, or just the running, off.

## Tab names that follow the work

Agents and shells publish what they're doing as the terminal title, so Herd
renames a tab to match once the title holds still for a couple of seconds:
switch task inside a workspace and the tab stops reading as the task you
started with. A tab you rename yourself is never renamed again, and split
tabs are left alone. Settings → Agents & Recovery turns it off.

## Confirmations

Herd asks in its own dialog rather than a system alert, themed with the rest
of the window: quitting, closing idle workspaces, reloading agents, removing
a plugin, resetting settings, and the plugin install preview all use it.

## Pasting an image to an agent

⌘V with an image on the clipboard writes it into
`~/Library/Application Support/Herd/pasted` and types the path into the pane,
because a path is what agents read and binary is what terminals mangle. A
file copied in Finder pastes its own path instead of being rewritten. Herd
keeps the last fifty and drops the rest. Settings → Agents turns it off, and
text pastes are untouched.

## Herd's command line

At a bare shell prompt, Herd takes the keyboard and edits the line itself:
the command is highlighted as you type, a greyed-out
suggestion from your history follows the caret, and the finished line goes to
the shell on Return. Everything a shell's own editor offers is here: word
moves and deletes (⌥←/→, ⌥⌫), ⌃A/⌃E, ⌃U/⌃K/⌃W, ↑/↓ through matching history,
→ or ⌃F to take the suggestion, ⌥→ for one word of it.

It only ever runs while the pane's foreground process is its own shell, which
Herd reads from the engine rather than guessing, so an agent, an editor or a
pager always gets your keys. Anything Herd doesn't handle (Tab, a control
key it has no meaning for, Escape, losing the window) hands what you typed
straight to the shell and steps aside, so nothing can be trapped in it.
Settings → Agents turns it off.

History comes from the shells' own files (zsh, bash and fish formats), ranked
by how often and how recently you have run each command.

**Completions.** Tab opens a menu for the word under the caret, built from
what the machine actually has: executables on PATH and shell builtins in
command position; this folder's files and directories; a command's
subcommands; the flags that command has been given before; this repo's
branches after `git switch`, `checkout`, `merge` and `rebase`; and whole
lines from history. ↑/↓ move, Return or Tab accepts, Escape closes the menu
without giving up the line. When Herd has nothing to offer, Tab goes to the
shell so its own completion still works.

**Where the completions come from.** Herd blends four sources, all local and
all instant: command specs (subcommands, options and their descriptions),
this folder's own scripts and targets (`package.json`, `Makefile`,
`justfile`, compose services, your shell and git aliases), your history
ranked by frecency, and what usually follows what: a sequence table built
from history, so after `git add .` the line already reads your usual commit.
Values that have to be live (branches, npm scripts, running containers)
come from short generator commands whose output is cached per folder, so
typing never waits on a process.

Herd ships specs for a handful of commands; **Settings → Agents → Command
specs** installs hundreds more from the MIT-licensed Fig corpus
(`withfig/autocomplete`), converted into Herd's own format on your machine.
The corpus is fetched on request rather than bundled, and its licence and a
notice are written beside it. Everything else works without it.

**Editing.** ⌃R searches history in the same menu. ⇧ with the arrows selects,
⌘C/⌘X/⌘V copy, cut and paste, ⌘A selects the line, and ⌘Z/⇧⌘Z undo and redo.

## Terminal text position

Settings → Terminal chooses where a pane's output sits while it doesn't fill
the pane: **Bottom** keeps the prompt at the foot of the pane, and **Top** is how a terminal normally fills from the first row. Herd
bottom-anchors by moving the surface, never by resizing the grid, so the
shell never reflows; the drop only applies while every row below the cursor
is blank, which also leaves split panes alone.

## Branches in the sidebar

A workspace card shows the space and what is running in it; the branch sits
in its own small chip below. Spaces that share a branch (or a worktree)
stack together under one chip rather than repeating it, with a count when
there are several.

## Agent notices

When an agent stops working (it finished, or it is waiting on you), Herd
slides a notice into the window's top right, tinted with that agent's colour
and naming the tab, how long it worked, and which agent it was. Click one to
jump to that pane; they stack up to three and fade after eight seconds. Work
you are already watching never interrupts you: a notice is skipped when Herd
is active and that tab is on screen. Settings → Agents & Recovery switches
between Herd's notices, system notifications, and none.

## Clipboard

Copying looks identical whether or not it worked, so Herd confirms it in its
own toast with a line of what landed there. The session server publishes no
clipboard event, so Herd watches the pasteboard while it is the active app,
which catches every route: copy-on-select, ⌘C, copy mode, and plugins.
Settings → Terminal turns it off. (If your agent notifications are set to
"system", the session server may also post its own notification for copies
made in copy mode; setting notifications to Herd or off leaves only this
toast.)

## Toasts

Actions whose result isn't immediately visible or that take time show a
progress toast (after 200 ms) and a confirmation or failure toast: plugin
install (download → preview dialog → install), uninstall (with confirmation),
enable/disable, link/unlink, plugin action runs (tracked until the command
finishes), new worktree, terminal config reload, and the Claude hook. Instant,
visible actions (tabs, panes, workspaces, renames) stay silent unless they fail.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘P | Command palette |
| ⌘O | Open folder as workspace |
| ⌘D / ⌘⇧D | Split pane right / down |
| ⌘⇧↩ | Toggle pane zoom |
| ⌘⌥←↑→↓ | Focus pane in direction |
| ⌘T / ⌘W | New / close tab |
| ⌘1…⌘9 | Tab 1–9 (9 = last) |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌃⌘↑ / ⌃⌘↓ | Previous / next workspace |
| ⌘N | New workspace |
| ⌘B | Toggle sidebar |

## License

MIT, see `LICENSE`. Third-party notices: `Herd/Resources/ThirdPartyNotices.txt`
(bundled in the app as `Contents/Resources/ThirdPartyNotices.txt`).

## Debugging

`HERD_SNAPSHOT_DIR=/tmp/snap open -n --env HERD_SNAPSHOT_DIR=/tmp/snap Herd.app`
writes `window.png` and `terminal.txt` every second (no Screen Recording
permission needed).
