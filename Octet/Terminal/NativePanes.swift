import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// One pane drawn natively: a mirror terminal fed by the pane's stream. The
/// engine's terminal stays the real one (it answers programs' queries); this
/// view draws it and types into it, and sizes it to fit.
@MainActor
final class PaneMirrorView: NSView {
    /// Every pane's view by pane id, for what acts on a pane's own terminal
    /// (scrolling it, reading where it's scrolled to).
    private static let live = NSMapTable<NSString, PaneMirrorView>.strongToWeakObjects()
    static func view(of paneId: String) -> PaneMirrorView? { live.object(forKey: paneId as NSString) }

    let paneId: String
    let surface: TerminalEngine.SurfaceView
    private let stream: PaneStream
    private var sizeWatch: AnyCancellable?
    /// The pane in front of the engine follows the one typed into.
    var onFocus: (() -> Void)?
    /// The pane closed in the engine (its program exited).
    var onClosed: (() -> Void)?

    init(paneId: String, socketPath: String) {
        self.paneId = paneId
        // The input sink is set before the surface exists, so it goes through
        // a box filled in once the stream does.
        let box = InputBox()
        surface = OctetTerminalRuntime.shared.makeMirrorView { box.send($0) }
        stream = PaneStream(paneId: paneId, socketPath: socketPath, size: .init(cols: 0, rows: 0, widthPx: 0, heightPx: 0))
        box.stream = stream
        super.init(frame: .zero)
        // Bottom-anchored output hangs below the view: clip it.
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(surface)
        let surface = self.surface
        stream.onReplay = { bytes in
            // From nothing: no screen, scrollback or modes left from before.
            surface.surfaceModel?.processOutput(Data("\u{1b}c\u{1b}[3J".utf8))
            surface.surfaceModel?.processOutput(bytes)
        }
        stream.onOutput = { bytes in surface.surfaceModel?.processOutput(bytes) }
        surface.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }
        stream.onClosed = { [weak self] in self?.onClosed?() }
        surface.keyInterceptor = { [weak self] event in self?.copyModeKey(event) ?? false }
        sizeWatch = surface.$surfaceSize.compactMap { $0 }.sink { [weak self] size in
            self?.gridChanged(size)
        }
        Self.live.setObject(self, forKey: paneId as NSString)
    }

    /// Where this terminal is scrolled to. Its scrollback is its own: the
    /// engine's replay and output since, so it lines up with the engine's
    /// from the bottom.
    var scroll: PaneScroll? {
        guard let handle = surface.surface else { return nil }
        var bar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(handle, &bar), bar.total >= bar.len else { return nil }
        let maximum = Int(bar.total - bar.len)
        return PaneScroll(offsetFromBottom: max(0, maximum - Int(bar.offset)), maxOffsetFromBottom: maximum,
                          viewportRows: Int(bar.len))
    }

    /// Scrolls so the viewport's bottom is `offset` rows above the end.
    func scroll(toOffsetFromBottom offset: Int) {
        guard let handle = surface.surface else { return }
        var bar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(handle, &bar), bar.total >= bar.len else { return }
        let maximum = Int(bar.total - bar.len)
        let top = UInt64(max(0, maximum - min(max(0, offset), maximum)))
        var after = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scroll_to_row_if_revision(handle, top, bar.row_space_revision, &after)
    }

    /// The text of each row in view, top to bottom, a row at a time: read
    /// together, a line wrapped over rows comes back as one. (Rows of the
    /// whole scrollback can't be read by number: every one reads the same.)
    func viewportRows() -> [String]? {
        guard let handle = surface.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(handle, &metrics), metrics.columns > 0, metrics.rows > 0 else { return nil }
        return (0..<Int(metrics.rows)).map { row in
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                              x: UInt32(metrics.columns - 1), y: UInt32(row)),
                rectangle: false)
            guard ghostty_surface_read_text(handle, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(handle, &text) }
            return String(cString: text.text)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { stream.stop() }

    /// Blank rows under the cursor that output is moved down by, so short
    /// output sits at the bottom of the pane ("Terminal text: Bottom"). The
    /// grid keeps its size: those rows hang below the view, empty.
    private var droppedRows = 0
    /// Scrolling owns the view for a moment; anchoring waits.
    private var anchoringPausedUntil = Date.distantPast

    override func layout() {
        super.layout()
        // Not flipped: down is toward zero.
        let drop = CGFloat(droppedRows) * (surface.cellSize.height > 0 ? surface.cellSize.height : 0)
        surface.frame = bounds.offsetBy(dx: 0, dy: -drop)
    }

    /// The blank space above dropped output is still the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return surface.hitTest(convert(point, to: surface.superview)) ?? surface
    }

    func terminalDidScroll() {
        anchoringPausedUntil = Date().addingTimeInterval(0.3)
    }

    /// Re-measures how far output can drop: the run of blank rows under the
    /// cursor, nothing if anything below it holds text.
    func updateBottomAnchor(enabled: Bool) {
        guard Date() >= anchoringPausedUntil, !inLiveResize, TabDrag.shared.item == nil else { return }
        let rows = enabled ? blankRowsBelowCursor() : 0
        guard rows != droppedRows else { return }
        droppedRows = rows
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func blankRowsBelowCursor() -> Int {
        guard let handle = surface.surface else { return 0 }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(handle, &metrics), metrics.cursor_in_viewport else { return 0 }
        let below = Int(metrics.rows) - 1 - Int(metrics.cursor_row)
        guard below > 0 else { return 0 }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: 0, y: UInt32(metrics.cursor_row) + 1),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(handle, selection, &text) else { return 0 }
        defer { ghostty_surface_free_text(handle, &text) }
        return String(cString: text.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? below : 0
    }

    /// The stream starts once the view knows its grid, so the engine's
    /// replay is drawn for the size it will stay at.
    private var started = false

    private func gridChanged(_ size: ghostty_surface_size_s) {
        guard size.columns > 0, size.rows > 0 else { return }
        let grid = PaneStream.Size(cols: Int(size.columns), rows: Int(size.rows),
                                   widthPx: Int(size.width_px), heightPx: Int(size.height_px))
        stream.resize(grid)
        if !started {
            started = true
            stream.start()
        }
    }

    // MARK: - Copy mode

    /// Moving through the scrollback with the keys and selecting from it,
    /// as herdr's copy mode did: the terminal's own keyboard-copy cursor.
    private(set) var inCopyMode = false
    private var copyBadge: NSTextField?
    private var selecting: ghostty_keyboard_copy_selection_e = GHOSTTY_KEYBOARD_COPY_SELECTION_NONE

    func enterCopyMode() {
        guard !inCopyMode, let handle = surface.surface else { return }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        guard ghostty_surface_keyboard_copy_cursor_set(handle, true, &column, &row, &width) else { return }
        inCopyMode = true
        selecting = GHOSTTY_KEYBOARD_COPY_SELECTION_NONE
        let badge = NSTextField(labelWithString: "COPY")
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .black
        badge.backgroundColor = .controlAccentColor
        badge.drawsBackground = true
        badge.sizeToFit()
        badge.frame.origin = CGPoint(x: bounds.maxX - badge.frame.width - 8, y: bounds.maxY - badge.frame.height - 6)
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(badge)
        copyBadge = badge
        window?.makeFirstResponder(surface)
    }

    func leaveCopyMode() {
        guard inCopyMode, let handle = surface.surface else { return }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        _ = ghostty_surface_keyboard_copy_cursor_set(handle, false, &column, &row, &width)
        inCopyMode = false
        copyBadge?.removeFromSuperview()
        copyBadge = nil
        scroll(toOffsetFromBottom: 0)
    }

    /// One key in copy mode; anything it doesn't know is swallowed, so
    /// nothing reaches the program by accident.
    private func copyModeKey(_ event: NSEvent) -> Bool {
        guard inCopyMode, let handle = surface.surface else { return false }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        let extend = selecting != GHOSTTY_KEYBOARD_COPY_SELECTION_NONE
        let linewise = selecting == GHOSTTY_KEYBOARD_COPY_SELECTION_LINE
        func move(_ movement: ghostty_keyboard_selection_move_e, _ count: UInt16 = 1) {
            _ = ghostty_surface_keyboard_selection_move(handle, movement, count, extend, linewise, &column, &row, &width)
        }
        func scroll(_ action: ghostty_keyboard_copy_scroll_e, _ amount: Int32) {
            _ = ghostty_surface_keyboard_copy_scroll(handle, action, amount, &column, &row, &width)
        }
        func select(linewise: Bool) {
            if selecting != GHOSTTY_KEYBOARD_COPY_SELECTION_NONE {
                // Pressed again: the selection goes, the cursor stays.
                selecting = GHOSTTY_KEYBOARD_COPY_SELECTION_NONE
                _ = ghostty_surface_keyboard_copy_cursor_set(handle, true, &column, &row, &width)
                return
            }
            if ghostty_surface_keyboard_copy_selection_start(handle, linewise, 1, &column, &row, &width) {
                selecting = linewise ? GHOSTTY_KEYBOARD_COPY_SELECTION_LINE : GHOSTTY_KEYBOARD_COPY_SELECTION_CHARACTER
            }
        }
        func copyAndLeave() {
            if selecting != GHOSTTY_KEYBOARD_COPY_SELECTION_NONE {
                _ = ghostty_surface_copy_selection_to_clipboard_bounded(handle, 8 << 20)
                ClipboardWatcher.shared.acknowledge()
            }
            leaveCopyMode()
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == .command {
            guard key == "c" else { return false }
            copyAndLeave()
            return true
        }
        if flags == .control {
            switch key {
            case "u": scroll(GHOSTTY_KEYBOARD_COPY_SCROLL_HALF_PAGES, -1)
            case "d": scroll(GHOSTTY_KEYBOARD_COPY_SCROLL_HALF_PAGES, 1)
            case "b": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_UP)
            case "f": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_DOWN)
            case "c": leaveCopyMode()
            default: break
            }
            return true
        }
        switch event.keyCode {
        case 123: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_LEFT)
        case 124: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_RIGHT)
        case 126: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_UP)
        case 125: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_DOWN)
        case 116: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_UP)
        case 121: move(GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_DOWN)
        case 53: leaveCopyMode()
        case 36, 76: copyAndLeave()
        default:
            switch key {
            case "h": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_LEFT)
            case "l": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_RIGHT)
            case "k": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_UP)
            case "j": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_DOWN)
            case "0", "^": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_BEGINNING_OF_LINE)
            case "$": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_END_OF_LINE)
            case "g": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_HOME)
            case "G": move(GHOSTTY_KEYBOARD_SELECTION_MOVE_END)
            case "[": scroll(GHOSTTY_KEYBOARD_COPY_SCROLL_PROMPTS, -1)
            case "]": scroll(GHOSTTY_KEYBOARD_COPY_SCROLL_PROMPTS, 1)
            case "v": select(linewise: false)
            case "V": select(linewise: true)
            case "y": copyAndLeave()
            case "q": leaveCopyMode()
            default: break
            }
        }
        return true
    }

    private final class InputBox: @unchecked Sendable {
        weak var stream: PaneStream?
        func send(_ bytes: Data) { stream?.send(input: bytes) }
    }
}

