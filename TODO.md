# Terminal TODO

From the terminal audit (2026-09-18), rechecked against the code on
2026-09-22. Ordered by priority: bugs first, then missing features. File
references use Octet's own files. "The surface view" is the embedded
terminal view under `Octet/Terminal/`.

## Bugs

- [x] **1. ⌘V and ⌘A never reach Octet's key hook (high).** Fixed: the surface view's `paste(_:)`, `pasteAsPlainText(_:)`, `pasteSelection(_:)` and `selectAll(_:)` go through `OctetKeyHook` first (SurfaceView_AppKit.swift).

- [x] **2. Paste protection never asks, and "clipboard read: Ask" means Deny (med).** Fixed: an unsafe
  paste (several lines or control characters) asks with its first lines
  shown, and a program's OSC 52 clipboard read asks Allow / Deny, both in
  Octet's dialog; a refusal completes the request empty so it isn't
  asked again. Build-checked only: testing needs the real clipboard.

- [x] **3. Font size changes leave the hidden top row wrong (med).** Fixed: `TopRowClippingView` relayouts on `cellSize` changes (OctetTerminal.swift).

- [x] **4. Bottom anchoring lags output by up to 200 ms (med).** Fixed: it's
  driven by the renderer's tick (output arrived), coalesced to one check a
  frame, with a 1 s timer as a safety net instead of the 0.2 s poll; it
  still stops while the window is hidden, minimized or occluded, and pauses
  while scrolling. The grid metrics are read before any text. Build-checked
  (not launched).

- [x] **5. The prompt line doesn't line up with the terminal grid (med).**
  Fixed: every character sits in its own cell (two for East Asian wide
  and emoji, `CellWidth`), so the caret and selection land by column
  whatever the font's glyph widths; the line stops at the focused pane's
  right edge (from the layout) and scrolls sideways past it; fractional
  font sizes reach the renderer. Still the settings font when none is set,
  but per-cell placement keeps it on the grid.

- [x] **6. Drag and drop, Services and context-menu Paste bypass the prompt line (med).** Fixed: drops,
  Services and context-menu Paste go to the prompt line; an image dropped
  without a file (dragged from a browser) is saved and its path inserted,
  as a pasted one is. Checked with the Debug `drop-image:` step.

- [x] **7. Clicks and scrolling above bottom-anchored content go nowhere (med).** Fixed: `TopRowClippingView.hitTest` returns the surface view for any point in bounds.

- [x] **8. When the terminal client exits, Octet quits (med).** Fixed: with
  one window, a client that exits (crash, detach, upgrade) leaves the app
  up with a "The terminal disconnected" card: Reconnect starts a fresh
  client (a new view generation), Quit quits. With several windows only
  that window closes, as before. Checked by killing the client process;
  Reconnect wasn't pressed in the test.

- [x] **9. The slash menu's "empty prompt" check is guessed from keystrokes (low-med).** No longer applies: `SlashController` was removed when slash commands started coming from the agents themselves (bc9ecc0).

- [x] **10. Text sent to panes can arrive out of order (low).** Fixed: the
  twin's prompts and answers and `SessionStore.runInPane` now write on the
  serial `EngineClient.inputQueue` with the prompt line and pastes.

- [x] **11. Scroll speed may be multiplied three times over (low).** It was:
  measured with a synthetic wheel notch, 9 lines per notch at "3 lines".
  The renderer now uses `mouse-scroll-multiplier = discrete:1`, and one
  notch scrolls exactly the setting (3). Trackpad scrolling is unchanged.

## Missing features

- [x] **12. Find in scrollback (med).** Done: ⌘F's panel searches the whole
  scrollback; the match found is boxed in the terminal (`SearchHighlight`,
  positioned from the real cell size and the bottom-anchoring offset the
  terminal now publishes); ⌘↑/⌘↓ jump between prompts (31); ⌘Home, ⌘End,
  ⌘PgUp and ⌘PgDn scroll to the top, the bottom, a page up and down.
  Checked with the Debug `find:` hook and real key events.

- [x] **13. The terminal context menu is effectively unreachable and thin
  (med).** Fixed: right-click and ⌃-click open Octet's menu (⇧ right-click
  still goes to the program in the pane): Copy (with a selection), Paste,
  Split Right/Down, Toggle Zoom, Close Pane, Find, Open Link or File on
  Screen, Review Changes, Clear Screen. Built in the running app via the
  Debug `menu` step; not opened by a real click. Copying the session
  server's own copy-mode selection still goes through its copy mode.

