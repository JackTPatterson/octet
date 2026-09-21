# Native agent UI (the visual twin): scope

Scoped 2026-09-18 against Claude Code 2.1.277 and its CLI reference
(code.claude.com/docs/en/cli-reference). Claude Code first; other agent CLIs
later behind the same driver interface.

## Where it stands

The twin today is read-only. `Shared/TwinTranscript.swift` parses the JSONL
transcript an agent writes while its TUI runs in a pane (Claude Code and
Codex formats, one model: messages, thinking, tool calls and results, model,
folder, token usage). It can't send a prompt, answer a permission request, or
interrupt.

## The move

Herd drives the agent headless over its structured stream and draws the whole
conversation natively. No TUI means no full-screen repainting, the heaviest
technical complaint in `docs/research/terminal-pain-points.md`.

## What was verified

A live `claude -p --output-format stream-json --verbose
--include-partial-messages` run (Haiku, no tools) showed:

- **The first message** (`system/init`) lists everything a native composer
  needs: `model`, `permissionMode`, `slash_commands` and
  `terminal_slash_commands`, `skills`, `agents`, `tools`, `mcp_servers` with
  connection status (for example `needs-auth`), `session_id`, and
  `capabilities` (`interrupt_receipt_v1`, `interrupt_cancel_queued_v1`,
  `msg_lifecycle_v1`).
- **Streaming:** `stream_event` deltas (`message_start`, `content_block_*`,
  `message_delta`), then full `assistant` messages.
- **The final `result`** carries `total_cost_usd`, `usage`, and `modelUsage`
  with `contextWindow` and `maxOutputTokens`, plus `subagent_stats`,
  `permission_denials` and `terminal_reason`.
- **The user's hooks run** (`hook_started`, `hook_response`), so behavior
  matches the TUI.
- **Startup cost:** a fresh process wrote about 43,000 tokens of system
  prompt to the cache before replying ($0.087 at list price, billed to the
  subscription since `apiKeySource` was `none`).
- **Budget cap:** `--max-budget-usd` is checked after a turn, so a turn can
  overshoot it.

From the documentation:

| Need | Documented | Supported way to do it |
| --- | --- | --- |
| Many turns in one process | Yes | Write `{"type":"user","message":{"role":"user","content":...},"parent_tool_use_id":null}` lines to stdin with `--input-format stream-json` |
| Nested subagent threads | Yes | `--forward-subagent-text`; group by `parent_tool_use_id` |
| Permission prompts answered by the host | No, for the stdio control protocol | `--permission-prompt-tool <mcp tool>`: a small MCP server in `herd-cli` receives each prompt and relays it to the app |
| Interrupt a turn | No | SIGINT the process: the spike showed it ends the turn and keeps the process for the next message |
| Change model or effort mid-session | Partly | `/model <name>` and `/effort <level>` sent as prompts work in print mode |
| Change permission mode mid-session | No | Restart with `--resume` and `--permission-mode` |
| Background session list | No, for the JSON shape | `claude agents --json [--all]` exists; parse defensively |

## Two ways to drive it

- **A. Direct CLI.** Herd spawns `claude` and uses only the documented
  surface above. No extra runtime. Permission mode changes mean a restart
  with `--resume`, which is cheap while the prompt cache is warm.
- **B. Agent SDK helper.** A small bundled helper built on Anthropic's Agent
  SDK, which officially supports permission callbacks (`canUseTool`),
  interrupt, `setModel` and `setPermissionMode`. Costs a Node or Bun runtime
  in the app bundle and one more process hop.

**Decision (after the spike, see `Spikes/AgentDriver/README.md`): driver A.**
Multi-turn stdin, the MCP permission tool (allow and deny both verified),
SIGINT interrupt (ends the turn, keeps the process) and `--resume` all work
with documented flags and nothing bundled. Driver B is out: the Agent SDK and
the Claude Code binary it ships are proprietary ("All rights reserved"), so an
MIT app can't redistribute them. Keep one `AgentDriver` protocol (start, send,
interrupt, answer permission, set model, set mode, event stream) so other
CLIs can slot in later.