/// Where each natively drawn pane is and how its terminal draws, in the
/// terminal area's own points: what anything laid over a pane (highlights,
/// hints, the prompt line, the new-tab splash) places itself by.
@MainActor
final class PaneGeometry: ObservableObject {
    struct Pane: Equatable {
        /// The pane's view in the terminal area.
        var frame: CGRect
        var cellSize: CGSize
        /// Where the first cell is drawn inside the pane's view.
        var padding: CGPoint
        var columns: Int
        var rows: Int
        /// The cursor, while it's in view.
        var cursor: (row: Int, column: Int)?
        var scroll: PaneScroll?

        static func == (a: Pane, b: Pane) -> Bool {
            a.frame == b.frame && a.cellSize == b.cellSize && a.padding == b.padding && a.columns == b.columns
                && a.rows == b.rows && a.cursor?.row == b.cursor?.row && a.cursor?.column == b.cursor?.column
                && a.scroll == b.scroll
        }

        /// A cell's top-left corner in the terminal area.
        func origin(row: Int, column: Int) -> CGPoint {
            CGPoint(x: frame.minX + padding.x + CGFloat(column) * cellSize.width,
                    y: frame.minY + padding.y + CGFloat(row) * cellSize.height)
        }
    }

    @Published private(set) var panes: [String: Pane] = [:]
    /// The focused pane's prompt, as the new-tab splash reads it.
    @Published private(set) var focusedGrid: TerminalGrid?