- [x] **14. No automatic Secure Keyboard Entry at password prompts
  (low-med).** Done: while the pane in front's tty has echo off in line
  mode (sudo, ssh, `read -s`), Secure Keyboard Entry is on with a padlock
  badge, and off as soon as the prompt ends (`PasswordWatcher`, 0.4 s,
  only while Octet is in front). Setting in Terminal. The detection was
  checked on a real pane's `read -s`; the switch itself needs Octet in
  front, so it wasn't exercised by the background test app.

- [x] **15. No bell, desktop notifications, progress or color-change
  handling (low).** Done with an engine patch
  (`scripts/engine-attention-marks.patch`): the session server now emits
  `pane.bell` and `pane.notification` (OSC 9, OSC 777) for every pane, and
  Octet shows a notification as its banner (named after the tab), bounces
  the Dock icon when behind, and rings the bell as a beep in the pane you're
  in or a notice for another. Checked: the events arrive in Octet from a
  real `printf` in a pane. Progress and colour-change reports remain
  unhandled (nothing asks for them yet).

- [x] **16. No URL hover preview (low).** Done: the link under the pointer
  shows at the terminal's bottom left with "⌘-click to open"
  (`HoverLinkPreview`, fed by the renderer's mouse-over-link action). Not
  exercised with a real pointer.
- [x] **17. The prompt line has no mouse integration (low).** Fixed: a click
  on the line moves the caret to the character under the pointer, and the
  pointer hides while typing there when that setting is on.

## From complaints about other terminals (2026-09-25)

Researched from the most-reacted GitHub issues and HN threads for Ghostty,
WezTerm, kitty, iTerm2, Warp, Wave, Zed, cmux, Conductor, Claude Squad,
Claude Code and Codex. Reaction counts are GitHub 👍 as of 2026-09-25. See
`docs/research/terminal-pain-points.md` for the sources.

### Highest priority

- [x] **18. Don't yank the view while an agent streams (high).** Claude Code
  #3648 (836), #826 (822), flicker #769/#1913 (~330 each); Ghostty #10456.
  Done: the session server already keeps a scrolled-back view on the lines
  being read; what was missing was knowing more arrived. A "↓ N new lines"
  pill sits at the foot of a scrolled-back pane and jumps to live
  (`LiveScrollWatcher`, `LiveScrollTracker`, fed by `pane.scroll_changed`).
- [x] **19. Keep the Mac awake while an agent is working (high, small).**
  Claude Code #81832 (its caffeinate gets killed, the Mac sleeps mid-task),
  #21432. Done: `SleepGuard` holds an idle-sleep assertion only while some
  agent is `working` (closed tabs still running count). Settings → Agents:
  Never, When plugged in (default), Always.
- [x] **20. Broadcast a prompt to several panes or agents (high).** Ghostty
  #3227 (405, locked for +1s), cmux #2336, Warp #409; Conductor's
  multi-model mode. Done: palette actions Broadcast to Panes in This Tab /
  Agents in This Workspace / All Agents; the prompt's title names who
  receives it. Agents get `agent.prompt`, falling back to typing; shells get
  a typed line. ⌘⇧I opens straight into it. ⌥⌘I types into every pane of
  the tab live, as iTerm2's broadcast input does, with a banner while it's
  on (checked with real key events).
- [x] **21. Worktree setup: copy env files, run a setup script, give each
  worktree its own port (high).** Conductor HN, Claude Squad #260, the dev.to
  "worktrees don't actually work" post. *Mostly done:* a worktree made from
  Octet gets the main checkout's git-ignored `.env*` files (never
  overwriting), and runs `.octet/setup`, or `conductor.json`'s
  `scripts.setup`, in its pane with `OCTET_ROOT_PATH`, `OCTET_WORKTREE_PATH`
  and `OCTET_PORT` (a block of ten from 3100). Octet asks before a repo's
  script runs the first time. Setting: Advanced → Set up new worktrees.
  Each workspace's listening ports show on its sidebar card, click to open
  (`PortsWatcher`, every 5 s in front, 30 s behind). Worktrees an agent
  makes itself (`claude --worktree`, anything that runs `git worktree add`)
  are caught when a pane first shows up in one made in the last half hour:
  the env files are copied, and a setup script is offered as Run Setup,
  in a tab of its own since the agent has the pane (checked with a real
  launch).
