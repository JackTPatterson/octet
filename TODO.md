# Terminal TODO

From the terminal audit (2026-09-18), rechecked against the code on
2026-09-22. Ordered by priority: bugs first, then missing features. File
references use Octet's own files. "The surface view" is the embedded
terminal view under `Octet/Terminal/`.

## Bugs

- [x] **1. ⌘V and ⌘A never reach Octet's key hook (high).** Fixed: the surface view's `paste(_:)`, `pasteAsPlainText(_:)`, `pasteSelection(_:)` and `selectAll(_:)` go through `OctetKeyHook` first (SurfaceView_AppKit.swift).

- [ ] **2. Paste protection never asks, and "clipboard read: Ask" means Deny (med).** *Partly fixed.* Done: Multi-line prompt-line text is bracketed, and pasted control bytes are filtered (`PromptLine`). Remaining: `confirmReadClipboard` (TerminalEngine.App.swift) still auto-confirms unsafe pastes and answers OSC 52 reads with nothing. Ask through `ConfirmCenter`.

- [x] **3. Font size changes leave the hidden top row wrong (med).** Fixed: `TopRowClippingView` relayouts on `cellSize` changes (OctetTerminal.swift).

- [ ] **4. Bottom anchoring lags output by up to 200 ms (med).** *Partly fixed.* Done: The poll stops while the window is hidden, minimized or occluded, and pauses while scrolling. Remaining: It is still a 0.2 s timer that reads screen text each tick. Drive it from the engine's wakeup, and check grid metrics before reading text.

- [ ] **5. The prompt line doesn't line up with the terminal grid (med).**
  With no font family set it renders in SF Mono while the terminal uses its
  built-in font, and at the settings size rather than the live size. The
  caret drifts (`caret * cellWidth`), wide characters (CJK, emoji) count as
  one column, and `font-size` truncates 13.5 to 13 (AppSettings.swift). Its
  width comes from the whole window grid, not the pane, so in a split it
  paints over the neighbouring pane, and long commands run past the pane
  edge. Fix: use the terminal's own font, lay glyphs out per cell with
  East-Asian width, clip to the pane rectangle, and wrap or scroll.

- [ ] **6. Drag and drop, Services and context-menu Paste bypass the prompt line (med).** *Partly fixed.* Done: Drops, Services and context-menu Paste go to the prompt line when it's active. Remaining: Dropped images in agent panes don't go through `PasteHandler`'s image-to-path logic.

- [x] **7. Clicks and scrolling above bottom-anchored content go nowhere (med).** Fixed: `TopRowClippingView.hitTest` returns the surface view for any point in bounds.

- [ ] **8. When the terminal client exits, Octet quits (med).** `onExit`
  calls `NSApp.terminate` (RootView.swift), which shows "Quit Octet?" when
  confirm-quit is on; Cancel leaves a dead terminal with no way back.
  Triggers include the session's detach key, a crash, or an upgrade. Fix: a
  "Terminal disconnected. Reconnect" overlay that bumps an `.id` generation
  on `OctetTerminalView`; also disable the detach key in the generated
  session config.

- [x] **9. The slash menu's "empty prompt" check is guessed from keystrokes (low-med).** No longer applies: `SlashController` was removed when slash commands started coming from the agents themselves (bc9ecc0).

- [ ] **10. Text sent to panes can arrive out of order (low).** *Partly fixed.* Done: Prompt-line and paste writes share the serial `EngineClient.inputQueue`. Remaining: `TwinSession` and `SessionStore.runInPane` still write from the global queue. Move them onto `inputQueue`.

- [ ] **11. Scroll speed may be multiplied three times over (low,
  unverified).** Trackpad deltas are doubled, the renderer sends one report
  per row with a wheel multiplier of 3, and the session's
  `mouse_scroll_lines = 3` probably applies per report, about 9 lines per
  notch. The "Mouse scroll lines" setting is then misleading. Fix: set the
  renderer's scroll multiplier to 1 and keep the user's value only in the
  session config.