    func set(_ panes: [String: Pane], focusedGrid: TerminalGrid?) {
        if panes != self.panes { self.panes = panes }
        if focusedGrid != self.focusedGrid { self.focusedGrid = focusedGrid }
    }
}

/// A tab's panes, each its own terminal, placed as the engine lays them out.
/// Views are kept by pane id across layouts, so a split or a resize moves
/// a pane's terminal rather than starting it again.
struct NativePaneGrid: NSViewRepresentable {
    let layout: PaneLayout?
    /// The tab shown, whose layout the engine works out for this view's size.
    let tabId: String?
    let focusedPaneId: String?
    let socketPath: String
    var gutter: CGFloat = 4
    let geometry: PaneGeometry
    /// The view's size in cells changed: the tab's layout should be worked
    /// out for it (`tab.set_viewport`).
    var viewport: (_ tabId: String, _ columns: Int, _ rows: Int) -> Void = { _, _, _ in }
    let focus: (String) -> Void

    func makeNSView(context: Context) -> GridView { GridView(geometry: geometry) }

    func updateNSView(_ view: GridView, context: Context) {
        view.update(layout: layout, focusedPaneId: focusedPaneId, socketPath: socketPath, gutter: gutter, focus: focus)
        view.report(tabId: tabId, viewport: viewport)
    }

