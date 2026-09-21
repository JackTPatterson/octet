# Live search and bottom-anchor reliability

The bundled engine (0.9.1, protocol 22) caps `pane.read` at about 1,000 lines.
The first batch's truncation notice was correct, but snapshot Find could not
reach older retained output. That implementation has now been replaced.

Cmd+F opens a small native Find panel over the live terminal. Return searches;
Next/Previous and Cmd+G/Shift+Cmd+G navigate results and scroll the target pane.
Global result counts work even when the server returns only a page of matches.
Reopening Find after focusing another pane retargets the panel.

Search uses `pane.copy_search`, with the content revision obtained from
`pane.copy_motion`; the pane metadata revision is unrelated. Stale searches
retry at most three times. A revision check before scrolling rejects already
stale coordinates. These requests are not an atomic search-and-scroll, so
continuous output may still require retrying. Match highlighting remains open:
the matching row is revealed, but the matched cells are not painted.

Bottom anchoring now observes cell-size changes and invalidates clipping layout.
Blank space forwards hit testing to the terminal surface. Grid polling stops
while hidden, minimized or fully occluded and resumes when visible. Visible
windows still poll every 200 ms. No battery improvement has been measured.

## Verification

- Debug application builds with signing disabled.
- Core tests cover global match indices, offset clamping, malformed/empty
  responses, actual JSON numeric decoding, stale coordinates and retry limits.
- `scripts/verify-output-search.swift` passes a native AppKit smoke test with
  a stubbed engine: field entry, next/previous, global match count, closed-pane
  error feedback, Escape dismissal from the field, and cancellation before a
  delayed scroll. Copying a held command also checks the currently focused pane.
- `scripts/verify-engine-search.py` passes against the real bundled engine in
  an isolated `octet-corpus-test` session: generates 4,000 numbered Unicode
  lines, reproduces the snapshot cap, finds old/recent matches, scrolls them
  into view, and checks no-match behavior. Its workspace was removed and the
  disposable server stopped; the user's Octet session was not changed.

Pending: cell highlighting, full-app shortcuts and clipboard/multiwindow checks,
continuous streaming/reflow, visual zoom and hit-testing acceptance, and T07's
Release-mode resource benchmark. These targeted checks do not mark all corpus
acceptance scenarios complete.