## Missing features

- [ ] **12. Find in scrollback (med).** *Partly fixed.* Done: ⌘F opens a find panel over the full scrollback (`OutputSearch.swift`), with ⌘G / ⇧⌘G for next and previous. Remaining: Matches aren't highlighted in the terminal, and ⌘↑/⌘↓ (jump to prompt) and ⌘Home/⌘PgUp still do nothing. Map them to `pane.scroll`.

- [ ] **13. The terminal context menu is effectively unreachable and thin
  (med).** The session captures the mouse, so right-click is sent as a mouse
  report; the menu only appears on Shift-right-click, offers only Copy and
  Paste, and Copy doesn't see the session's own selection. Fix: open it on a
  gesture that bypasses capture (⌃-click, or right-click before handing the
  event on) with Paste, Split Right/Down, Zoom, Close Pane, Find, Clear, and
  Copy of the session selection.

- [ ] **14. No automatic Secure Keyboard Entry at password prompts
  (low-med).** Password prompts inside panes (`sudo`, `ssh`) never trigger it.
  Fix: reuse `ShellPrompt`'s tty probe on the focused pane; when echo is off
  and canonical mode is on, enable secure input temporarily with a lock hint,
  and release it when the prompt ends.

- [ ] **15. No bell, desktop notifications, progress or color-change
  handling (low).** These engine actions are unhandled. Fix: at least
  `NSApp.requestUserAttention(.informationalRequest)` or `NSSound.beep()` on
  the bell while inactive. Unverified whether the session forwards BEL and
  OSC 9 to the host.

- [ ] **16. No URL hover preview (low).** The surface publishes `hoverUrl`
  but nothing shows it. Fix: a bottom-left overlay in `RootView` bound to it.
  ⌘-click on links already works.

- [ ] **17. The prompt line has no mouse integration (low).** Keys Octet
  consumes never reach the renderer, so hide-mouse-while-typing never fires
  on the prompt line, and the overlay ignores clicks, so a click can't move
  the caret. Fix: `NSCursor.setHiddenUntilMouseMoves(true)` when the prompt
  line consumes a key (if the setting is on), and map a click's x to a
  column (`(x - origin.x) / cellWidth`) to set the caret.

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
  a typed line. Remaining: a shortcut, and a persistent "broadcasting"
  mode like iTerm2's for typing live into several panes.
- [ ] **21. Worktree setup: copy env files, run a setup script, give each
  worktree its own port (high).** Conductor HN, Claude Squad #260, the dev.to
  "worktrees don't actually work" post. *Mostly done:* a worktree made from
  Octet gets the main checkout's git-ignored `.env*` files (never
  overwriting), and runs `.octet/setup`, or `conductor.json`'s
  `scripts.setup`, in its pane with `OCTET_ROOT_PATH`, `OCTET_WORKTREE_PATH`
  and `OCTET_PORT` (a block of ten from 3100). Octet asks before a repo's
  script runs the first time. Setting: Advanced → Set up new worktrees.
  Each workspace's listening ports show on its sidebar card, click to open
  (`PortsWatcher`, every 5 s in front, 30 s behind). Remaining: worktrees
  an agent makes itself (`claude --worktree`) don't get set up.
- [x] **22. Checkpoints that rewind code, not just chat (high, large).** Codex
  #9203 (512), #11626 (225); Claude Code #353 (178), #87575 (/rewind misses
  Bash edits). Done: as an agent starts working, Octet snapshots its
  worktree (tracked and untracked, not ignored) through a throwaway index
  into `refs/octet/checkpoints/<worktree>/…`, the last 50 kept; HEAD, the
  index and the stash are untouched. Palette › Restore a Checkpoint lists
  them with how many files differ, restores after asking (removing files
  made since), and offers Undo. About 0.25 s on a 16k-file repo. Remaining:
  a restore button on the twin's turns, and the conversation rewinding with
  the files.