    static func dismantleNSView(_ view: GridView, coordinator: ()) { view.stopMeasuring() }

    @MainActor
    final class GridView: NSView {
        private var panes: [String: PaneMirrorView] = [:]
        private var paneLayout: PaneLayout?
        private var gutter: CGFloat = 4
        private var focusedPaneId: String?
        private let geometry: PaneGeometry
        private var measuring: Timer?

        init(geometry: PaneGeometry) {
            self.geometry = geometry
            super.init(frame: .zero)
            // The cursor moves without any layout: read it a few times a second.
            measuring = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var tabId: String?
        private var viewport: (String, Int, Int) -> Void = { _, _, _ in }
        private var reported: (tab: String, columns: Int, rows: Int)?

        func report(tabId: String?, viewport: @escaping (String, Int, Int) -> Void) {
            self.tabId = tabId
            self.viewport = viewport
            reportViewport()
        }

        /// The whole view in cells of the panes' font: what the tab's layout
        /// divides, so the engine's cells and the panes' agree.
        private func reportViewport() {
            guard let tabId, let cell = geometry.panes.values.first?.cellSize,
                  cell.width > 0, cell.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            let columns = Int(bounds.width / cell.width), rows = Int(bounds.height / cell.height)
            guard columns > 0, rows > 0,
                  reported.map({ $0.tab != tabId || $0.columns != columns || $0.rows != rows }) ?? true else { return }
            reported = (tabId, columns, rows)
            viewport(tabId, columns, rows)
        }

        func stopMeasuring() {
            measuring?.invalidate()
            measuring = nil
        }

        override var isFlipped: Bool { true }

        /// Every pane's frame and its terminal's metrics, as they are now.
        private func measure() {
            let bottom = SettingsStore.shared.values.textPosition == .bottom
            var found: [String: PaneGeometry.Pane] = [:]
            for (id, view) in panes {
                view.updateBottomAnchor(enabled: bottom)
                guard let handle = view.surface.surface else { continue }
                var metrics = ghostty_surface_grid_metrics_s()
                guard ghostty_surface_grid_metrics(handle, &metrics), metrics.cell_width > 0 else { continue }
                // The surface sits inside the pane's view; both are measured here.
                let surfaceFrame = view.surface.convert(view.surface.bounds, to: self)
                found[id] = PaneGeometry.Pane(
                    frame: view.frame,
                    cellSize: CGSize(width: metrics.cell_width, height: metrics.cell_height),
                    padding: CGPoint(x: surfaceFrame.minX - view.frame.minX + metrics.padding_left,
                                     y: surfaceFrame.minY - view.frame.minY + metrics.padding_top),
                    columns: Int(metrics.columns), rows: Int(metrics.rows),
                    cursor: metrics.cursor_in_viewport ? (Int(metrics.cursor_row), Int(metrics.cursor_column)) : nil,
                    scroll: view.scroll)
            }
            let focused = focusedPaneId.flatMap { id in panes[id].flatMap { view in found[id].map { (view, $0) } } }
            geometry.set(found, focusedGrid: focused.flatMap { Self.grid(of: $0.0, at: $0.1) })
            reportViewport()
        }

        /// How much of a pane is in use down to its cursor, and where the
        /// cursor's row is: nil while the cursor is out of view.
        private static func grid(of view: PaneMirrorView, at pane: PaneGeometry.Pane) -> TerminalGrid? {
            guard let cursor = pane.cursor, pane.columns > 0, let handle = view.surface.surface else { return nil }
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                              x: UInt32(pane.columns - 1), y: UInt32(cursor.row)),
                rectangle: false)
            guard ghostty_surface_read_text(handle, selection, &text) else { return nil }
            defer { ghostty_surface_free_text(handle, &text) }
            let rowsInUse = String(cString: text.text).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let top = pane.origin(row: cursor.row, column: 0).y
            return TerminalGrid(cursorRow: cursor.row, cursorColumn: cursor.column, rowsInUse: rowsInUse,
                                cursorTop: top, cursorBottom: top + pane.cellSize.height)
        }