## Feature map

| Area | CLI surface | Native UI |
| --- | --- | --- |
| Sessions | `-c`, `-r <id or name>`, `--fork-session`, `-n`, `/rename`, `--session-id` | New, continue, resume and fork; names. Herd assigns the session id up front, so recovery is trivial |
| Composer | `--model`, `/model`, `--effort`, `--permission-mode`, `--agent`, `--add-dir`, `-w` (including `#<PR>`) | Model, effort, mode and agent pickers; extra folders; worktrees |
| Input | Image content blocks; `slash_commands`, `skills` from init; `--prompt-suggestions` | Image attachments (reuse `ImagePaste`); Herd's native slash and skill menu; suggested next prompts |
| Conversation | `stream_event` deltas, thinking blocks, tool use and results, `--include-hook-events` | Streaming text, collapsible thinking, tool cards (Edit and Write as diffs, Bash with output, Read collapsed), quiet hook activity |
| Subagents | `--forward-subagent-text`, `parent_tool_use_id` | Nested threads; replaces the `agent-watch` subagent tabs |
| Permissions | `--permission-prompt-tool` (A) or `canUseTool` (B) | Approval sheet with a diff preview; Allow once, Always, Deny with a note |
| Usage | `result.total_cost_usd`, `modelUsage.contextWindow`, `--max-budget-usd`, `claude auth status` | Context meter, per-session cost, optional budget, account chip |
| MCP | `init.mcp_servers`, `claude mcp login <name>` | Status chips with Sign in |
| Background agents | `--bg`, `claude agents --json --all`, `stop`, `respawn`, `rm`, `logs`, `daemon status` | Agents board with state, last line and actions |
| Maintenance | `claude doctor`, `auth login` and `logout`, `update`, `project purge` | Diagnostics sheet, account actions, update, purge behind a confirmation |
| Escape hatch | `claude --resume <id>` | "Open in terminal" runs the session in a pane for TUI-only commands (`terminal_slash_commands`) and anything the native view doesn't cover yet |

The read-only twin stays for sessions started in a terminal or in the
background.

## Phases

0. **Spike: done (2026-09-19).** Driver A verified; driver B ruled out by
   license. Measured: 3.7 s startup, 7.5 s cold and 1.6 s warm to first
   token, 6.9 s on resume. Still to measure: time to first token in the
   TUI for comparison.
1. **MVP.** A native conversation tab: new, continue and resume; streaming
   text; collapsed tool cards; permission sheet; interrupt; model, effort and
   mode pickers; cost and context meter; "Open in terminal".
2. **Rich rendering.** Diffs, Bash output, task lists, subagent threads,
   images, prompt suggestions, the slash and skill menu, hook activity.
3. **Sessions and agents board.** Session picker, background agents,
   worktrees, names.
4. **Account and config.** Auth, MCP status and sign in, doctor, update;
   fold in the existing Marketplace.
5. **Other CLIs.** `TwinConversation` is already agent-neutral and parses
   Codex transcripts; a Codex driver slots in behind `AgentDriver`.

## Risks

- **Undocumented surfaces drift between versions** (stdio control messages,
  the `agents --json` shape). Use documented pieces or the SDK only, parse
  defensively, and gate features on `claude --version`.
- **A process per conversation.** A fresh process takes about 3.7 s to
  start and, the first time within an hour, pays the system prompt cache
  write ($0.11 at list price in the spike; $0.006 when the cache was warm).
  Keep one long-lived process per conversation and start it when the
  composer opens.
- **The user's configuration applies.** Hooks, MCP servers and skills load
  as in the TUI, which is the right parity.
- **Branding.** The no-third-party-names rule covers terminals. The agent's
  own mark on its chip stays, since the user picked that agent.