- [x] **23. Diff review with line comments sent to the agent (high, large).**
  Claude Code #33932 (276), #23626 (141, pick the base branch); Conductor's
  best-liked feature. Done: ⌘⇧R or palette › Review Changes opens the
  focused project's changes over the terminal: against HEAD or since the
  branch left main, new files included, refreshed every 4 s. Click a line to
  leave a note; ⌘↩ sends every note to an agent in the project as one
  message. Files over 3,000 changed lines (or past 20,000 in all) are
  counted, not drawn. Syntax colours, and Commit All with a message once
  there are no notes left. Remaining: a split (side-by-side) view, and
  staging single files or hunks.
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
  cache per account), and shells the session server opens by itself.
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

- [ ] **47. OpenCode drew into a corner after Octet reattached (low, seen
  once).** OpenCode started while the app was running, then the app was
  restarted: OpenCode kept drawing in about a 20-column box at the top left
  of its pane, as if it never heard the size. Check whether a reattach
  sends a resize (SIGWINCH) to the pane.

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
  Unit-tested; the keys weren't pressed end to end. Not done: rebinding
  which key accepts.
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
- [ ] **31. Command marks from OSC 133 (med).** *Partly done:* ⌘↑ / ⌘↓ in
  a shell pane jump to the previous / next prompt (`PromptJump`), found by
  the shape of the current prompt since the session server keeps no marks;
  checked with real key events. Agent panes keep their own ⌘↑ / ⌘↓.
  Remaining, and needing marks from the session server (Herdr has no
  OSC 133 in its API): copy the last command's output, exit status and
  duration per command, folding.
- [ ] **32. Prompt queue (med).** Claude Code #50246 (245), #33323; Codex
  #28864. Queue per tab, and "after agent X finishes".
- [ ] **33. Session title pinning and stable tab order (low-med).** Claude
  Code #2112 (182), Ghostty #3709. Manual names already stick; keep order
  and ⌘1–9 stable when notices arrive (cmux HN).

### Larger bets

- [ ] **34. Global hotkey window (med).** WezTerm #1751 (its top issue), cmux
  #2758, Warp #91. Summon the agents board over any app.
- [ ] **35. Scripting: URL scheme and CLI (med).** Ghostty #2353 (257), Warp
  #3364; iTerm2's Python API is what switchers miss. `octet://open?path=`,
  `octet-cli run <agent> --in <dir>`, send text to a pane.
- [ ] **36. Floating popup pane (med).** Ghostty #3197 (242), WezTerm #270.
- [ ] **37. Mobile push with approve/deny (med).** Claude Code #29438 (69),
  #28765 (44); ntfy/Pushover hooks exist to fill the gap.
- [ ] **38. Audit timeline (low-med).** Commands and files per agent, with
  `rm -rf`, force-push and `sudo` flagged (cc-audit-log et al.).
- [ ] **39. Quick Look for paths agents print (low-med).** Wave's standout;
  Warp #4739 (99), #7115 (78).
- [ ] **40. Best-of-N: one task, several agents, compare diffs (low-med).**
  Builds on 20 and 23.

### libghostty host risks to verify

- [ ] **41. Option-as-Alt left/right actually applies (med).** cmux #2369: it
  worked in Ghostty but was ignored in cmux, breaking ISO layouts.
- [ ] **42. CJK IME composition, in the terminal and the prompt line (med).**
  Ghostty #12278, #10310, #4634, #7225.
- [ ] **43. Pinned GhosttyKit includes the Jan 2026 scrollback leak fix
  (med).** Ghostty #10289 (71 GB with several Claude Code windows).
- [ ] **44. Agent status accuracy (med).** cmux #1027: stuck "Running", false
  "Needs input", missed prompts. Needs a regression corpus.

Already covered, for the record: a session manager (Ghostty #3358, 609, their
top request), close protection (closed tabs keep running and reopen with
⌘⇧T), context usage per agent, sticky manual tab names, image paste, and no
account or telemetry (Warp #900, 462).