        func update(layout: PaneLayout?, focusedPaneId: String?, socketPath: String, gutter: CGFloat,
                    focus: @escaping (String) -> Void) {
            self.paneLayout = layout
            self.gutter = gutter
            let ids = Set(layout?.panes.map(\.id) ?? [])
            for (id, view) in panes where !ids.contains(id) {
                view.removeFromSuperview()
                panes[id] = nil
            }
            var added = false
            for id in ids where panes[id] == nil {
                let view = PaneMirrorView(paneId: id, socketPath: socketPath)
                addSubview(view)
                panes[id] = view
                added = true
            }
            for (id, view) in panes { view.onFocus = { focus(id) } }
            needsLayout = true
            // Typing goes to the engine's focused pane, as it moves.
            if focusedPaneId != self.focusedPaneId {
                self.focusedPaneId = focusedPaneId
                takeFocus(moved: true)
            } else if added {
                // The first panes can arrive after the grid joined its window.
                takeFocus(moved: false)
            }
        }

        /// The first focus can come before the grid is in a window, where
        /// it went nowhere and was never tried again: try again on arrival.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            takeFocus(moved: false)
        }

        /// Makes the focused pane's terminal take the keys. When the focus
        /// didn't move, not from a field being edited or another terminal
        /// (the drawer's): only from whatever SwiftUI left holding them.
        private func takeFocus(moved: Bool) {
            // No focused pane known yet: the layout's first.
            let id = focusedPaneId.flatMap { panes[$0] != nil ? $0 : nil } ?? paneLayout?.panes.first?.id
            guard let window, let id, let view = panes[id],
                  window.firstResponder !== view.surface else { return }
            let current = window.firstResponder
            let busy = current is NSText
                || (current is TerminalEngine.SurfaceView && !panes.values.contains { $0.surface === current })
            guard moved || !busy else { return }
            window.makeFirstResponder(view.surface)
        }

        override func layout() {
            super.layout()
            guard let layout = paneLayout else { return }
            for (id, frame) in Self.frames(layout, in: bounds.size, gutter: gutter) {
                panes[id]?.frame = frame
            }
            measure()
        }

        /// The engine's cell rectangles, scaled to the view, with `gutter`
        /// points between neighbours.
        static func frames(_ layout: PaneLayout, in size: CGSize, gutter: CGFloat) -> [String: CGRect] {
            let area = layout.area
            guard area.width > 0, area.height > 0 else { return [:] }
            let sx = size.width / area.width, sy = size.height / area.height
            let rects = layout.panes.map { $0.rect.offsetBy(dx: -area.minX, dy: -area.minY) }
            // Neighbours meet at a shared edge, or (an engine still drawing
            // gaps) across a one-cell gap: the boundary is that gap's middle.
            func boundary(after edge: CGFloat, horizontal: Bool) -> CGFloat {
                rects.contains { (horizontal ? $0.minX : $0.minY) == edge } ? edge : edge + 0.5
            }
            func boundary(before edge: CGFloat, horizontal: Bool) -> CGFloat {
                rects.contains { (horizontal ? $0.maxX : $0.maxY) == edge } ? edge : edge - 0.5
            }
            var frames: [String: CGRect] = [:]
            for (pane, rect) in zip(layout.panes, rects) {
                let left = rect.minX <= 0 ? 0 : boundary(before: rect.minX, horizontal: true) * sx + gutter / 2
                let top = rect.minY <= 0 ? 0 : boundary(before: rect.minY, horizontal: false) * sy + gutter / 2
                let right = rect.maxX >= area.width ? size.width
                    : boundary(after: rect.maxX, horizontal: true) * sx - gutter / 2
                let bottom = rect.maxY >= area.height ? size.height
                    : boundary(after: rect.maxY, horizontal: false) * sy - gutter / 2
                frames[pane.id] = CGRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1))
            }
            return frames
        }
    }
}

/// One pane on its own, outside any tab's layout: a popup.
struct PaneTerminal: NSViewRepresentable {
    let paneId: String
    let socketPath: String
    var closed: () -> Void = {}

    func makeNSView(context: Context) -> PaneMirrorView {
        let view = PaneMirrorView(paneId: paneId, socketPath: socketPath)
        view.onClosed = closed
        DispatchQueue.main.async { view.window?.makeFirstResponder(view.surface) }
        return view
    }

    func updateNSView(_ view: PaneMirrorView, context: Context) { view.onClosed = closed }
}