- [x] **22. Checkpoints that rewind code, not just chat (high, large).** Codex
  #9203 (512), #11626 (225); Claude Code #353 (178), #87575 (/rewind misses
  Bash edits). Done: as an agent starts working, Octet snapshots its
  worktree (tracked and untracked, not ignored) through a throwaway index
  into `refs/octet/checkpoints/<worktree>/…`, the last 50 kept; HEAD, the
  index and the stash are untouched. Palette › Restore a Checkpoint lists
  them with how many files differ, restores after asking (removing files
  made since), and offers Undo. About 0.25 s on a 16k-file repo. Each prompt in the
  twin has a restore button (on hover, and in its right-click menu) that
  finds the checkpoint taken as the agent started on it (unit-tested; the
  button is build-checked). Remaining: the conversation rewinding with the
  files.
- [x] **23. Diff review with line comments sent to the agent (high, large).**
  Claude Code #33932 (276), #23626 (141, pick the base branch); Conductor's
  best-liked feature. Done: ⌘⇧R or palette › Review Changes opens the
  focused project's changes over the terminal: against HEAD or since the
  branch left main, new files included, refreshed every 4 s. Click a line to
  leave a note; ⌘↩ sends every note to an agent in the project as one
  message. Files over 3,000 changed lines (or past 20,000 in all) are
  counted, not drawn. Syntax colours, and Commit All with a message once
  there are no notes left. A split view puts old and new side by side
  (removed runs against the lines that replace them; either side takes a
  note), switched in the header and remembered (checked with a real
  launch). Remaining: staging single files or hunks.
- [ ] **24. Multiple accounts per agent (high).** Claude Code #18435 (991),
  #36151 (1023). *Mostly done:* palette Add Claude/Codex Account (its own
  config folder, then a tab to sign in), Use Account for This Project, and
  Settings → Agents → Accounts. Every shell Octet opens in the project (its
  worktrees too) and Octet's own conversations get `CLAUDE_CONFIG_DIR` /
  `CODEX_HOME`; the twin, recovery and activity read transcripts from the
  account's folder; an Account chip shows which is in use; Settings shows
  each account's sign-in ("Signed in · Max"). Octet's Codex conversations
  get it too. Remaining: usage and limits per account (the usage chip
  reads the default sign-in; splitting it means a keychain token and a
  cache per account). Shells the session server opens by itself now get
  the account too: Octet's pane shell wrapper reads a folder → account
  table (worktrees and symlinked paths included).
- [x] **45. Name the skill on a Skill tool row (med, small).** Done: the
  conversation view titles a skill call with the skill's name, its args as
  the line under it, and the twin writes `Skill(frontend-design)` as Claude
  Code does (`SkillCall`).
- [x] **46. Closing the last window can leave Octet stuck quitting (med,
  seen once, unverified).** While testing, a window whose last tab closed
  disappeared and the app stayed running with no window and its 1.5 s
  refresh stalled. `applicationShouldTerminateAfterLastWindowClosed` is true
  and `applicationShouldTerminate` answers `.terminateLater` while
  `ConfirmCenter` draws "Quit Octet?" inside a window, and there's no window
  left to draw it in. Fixed on that reading: with no terminal window
  visible, quitting doesn't ask (nothing is lost; the session keeps
  running). Not reproduced without clicking, so unverified.

- [x] **47. OpenCode drew into a corner after Octet reattached (low, seen
  once).** OpenCode started while the app was running, then the app was
  restarted: OpenCode kept drawing in about a 20-column box at the top left
  of its pane, as if it never heard the size. Found: on attach the client
  started at the surface's stand-in size (800×600 px, 46×15 cells), so
  every pane got resized to 46×15 and back; a program that misses the
  second resize stays small. Fixed: the client starts once the terminal
  has its real size (up to 2 s), so a reattach sends no resize at all
  (checked with a SIGWINCH logger across a real restart). Two apps on one
  session (a Debug run next to the everyday app) did the same thing;
  Debug builds now use `octet-debug`.

### Worth doing

- [x] **25. Clean copy from agent output (med).** Claude Code #18170 (296),
  #5512 (140); Codex #2880 (77). Done: Copy as Markdown / Copy as Plain
  Text on any agent message (right-click, conversation and twin); copying
  from a pane running an agent drops its layout (`CopyTidy`: bullets, the
  indent under them, box edges, trailing spaces), with a setting in
  Terminal. The clipboard step runs only while Octet is in front, so it was
  checked by unit tests, not in the running app.
