# What a heavy terminal user complains about, and where Herd stands

Source: a survey of 25 videos (of 1,099 listed) from one prolific developer
channel, filtered to terminal emulators, shells, and terminal-based coding
agents. The raw digest with per-video timestamps is kept out of this repo;
this file is Herd's own reading of it. Treat it as one informed person's
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

## What Herd already answers

| Complaint | Herd |
| --- | --- |
| Parallel agents are miserable (3) | The whole point: workspaces grouped by project, per-tab agent state, an idle dock for what's gone stale, one palette across every workspace, tab and agent |
| Losing sessions to a reboot (3) | Session recovery: Herd journals each agent's session id and offers to resume them where they were |
| Embedded panes are bad (7) | Herd is a real terminal, built on the kind of native emulator he praises, not a pane bolted into an editor |
| Electron (9) | Native Swift, GPU-rendered text. Worth noting his own team reached for Electron only after a native attempt failed on scrollable-text performance; Herd's GPU terminal engine is the answer to that specific failure |
| Closed source (1) | Herd is MIT and public |
| Subscriptions (2) | Herd costs nothing and has no account |
| Sign-in and telemetry (6) | Herd has no account, no sign-in, and no telemetry |

## Things Herd has that he would object to — each already optional

He did **not** criticise notifications, autocomplete popups, or block-style
chrome anywhere in the 25 videos; that is a gap in the evidence, not
agreement. These are the features of ours his stated positions bear on:

| Feature | Setting |
| --- | --- |
| Herd's command line taking the keyboard at a prompt | Settings → Agents → Herd's command line |
| Completion menu and history suggestions | Same toggle; the suggestions are local (history, project files, specs) — no model in the input path, which is exactly his objection to AI in a CLI |
| Agent notices in the corner | Settings → Agents: Herd's notices, system notifications, or none |
| Tabs renaming themselves | Settings → Agents |
| Terminal text anchored to the bottom | Settings → Terminal: Top or Bottom |
| Clipboard confirmations | Settings → Terminal |
| Tips in the sidebar | Settings → General |
| Motion | Settings → Motion, per area |

The one place we contradict him outright is **theming**: Herd imposes its own
theme set on the whole window, and he wants a tool to follow the terminal's
existing theme. That is worth fixing rather than defending.

## Worth adding, in order of how much pain it removes

1. **Paste an image into an agent pane** (complaint 5). Herd sees ⌘V before
   the terminal does: when the pasteboard holds an image, write it to a temp
   file and paste the path, which is what agents actually accept. A concrete
   fix for a named breakage.
2. **Follow the terminal's own theme** (8). Import from the user's terminal
   config or an existing theme file, instead of only offering Herd's set.
3. **Usage and limits in view** (2). A chip per agent showing what its own
   CLI reports about usage, so a rate limit is visible before it bites.
4. **An agents board** (3). One view of every running agent with its last
   line and state — the thing tmux stops being able to do past six tasks.
5. **Remote sessions in the UI** (the SSH complaint). The engine already
   manages machines; Herd doesn't surface them.

We cannot fix an agent's own full-screen repainting (4) from outside it —
that lives in the agent's client. Worth saying plainly rather than implying
Herd solves it.
