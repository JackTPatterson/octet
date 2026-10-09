# Octet UI: what to build next (2026-10-08)

Two passes: an audit of the native conversation view's code (what it does,
where it falls short), and what people ask for in other agents' GUIs
(Claude Code desktop and web, Codex app, Cursor, Zed, Copilot, OpenCode),
from reaction-sorted GitHub issues and changelogs. Reddit and Hacker News
could not be read from here; counts are reactions on the day searched.

## Where Octet stands against the asks

| Ask (evidence) | Octet UI today | Gap |
| --- | --- | --- |
| Per-turn diff review, keep/undo hunks (Claude Code #33932 283, Codex #2998 236) | Diffs per tool card, Session Changes since the start | No "this turn's changes" view, no per-hunk keep/undo; Codex and OpenCode edits show raw JSON, not diffs |
| Edit a past message, rewind, fork (Codex #11626 227, #2948 84) | Rewind and Fork for Claude (Rewind for Pi) from the right-click menu | No editing a sent message; Codex/OpenCode/Qwen have no rewind though Octet's own checkpoints could do it; a restore can't be undone |
| Context and usage always visible (Codex #23794 253, Claude Code #18456 163) | Context meter in the header | Done; per-turn tokens not shown |
| Timestamps (Claude Code #44763 103) | `createdAt` kept, never shown | Easy |
| Keyboard navigation, jump between prompts (Claude Code #18818 64, #16784) | ⌘↑/⌘↓ only in terminal panes | No prompt jumping, ↑ to recall, expand/collapse all, copy last reply |
| Find in conversation (Codex #8591 43) | None; ⌘F is refused while a conversation shows | Missing |
| Editable queue (Codex #45019 64, #28864 25) | Queued messages can be cancelled | Can't edit or reorder |
| Copy as Markdown (Claude Code #859 70, #54670 38) | Per reply, per code block | Done |
| Collapse thinking/tool output with defaults (Claude Code #36006 34) | Thinking collapsed, tools collapsible | No defaults per type, no "collapse all"; long diffs cut at 400 lines with no "show more" |
| Background tasks and subagents (Claude Code #75863 29, #2685 23) | Subagent items indented one level | No grouping or collapse per subagent; resumed conversations drop subagent threads |
| Readable width (Codex #16669 43) | Full width | No max width setting |

## Bugs and debt the audit found

- **Drafts are lost**: the composer's text and images are view state, so
  switching to Review, the editor or the board throws them away (and the
  scroll position and opened cards).
- **The limit splash hides the transcript**, so history can't be read while
  waiting for the reset.
- **Tab with @-file suggestions open** cycles OpenCode agents instead of
  taking the file.
- Dropping a non-image file is silently ignored.
- **Long conversations re-render too much**: every streamed token rebuilds
  the view, re-parses the streaming reply's Markdown, rescans every item for
  suggested commands and compares whole item arrays (images included); every
  row re-renders when a turn starts or ends; tool cards decode their JSON
  several times per draw; images are decoded in `body`.
- Accessibility: no "You"/"Claude" labels on messages, image enlarge isn't
  keyboard-reachable, rewind/fork only by right-click.

## Recommended, in order

1. **Fix the debt that hurts every day**: keep drafts per conversation,
   show the transcript behind the limit card, the Tab/@ bug, file
   attachments as `@path`, and the long-conversation rendering cost
   (cache parsed Markdown and decoded inputs, stop passing `running` to
   every row, cheaper change checks).
2. **This turn's changes, keep or undo per hunk**: a "Changes" strip under
   each finished turn listing the files it touched, opening a review of
   that turn's diff (from Octet's per-turn checkpoints) with Keep / Undo per
   hunk and per file. Real diffs for Codex and OpenCode edits too.
3. **Find and navigate**: ⌘F within the conversation with match stepping;
   ⌘↑/⌘↓ between your messages; ↑ in an empty composer recalls the last
   message; ⌥⌘← / → collapse / expand all; timestamps on hover and between
   turns separated by a gap.
4. **Edit and resend a past message** (rewinds to it, then sends the edit),
   for every agent, using Octet's checkpoints where the agent can't rewind
   itself, with Undo for any restore.
5. **Subagents and background work**: each subagent as a collapsible group
   with its status and a link to its full thread; keep them on resume.
6. **Editable queue**: edit, reorder and send-now on queued messages.
7. **Reading comfort**: a readable-width setting, per-type collapse
   defaults, "show N more lines" on long diffs and outputs.