- [x] **26. View and edit large pastes before sending (med).** Claude Code
  #3412 (309), #23134 (159); Codex #25144 (88). Done: a paste of 25+ lines
  (or 3,000+ characters) into a pane running an agent opens an editable
  preview; Paste (⌘↩) sends it bracketed, so the agent still takes it as a
  paste. Checked end to end in Claude Code with the Debug hook
  (`paste:<file>`, `confirm-paste`). Setting in Terminal.
- [x] **27. Shift+Enter inserts a newline in every agent, over SSH too
  (med).** Warp #6401 (80), Claude Code #16859. Checked on 2026-09-25 with
  real key events through Octet's renderer and the session server
  (`OCTET_DEBUG_KEYS`, Debug builds): Shift+Enter already puts a newline in
  Claude Code and Codex, since the kitty keyboard protocol passes through.
  Without it (a plain program) Shift+Enter is `\r`, as in any terminal.
  Not checked: OpenCode (see 47) and SSH, where the remote end decides.
- [x] **28. Completion escape hatches (med).** Warp #1811 (372), #1909 (269),
  #3675 (96). Done: ⌥⇥ sends Tab straight to the shell's own completion
  past Octet's menu; ⇧⌦ on a suggestion stops Octet suggesting that
  command (with Undo; the shell's history file isn't touched). Octet's
  command line and its completions were already switchable in Settings.
  Unit-tested; the keys weren't pressed end to end. Settings › Accept a
  suggestion with: →, Tab, or either (checked with real keys: in Tab mode,
  Tab takes the suggestion and → only moves).
- [x] **29. Hints mode (med).** Ghostty #2394 (105) and 97 for keyboard URL
  opening; kitty hints, WezTerm QuickSelect. Done: ⌘⇧H (or palette › Open
  Link or File on Screen) labels every link, path with a folder or line
  (`src/app.swift:12:5`) and commit hash in the pane in front; type the
  label to open it (links in the browser, paths in Octet's editor at the
  line, hashes copied), ⇧ with it to copy instead, Esc to leave. Labels
  follow bottom-anchored text. Checked with real pane text; the editor
  opening at the line was checked by the file opening, not the selection
  (the debug capture doesn't draw the editor's text).
- [x] **30. Prune merged worktrees, show disk use per worktree (med).** cmux
  #6510; one report of 256 worktrees using 28 GB. Done: palette › Clean Up
  Worktrees lists the repository's worktrees with merged / uncommitted /
  not merged and their size on disk, and removes merged, clean ones (one or
  all) after asking, through the session server when a workspace is open
  on them. Branches are kept; `git worktree remove` refuses dirty ones.
- [x] **31. Command marks from OSC 133 (med).** Done. The session server
  keeps marks now (`pane.marks`, from the engine patch), and zsh and fish
  in Octet's panes emit them through Octet's shell wrapper
  (`ShellIntegration`: a `.zshenv` that hands straight back to your own
  files, a fish `vendor_conf.d` file; setting in Terminal). ⌘↑/⌘↓ jump
  by the real prompt rows (by prompt shape where a shell has no marks); a
  Last command chip shows "✓ 1.2s" / "✗ 1 · 340ms"; Copy Last Command's
  Output is in the palette and the right-click menu. Checked with real
  zsh: marks, exit codes and a 1.209 s `sleep 1.2`. Not done: folding a
  command's output; bash (its login startup can't be hooked this way).
- [x] **32. Prompt queue (med).** Claude Code #50246 (245), #33323; Codex
  #28864. Done: palette › Queue a Prompt for <agent> for each agent in the
  workspace, including another tab's ("after agent X finishes"); sent when
  that agent is idle or done, one per turn, in order; Queued Prompts lists
  them to cancel. Checked end to end: held while working, delivered on
  finishing. A tab running an agent with prompts waiting shows
  their count next to its name (build-checked only).
- [x] **33. Session title pinning and stable tab order (low-med).** Claude
  Code #2112 (182), Ghostty #3709. Already so: a tab you name keeps its
  name, and nothing reorders tabs or ⌘1–9 but you (checked 2026-09-25:
  every `tab.move` comes from a drag, a menu or the palette).

