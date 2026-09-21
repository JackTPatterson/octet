# Agent driver spike

Answers phase 0 of `docs/NATIVE-AGENT-UI.md`: can Octet drive Claude Code
headless well enough to draw a native conversation UI? Run 2026-09-19 against
Claude Code 2.1.277, Haiku, from a scratch folder.

- `driver_a.py`: driver A. Spawns `claude -p --input-format stream-json
  --output-format stream-json --verbose --include-partial-messages` with
  `--session-id`, `--mcp-config` and `--permission-prompt-tool
  mcp__octetperm__approve`, then runs every scenario through one long-lived
  process. `SPIKE_ONLY=perm` runs just the permission turns.
- `perm_server.py`: the permission tool as a minimal stdio MCP server. It
  allows by default and denies commands containing "deny", logging each
  request. In Octet this becomes a `octet-cli` subcommand relaying to the app.

Run: `SPIKE_WORKDIR=<scratch dir> python3 driver_a.py` from that directory.

## Results (driver A)

| Scenario | Result |
| --- | --- |
| Startup | The `init` message only arrives after the first user message is written, 3.7 s later |
| First turn, cold | 7.5 s to first token |
| Second turn, same process | 1.6 s to first token |
| Tool call with a permission prompt | The tool received `{"tool_name":"Bash","input":{"command":"touch spike-allowed.txt","description":"Create a file called spike-allowed.txt"},"tool_use_id":"toolu_..."}`; answering `{"behavior":"allow","updatedInput":...}` ran it |
| Denied tool call | `{"behavior":"deny","message":"..."}` blocked it (no file), Claude relayed the message, and `result.permission_denials` counted 1 |
| Harmless commands | `echo` never reached the permission tool: Claude Code approves read-only commands itself |
| Interrupt | SIGINT ends the current turn (`result` subtype `error_during_execution`) and the process stays alive for the next message |
| Resume in a new process | `--resume <session-id>` kept the context, 6.9 s to first token |
| Usage | The first turn of the first run cost $0.11 at list price, nearly all of it caching the system prompt. A second run within the hour started at $0.006 because that cache was still warm (about a one-hour lifetime). Later turns cost about $0.006 each |

Not measured: time to first token in the interactive TUI for comparison (it
needs a pty harness).

## Driver B (Agent SDK helper): not viable to bundle

`@anthropic-ai/claude-agent-sdk` 0.3.278 installs 258 MB, of which 208 MB is
its own copy of the Claude Code binary. Its `LICENSE.md` reads "© Anthropic
PBC. All rights reserved. Use is subject to the Legal Agreements", so an MIT
app published on GitHub can't redistribute it or the binary. It could run
against the user's own install (`pathToClaudeCodeExecutable`) only if the user
also installs Node and the SDK. Its extras over driver A (`setPermissionMode`
and `setModel` without a restart, `canUseTool`) don't justify that.

## Conclusion

Use driver A. Everything the MVP needs works with documented flags and
nothing bundled:

- multi-turn: one long-lived process per conversation, started when the
  composer opens, so the 3.7 s startup overlaps with typing
- permissions: the MCP permission tool, served by `octet-cli`, relaying to a
  native sheet
- interrupt: SIGINT, keeping the process
- permission mode change: restart with `--resume` and `--permission-mode`;
  cheap within the hour because the prompt cache stays warm
- model and effort: `/model` and `/effort` sent as prompts
