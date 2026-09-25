# What a heavy terminal user complains about, and where Octet stands

Source: a survey of 25 videos (of 1,099 listed) from one prolific developer
channel, filtered to terminal emulators, shells, and terminal-based coding
agents. The raw digest with per-video timestamps is kept out of this repo;
this file is Octet's own reading of it. Treat it as one informed person's
opinions, drawn from auto-captions — a strong signal about what irritates
people who live in a terminal all day, not a survey.

## The complaints, ranked by how often they recur

1. **Closed-source agent CLIs** — by a wide margin the most repeated, across
   7+ of the 25 videos. He trusts what he can read and patch.
2. **Opaque subscription rate limits**, inconsistently enforced and poorly
   explained; cited as his reason for switching agents at one point.
3. **Orchestrating many parallel agents is miserable** — terminal plus IDE
   plus browser, tmux breaking down past five or six tasks, and losing track
   of dozens of sessions after a reboot.
4. **An agent's TUI repainting the whole screen** (thousands of lines for a
   screenful), causing lag and flicker. His most technical complaint.
5. **Agent CLIs are buggier than the IDEs they replaced**; pasting an image
   into a terminal UI is unreliable.
6. **Sign-in flows**: a CLI disclosing an IP address by default, embedded
   webviews that password managers can't fill, OAuth in a terminal.
7. **Embedded terminal panes inside other apps** are bad enough to avoid.
8. **A tool imposing its own theme** instead of respecting the terminal's.
9. **Electron**, consistently, as a performance smell.

What he praises: fast native terminal emulators, open-source agent CLIs, terminals and multiplexers
as tools, and moving agent orchestration *out* of the terminal into a GUI.

## What Octet already answers

| Complaint | Octet |
| --- | --- |
| Parallel agents are miserable (3) | The whole point: workspaces grouped by project, per-tab agent state, an idle dock for what's gone stale, one palette across every workspace, tab and agent |
| Losing sessions to a reboot (3) | Session recovery: Octet journals each agent's session id and offers to resume them where they were |
| Embedded panes are bad (7) | Octet is a real terminal, built on the kind of native emulator he praises, not a pane bolted into an editor |
| Electron (9) | Native Swift, with terminal text rendered on the GPU by libghostty. Native isn't automatically fast: smooth scrolling of long, rich text in AppKit is hard, and the native conversation views still have to prove it with long transcripts |
| Closed source (1) | Octet is MIT and public |
| Subscriptions (2) | Octet costs nothing and has no account |
| Sign-in and telemetry (6) | Octet has no account, no sign-in, and no telemetry |

## Things Octet has that he would object to — each already optional

He did **not** criticise notifications, autocomplete popups, or block-style
chrome anywhere in the 25 videos; that is a gap in the evidence, not
agreement. These are the features of ours his stated positions bear on:

| Feature | Setting |
| --- | --- |
| Octet's command line taking the keyboard at a prompt | Settings → Agents → Octet's command line |
| Completion menu and history suggestions | Same toggle; the suggestions are local (history, project files, specs) — no model in the input path, which is exactly his objection to AI in a CLI |
| Agent notices in the corner | Settings → Agents: Octet's notices, system notifications, or none |
| Tabs renaming themselves | Settings → Agents |
| Terminal text anchored to the bottom | Settings → Terminal: Top or Bottom |
| Clipboard confirmations | Settings → Terminal |
| Tips in the sidebar | Settings → General |
| Motion | Settings → Motion, per area |

The one place we contradicted him outright was **theming**: Octet imposed its
own theme set on the whole window. It now follows the terminal's colours
(Settings → Appearance → Follow your terminal's colours, which reads a Ghostty
or `key = value` theme file).

## What this list led to

Shipped since this was written:

1. **Pasting an image into an agent pane** (complaint 5) writes the image to a
   file and pastes the path, which is what agents accept.
2. **Following the terminal's own theme** (8), described above.
3. **Usage and limits in view** (2): Claude and Codex usage, weekly pace, and
   a limit screen with a reset countdown.
4. **An agents board** (3), ⌘⇧A: every running agent sorted by who needs
   you, with its last line and state.

Still open:

5. **Remote sessions in the UI** (the SSH complaint). The engine manages
   machines; Octet only lists and opens them from the palette.
6. **Diff review and commit** for agent changes, which Octet shows only as a
   line count today.

Full-screen repainting (4) looked out of reach from outside the agent, and
was, until the visual twin: agents write their turns to disk as structured
lines, so Octet can draw the conversation itself and never repaint at all. The
twin renders each agent's own idiom — Claude's `●`/`⎿` and `Update(file)`,
Codex's `•` and patches — so what it replaces is the repainting, not the
interface people know.

## A second pass: other terminals' issue trackers (2026-09-25)

A wider sweep of the most-reacted GitHub issues and HN threads for Ghostty,
WezTerm, kitty, iTerm2, Warp, Wave, Zed, cmux, Conductor, Claude Squad,
Claude Code and Codex. The ranked list, with reaction counts, is items 18–44
in `TODO.md`. The strongest signals:

- Agent output yanking the view or flickering is the most-reacted terminal
  complaint anywhere (Claude Code #3648, #826: 800+ each).
- Broadcast input is Ghostty's most-wanted open feature after sessions
  (#3227, 405, locked for +1s).
- Worktrees don't work without their env files, a setup script and their
  own ports: raised in every multi-agent tool's HN thread.
- Rewind that restores code (Codex #9203, 512), diff review with comments
  (Claude Code #33932, 276) and multiple accounts (Claude Code #18435, 991)
  are the big asks Octet doesn't meet yet.
- Octet's persistent workspaces already answer Ghostty's top request, a
  session manager (#3358, 609), and having no account answers Warp's forced
  login backlash (#900, 462).

Sources: github.com/ghostty-org/ghostty/discussions (sorted by top),
github.com/wezterm/wezterm and kovidgoyal/kitty issues by reactions,
warpdotdev/Warp, anthropics/claude-code, openai/codex and manaflow-ai/cmux
issues by reactions; HN 42517447 and 47311129 (Ghostty), 42247583 and
47970622 (Warp), 44594584 (Conductor), 47079718 (cmux), 46368739 (Superset),
45427697 (Sculptor), 44533004 (vibe-kanban).