### Larger bets

- [x] **34. Global hotkey window (med).** WezTerm #1751 (its top issue), cmux
  #2758, Warp #91. Done: Settings › General › Hotkey from any app (off,
  ⌃`, ⌥Space, ⌥⌘T) brings Octet forward from any app, or hides it when it's
  already in front; Carbon hotkeys, so no accessibility permission. A
  shortcut another app holds is reported. Build-checked only. Not done: a
  drop-down window that slides over full-screen apps.
- [x] **35. Scripting: URL scheme and CLI (med).** Ghostty #2353 (257), Warp
  #3364. Done: `octet://open?path=`, `octet://run?agent=&path=&prompt=`
  and `octet://send?text=` (`OctetURL`), and `octet-cli open [folder]`,
  `run <agent> [--in] [--prompt]`, `send <text>` on top of them. A link
  that types into the terminal, or starts an agent with instructions, asks
  first. Parsing is tested; the links weren't opened in a running copy.
  Not done: reading a pane's screen from a script (the session server's
  `pane.read` already does that over its socket).
- [x] **36. Floating popup pane (med).** Ghostty #3197 (242), WezTerm #270.
  Done: palette › Open Popup Terminal and Run in Popup… (lazygit, htop, a
  picker) open a popup pane (80% of the terminal) over the pane in front,
  in its folder, gone when the command exits: a small session-server
  plugin Octet writes to its support folder and links once
  (`PopupTerminal`). Linking and opening were checked against a scratch
  session; the popup wasn't looked at in a running copy.
- [x] **37. Mobile push with approve/deny (med).** Claude Code #29438 (69),
  #28765 (44). Done for the push: Settings › Agents › Notices on your phone
  sends "needs you" (high priority) and "finished" to an ntfy topic while
  Octet isn't in front (`PhonePush`; ntfy.sh or your own server). Off until
  a topic is set. Not done: approve/deny from the phone, which needs a way
  back into this Mac; Claude's Remote Control covers that for Claude.
- [x] **38. Audit timeline (low-med).** Commands and files per agent, with
  `rm -rf`, force-push and `sudo` flagged (cc-audit-log et al.).
  Done: palette › Agent Command Log… lists the shell commands Claude and
  Codex ran in the focused project this week, risky ones marked; a row
  copies its command. Heredoc bodies aren't counted as commands.
- [x] **39. Quick Look for paths agents print (low-med).** Wave's standout;
  Warp #4739 (99), #7115 (78). Done: in hints (⌘⇧H) an image, PDF, media
  or office file opens in Quick Look instead of the editor, and ⌥ with a
  label Quick Looks any file; bare names like `shot.png` get a label too.
  Right-clicking a selected file name offers Quick Look (⌘Y), Open and
  Show in Finder. Checked with a real launch: the panel opens on the file.
- [ ] **40. Best-of-N: one task, several agents, compare diffs (low-med).**
  Builds on 20 and 23.

### libghostty host risks to verify

- [ ] **41. Option-as-Alt left/right actually applies (med).** cmux #2369: it
  worked in Ghostty but was ignored in cmux, breaking ISO layouts. *Partly
  checked 2026-09-25:* Settings writes `macos-option-as-alt = right` (or
  left/true/false) into the renderer config, and keys are translated by
  Ghostty's own handling, not by Octet. Not checked: a real right-Option
  keypress (a synthetic event can't easily carry which Option key), and
  Octet's command line, which reads ⌥ itself at a bare prompt.
- [ ] **42. CJK IME composition, in the terminal and the prompt line (med).**
  Ghostty #12278, #10310, #4634, #7225.
- [x] **43. Pinned GhosttyKit includes the Jan 2026 scrollback leak fix
  (med).** Ghostty #10289 (71 GB with several Claude Code windows).
  Checked 2026-09-25: the pinned manaflow-ai/ghostty commit (4a0e9e1,
  2026-09-17) contains upstream's fixes 9ee78d8 and 17da138 (compare:
  0 behind).
- [ ] **44. Agent status accuracy (med).** cmux #1027: stuck "Running", false
  "Needs input", missed prompts. Needs a regression corpus.

Already covered, for the record: a session manager (Ghostty #3358, 609, their
top request), close protection (closed tabs keep running and reopen with
⌘⇧T), context usage per agent, sticky manual tab names, image paste, and no
account or telemetry (Warp #900, 462).
