# Terminal TODO

From the terminal audit (2026-09-18). Ordered by priority; bugs first, then
missing features. File references use Herd's own files; "the surface view"
is the embedded terminal view under `Herd/Terminal/`.

## Bugs

- [ ] **1. ⌘V and ⌘A never reach Herd's key hook (high).** The Edit menu
  takes ⌘V first and pastes straight into the terminal, so image paste
  (`PasteHandler`) and the prompt line's paste never run. With the prompt
  line active, pasted text reaches the shell ahead of the held line and the
  command comes out garbled. ⌘A selects the terminal instead of the line.
  Fix: route inside the surface view's `paste(_:)` and `selectAll(_:)`
  actions (`HerdKeyHook.paste()` runs `PasteHandler`, then inserts into the
  prompt line when it's active), so menu, context menu and keys agree.

- [ ] **2. Paste protection never asks, and "clipboard read: Ask" means
  Deny (med).** Unsafe bracketed pastes (the injection case) are confirmed
  automatically, and OSC 52 clipboard reads under the default `.ask` are
  silently answered with nothing. The prompt line also sends multi-line
  pastes unbracketed. Fix: ask through `ConfirmCenter`, completing the
  request with the text on OK and empty on Cancel; use the same dialog for
  clipboard reads and multi-line prompt-line pastes.

- [ ] **3. Font size changes leave the hidden top row wrong (med).**
  `TopRowClippingView` (HerdTerminal.swift) only relayouts on frame or
  backing changes, so after a font change the engine's tab row peeks through
  or the first content row is clipped until the next resize. Fix: subscribe
  to the surface's `cellSize` and set `needsLayout`. (⌘=/⌘-/⌘0 are now
  Herd menu items, so this is only the relayout.)

- [ ] **4. Bottom anchoring lags output by up to 200 ms (med).** A 0.2 s
  timer polls the cursor row, so every command's output visibly jumps, and
  the timer reads screen text on the main thread 5 times a second forever,
  even when the window is hidden. Fix: recompute from the engine's wakeup
  path (coalesced), read the cursor row from grid metrics first, and skip
  work when the window isn't visible.

- [ ] **5. The prompt line doesn't line up with the terminal grid (med).**
  With no font family set it renders in SF Mono while the terminal uses its
  built-in font, and at the settings size rather than the live size. The
  caret drifts (`caret * cellWidth`), wide characters (CJK, emoji) count as
  one column, and `font-size` truncates 13.5 to 13 (AppSettings.swift). Its
  width comes from the whole window grid, not the pane, so in a split it
  paints over the neighbouring pane, and long commands run past the pane
  edge. Fix: use the terminal's own font, lay glyphs out per cell with
  East-Asian width, clip to the pane rectangle, and wrap or scroll.

- [ ] **6. Drag and drop, Services and context-menu Paste bypass the prompt
  line (med).** Dropped paths go straight to the pty, landing ahead of the
  typed text. Fix: in those entry points, insert into the prompt line when
  it's active; for agent panes, reuse `PasteHandler`'s image-to-path logic.

- [ ] **7. Clicks and scrolling above bottom-anchored content go nowhere
  (med).** Above the moved-down stage, hit testing returns
  `TopRowClippingView` itself, so the click doesn't focus the terminal and
  the scroll wheel never reaches the session. Fix: override `hitTest` in
  `TopRowClippingView` to return the surface view for any point in bounds.

- [ ] **8. When the terminal client exits, Herd quits (med).** `onExit`
  calls `NSApp.terminate` (RootView.swift), which shows "Quit Herd?" when
  confirm-quit is on; Cancel leaves a dead terminal with no way back.
  Triggers include the session's detach key, a crash, or an upgrade. Fix: a
  "Terminal disconnected. Reconnect" overlay that bumps an `.id` generation
  on `HerdTerminalView`; also disable the detach key in the generated
  session config.

- [ ] **9. The slash menu's "empty prompt" check is guessed from keystrokes
  (low-med).** `typed[pane]` (SlashController.swift) only tracks keyDown, so
  paste, ↑ history, ⌥⌫/⌃U, mouse edits and the agent's own modes throw it
  off. It also matches `charactersIgnoringModifiers`, so on layouts where /
  is Shift+7 (German) the menu never opens. Fix: decide from the screen (read
  the cursor row left of the cursor) and match `event.characters`.

- [ ] **10. Text sent to panes can arrive out of order (low).** Prompt line
  and slash menu sends go through the concurrent global queue, so a flush
  followed by ⌃C, or two quick submits, can reorder. Fix: one private serial
  queue for all Herd-to-pane writes.

- [ ] **11. Scroll speed may be multiplied three times over (low,
  unverified).** Trackpad deltas are doubled, the renderer sends one report
  per row with a wheel multiplier of 3, and the session's
  `mouse_scroll_lines = 3` probably applies per report, about 9 lines per
  notch. The "Mouse scroll lines" setting is then misleading. Fix: set the
  renderer's scroll multiplier to 1 and keep the user's value only in the
  session config.

## Missing features

- [ ] **12. Find in scrollback (med).** ⌘F does nothing, and ⌘↑/⌘↓ (jump
  to prompt) and ⌘Home/⌘PgUp are consumed with no effect. The renderer only
  holds the viewport; the scrollback lives in the session server, which has
  `pane.copy_search`, `pane.read`, `pane.scroll` and copy mode. Fix: a find
  bar over the top right of the terminal driving `pane.copy_search`
  (next/previous, Esc leaves copy mode); bind ⌘F, ⌘G, ⇧⌘G in the menus and
  unbind them in the renderer; map ⌘↑/⌘↓ to `pane.scroll`.

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

- [ ] **17. The prompt line has no mouse integration (low).** Keys Herd
  consumes never reach the renderer, so hide-mouse-while-typing never fires
  on the prompt line, and the overlay ignores clicks, so a click can't move
  the caret. Fix: `NSCursor.setHiddenUntilMouseMoves(true)` when the prompt
  line consumes a key (if the setting is on), and map a click's x to a
  column (`(x - origin.x) / cellWidth`) to set the caret.
