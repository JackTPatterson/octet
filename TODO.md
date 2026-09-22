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
