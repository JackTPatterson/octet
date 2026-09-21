# Terminal acceptance scenarios

Derived from [corpus.json](corpus.json), collected 2026-09-21. **None executed in this research pass.** Expected outcomes are Octet acceptance targets, not claims about competitor behavior. Use disposable sessions and record environment, actual result and artifacts as described in [README.md](README.md).

## T01: Find output, not just commands

Related observations: P01, P02.

**Steps:** Print 10,000 numbered lines containing a unique marker near the beginning and end, plus ANSI-colored and Unicode matches. In a split, use Cmd+F, paste a marker, then Cmd+G/Shift+Cmd+G and Escape.

**Expected:** Find reaches offscreen matches in the focused pane, accepts paste, distinguishes output search from history/palette search, restores terminal focus, and sends no query text to the shell.

**Result:** Not run.

## T02: Keep the shell in charge of completion

Related observations: P03.

**Steps:** In disposable zsh/bash/fish profiles, configure a custom completion for a fake command. Try Tab with Octet's editor on/off and with history results present. Attempt shell completion while retaining editor features.

**Expected:** Document available controls. Target: independently choose shell completion; Tab and Escape preserve the exact buffered line, with no duplicates or unintended execution. Whole-editor disable counts only as partial coverage.

**Result:** Not run.

## T03: Alias and remote completion parity

Related observations: P04.

**Steps:** In a disposable profile define ll='ls -lh'; create names containing spaces and Unicode. Compare Tab after ll and ls. Repeat with a function and, on a test SSH host, a remote-only file.

**Expected:** Equivalent candidates and correct shell quoting; remote context never uses local files; no freezes. Record shell, dotfiles and versions.

**Result:** Not run.

## T04: Explicit terminal-to-UI transition

Related observations: P05.

**Steps:** Start a supported agent in terminal mode; dismiss the banner, relaunch, and disable offers. Try Switch to Octet UI for idle and working sessions, including missing session IDs.

**Expected:** Current and destination views are understandable. Dismissal/settings persist as documented; working-session interruption is explained; resumed identity is correct; missing IDs visibly start a new conversation rather than claiming successful resume.

**Result:** Not run.

## T05: Remote session workflow

Related observations: P06.

**Steps:** Using a disposable SSH host, connect, split, disconnect the network, reconnect, and relaunch Octet. Try locating/reusing the same host without command history.

**Expected:** Record current raw-SSH behavior separately from a proposed host manager. Target: clear host/cwd identity, honest disconnect state, correct completion context and no local/remote confusion.

**Result:** Not run.

## T06: Provider limits and failure clarity

Related observations: P07.

**Steps:** Use a provider test stub or recorded failure to supply rate-limit, authentication and unavailable-model responses; do not spend real credits to force limits.

**Expected:** Show provider-specific cause and recovery action; retain the unsent draft and conversation. Unknown usage remains unknown; terminal use stays available.

**Result:** Not run.

## T07: Idle and streaming resource baseline

Related observations: P08.

**Steps:** Use a Release build with snapshots off. Measure 10 minutes each: one idle shell, ten idle tabs, hidden window, and one streaming agent. Repeat three times on the same machine with matched terminal controls.

**Expected:** Record hardware/OS/build, app plus engine CPU, wakeups, RSS, energy estimate and latency. Proposed investigation threshold: sustained idle CPU above 2% of one core or monotonic idle RSS growth. Threshold is ours, not a researched product promise.

**Result:** Not run.

## T08: Terminal-only offline experience

Related observations: P09.

**Steps:** With agent integrations disabled and network unavailable, launch, create tabs, run local commands, search history and reopen. Inspect outbound attempts using a local network monitor.

**Expected:** Core terminal works without login or billing prompts. Optional integrations explain their connectivity needs and do not block shell input; record actual network evidence before claiming zero telemetry.

**Result:** Not run.

## T09: Session identity and recovery

Related observations: P10.

**Steps:** In a disposable Octet session, create three workspaces with two panes each and labeled long-running test processes. Quit/reopen the GUI; separately stop the test server; separately simulate machine restart.

**Expected:** GUI reconnect preserves live process IDs. Server/machine loss is distinguished from live reconnect: eligible agent conversations resume with correct IDs/cwds, ordinary processes are not falsely reported as surviving. No duplicates or writes to wrong panes.

**Result:** Not run.

## T10: Every paste path respects buffered input

Related observations: P11.

**Steps:** At an Octet-edited prompt type printf without submitting. Paste harmless text via Cmd+V, Edit menu, context menu and plain-text paste; then try file drop, multiline text, image and Cmd+A. Repeat editor off and in an agent TUI.

**Expected:** Text arrives once in correct order, selection targets the intended surface, paths are quoted, and no command runs until intended. Image-to-path works where supported; unsupported payloads fail visibly.

**Result:** Not run.

## T11: Grid alignment and popup layering

Related observations: P12.

**Steps:** Type ASCII, CJK, combining marks and emoji in narrow splits with long paths. Open completions at the bottom/right edge, resize, change font and display scaling, and test top/bottom anchoring.

**Expected:** Caret matches glyph cells; text and menus stay readable and within intended bounds; no cover stripe, cross-pane painting or clipped input. This session's layering fix still needs visual verification.

**Result:** Not run.

## T12: Streaming, resize and scroll position

Related observations: P13, P16.

**Steps:** In a disposable session, stream numbered output and exercise an agent TUI and native conversation separately. Scroll upward while output arrives, resize repeatedly, change tabs and return to latest output.

**Expected:** Latest output remains reachable; older reading position is preserved until explicitly following output; no duplicated/lost text, persistent flicker or stolen selection. Record agent and renderer versions; do not attribute every redraw fault to the terminal.

**Result:** Not run.

## T13: Dense tabs and standard window behavior

Related observations: P14.

**Steps:** Create 20 labeled tabs across projects. Rename one manually, generate title changes, reorder tabs and drag the window from visible titlebar space at narrow and wide sizes.

**Expected:** Focused tab and project stay identifiable; manual names survive automatic updates; window dragging and tab dragging are distinct; chrome does not consume disproportionate terminal space.

**Result:** Not run.

## T14: Inline graphics and text fallback

Related observations: P15.

**Steps:** Run an inline-image-capable CLI in a disposable session. Display a small image followed by numbered text; scroll, resize and switch tabs. Compare direct renderer capability with Octet's full session path.

**Expected:** Images reserve correct space or a clear text fallback appears; neither terminal text nor prompt is obscured. Pasting an image path and displaying inline graphics are tested separately.

**Result:** Not run.
