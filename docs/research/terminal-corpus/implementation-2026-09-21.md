# First implementation batch

Historical record: the snapshot Find implementation and its smoke fixture were
replaced in [batch 2](implementation-2026-09-21-batch-2.md) after live engine testing
exposed the read API cap. Clipboard and completion changes remain in place.

Related scenarios: T01, T02, T10. Full end-to-end scenarios remain pending.

## Find in output

Cmd+F opens a read-only snapshot of the focused terminal pane's retained output.
The native Find bar supports next/previous (Cmd+G / Shift+Cmd+G), Unicode,
selection and copying. Refresh fetches new output; truncation is explicitly
reported. Done/Escape returns to the terminal. The pane ID is captured on open,
so changing focus cannot mix output from another pane into the same snapshot.

This implementation uses the bundled engine's `pane.read` schema, with `recent`
text and ANSI stripping. It does not implement live-terminal highlighting or
scroll-to-match through `pane.copy_search`; those remain follow-up work. Native
agent-conversation search is also outside this batch.

## Clipboard and completion control

The surface's paste, plain-text paste, selection paste, copy and select-all now
consult the prompt editor. Services and file/text drops also insert into held
input. Image paths insert into the active editor instead of racing ahead of it.

Pasted CRLF/CR are normalized, trailing newlines trimmed, and C0/C1 control bytes
filtered while preserving tabs, internal newlines and Unicode format characters.
Multiline/tab-containing input is bracketed when handed to the shell. Handoff
restores the caret before sending Tab, and editor/image writes share a serial
queue. Shell support for bracketed paste and complex multiline cursor movement
still needs the live zsh/bash/fish matrix.

Settings → Agents → Octet's Tab completions can be disabled independently of
the editor and history suggestions. Tab then gives the current line to the
shell, which owns that line afterward. Ctrl+R remains the editor's history menu.

## Verification

- App Debug build passes with signing disabled.
- Core suite: 178 tests, including four new corpus regression tests.
- `scripts/verify-output-search.swift` passes a native AppKit smoke test with
  a stubbed engine: 10,000 Unicode lines, offscreen next/previous matches,
  read-only text and sheet dismissal. Its header has the rerun command.
- Initial tests caught Unicode control filtering stripping emoji ZWJ; fixed
  by filtering terminal C0/C1 ranges rather than all Unicode control characters.

Still pending: live engine scrollback retrieval and truncation, typing/paste in
the Find field, all clipboard sources with the app running, shell completion
parity, multiline handoff under each shell, and multiple-window behavior. Do
not mark the full corpus scenarios passed from unit or stubbed UI tests alone.
