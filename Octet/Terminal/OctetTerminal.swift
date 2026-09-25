// Octet-facing API over the embedded terminal engine.
//
// Usage:
//   OctetTerminalRuntime.configure(overrides: "background = 050505")   // once, at launch
//   OctetTerminalView(command: "...", environment: [...], workingDirectory: ..., onTitleChange: ..., onExit: ...)
//
// The engine glue lives in ./Engine.

import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// Owns the process-wide terminal engine app and configuration.
@MainActor
final class OctetTerminalRuntime {
    static let shared = OctetTerminalRuntime()

    private var overrides: String = ""
    private var didInitEngine = false
    private var engineApp: TerminalEngine.App?

    private init() {}

    /// Call once at launch, before any terminal view is created.
    /// `overrides` uses the renderer's config-file syntax, one setting per line
    /// (e.g. "background = 050505\nfont-size = 13"). The user's own renderer
    /// config files are never loaded.
    static func configure(overrides: String) {
        let runtime = shared
        precondition(runtime.engineApp == nil, "OctetTerminalRuntime.configure must be called before any terminal is created")
        runtime.overrides = overrides
        runtime.initEngineIfNeeded()
        runtime.engineApp = TerminalEngine.App(overrides: overrides)
    }

    /// Replaces the overrides and applies them live to every surface.
    static func updateConfig(overrides: String) {
        let runtime = shared
        runtime.overrides = overrides
        runtime.engineApp?.updateConfig(overrides: overrides)
    }

    /// Tells programs in the terminal whether the theme is light or dark
    /// (they can query it, and some pick colors from it).
    static func setColorScheme(dark: Bool) {
        guard let app = shared.engineApp?.app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// Applies (or clears) the renderer's background blur on a window.
    static func applyBackgroundBlur(to window: NSWindow) {
        shared.engineApp?.applyBackgroundBlur(to: window)
    }

    /// Where the terminal's cursor is, in the window's terminal view, plus
    /// the cell size — the anchor Octet draws its own prompt line at.
    struct CursorAnchor: Equatable {
        /// Origin of the cursor cell inside the terminal view.
        let origin: CGPoint
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        /// Columns left on the cursor's row.
        let columnsRemaining: Int
    }

    @MainActor
    static func cursorAnchor() -> CursorAnchor? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let content = window.contentView,
              let surface = findSurface(in: content),
              let handle = surface.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(handle, &metrics), metrics.cursor_in_viewport else { return nil }
        // The surface may be shifted inside its clipping host, so measure in
        // the host's coordinates — that is what SwiftUI overlays sit on.
        let host = surface.superview as? FlippedView
        let offsetY = (host?.frame.origin.y ?? 0) + surface.frame.origin.y
        let x = metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width
        let y = offsetY + metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height
        return CursorAnchor(
            origin: CGPoint(x: x, y: y),
            cellWidth: metrics.cell_width,
            cellHeight: metrics.cell_height,
            columnsRemaining: max(0, Int(metrics.columns) - Int(metrics.cursor_column))
        )
    }

    /// The cursor's row from the cursor to the right edge, as text.
    @MainActor
    static func textRightOfCursor() -> String? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let content = window.contentView,
              let surface = findSurface(in: content),
              let handle = surface.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(handle, &metrics), metrics.cursor_in_viewport,
              metrics.columns > metrics.cursor_column else { return nil }
        let row = UInt32(metrics.cursor_row)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: UInt32(metrics.cursor_column), y: row),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(metrics.columns) - 1, y: row),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(handle, &text) }
        return String(cString: text.text)
    }

    /// What the terminal is showing right now, as text. Some of what an agent
    /// says never reaches its session file — a question it is waiting on is
    /// drawn on screen and nowhere else — so this is how Octet reads it.
    @MainActor
    static func screenText() -> String? {
        // The key window may be a panel with no terminal in it, so this looks
        // for the window that actually has the surface.
        let windows = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows.filter(\.isVisible)
        guard let surfaceView = windows.lazy.compactMap({ $0.contentView.flatMap(findSurface(in:)) }).first,
              let surface = surfaceView.surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Makes the key window's terminal surface first responder again.
    static func focusTerminal() {
        DispatchQueue.main.async {
            if WindowRegistry.shared.key?.twin.isVisible == true, TwinComposerFocus.request() { return }
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                  let content = window.contentView,
                  let surface = findSurface(in: content) else { return }
            window.makeFirstResponder(surface)
        }
    }

    #if DEBUG
    /// Verification hook: presses keys in the terminal as real key events,
    /// so what a key sends can be checked without a person at the keyboard.
    /// `keys` is space-separated: a letter, `return`, or a modifier+key such
    /// as `shift+return` or `opt+return`.
    static func debugPress(_ keys: String) {
        guard let (window, surface) = NSApp.windows.lazy.compactMap({ window -> (NSWindow, TerminalEngine.SurfaceView)? in
            guard window.isVisible, let content = window.contentView, let surface = findSurface(in: content) else { return nil }
            return (window, surface)
        }).first else { return }
        window.makeFirstResponder(surface)
        let codes: [String: UInt16] = ["a": 0, "b": 11, "c": 8, "return": 36, "up": 126, "down": 125]
        for token in keys.split(separator: " ") {
            // `paste:<file>` pastes the file's text as ⌘V would, from a
            // pasteboard of its own so the real clipboard is left alone.
            if token.hasPrefix("paste:"), let text = try? String(contentsOfFile: String(token.dropFirst(6)), encoding: .utf8) {
                let board = NSPasteboard(name: NSPasteboard.Name("com.jpxsoftware.octet.debug-paste"))
                board.clearContents()
                board.setString(text, forType: .string)
                _ = OctetKeyHook.paste(from: board)
                continue
            }
            // `wheel-up` turns the scroll wheel one notch up.
            if token == "wheel-up" {
                // Over the middle of the terminal, where the wheel lands.
                let middle = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
                if let move = NSEvent.mouseEvent(with: .mouseMoved, location: middle, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) {
                    surface.mouseMoved(with: move)
                }
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) {
                    cg.location = window.convertPoint(toScreen: middle)
                    if let event = NSEvent(cgEvent: cg) { surface.scrollWheel(with: event) }
                }
                continue
            }
            // `confirm-paste` presses Paste on a paste preview.
            if token == "confirm-paste" {
                if let store = OctetKeyHook.store { PastePreviewCenter.shared.send(store: store) }
                continue
            }
            var parts = token.split(separator: "+").map(String.init)
            let key = parts.removeLast()
            guard let code = codes[key] else { continue }
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("shift") { flags.insert(.shift) }
            if parts.contains("opt") { flags.insert(.option) }
            if parts.contains("ctrl") { flags.insert(.control) }
            if parts.contains("cmd") { flags.insert(.command) }
            let character = key == "return" ? "\r" : (flags.contains(.shift) ? key.uppercased() : key)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: character, charactersIgnoringModifiers: key == "return" ? "\r" : key,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { surface.keyDown(with: event) } else { surface.keyUp(with: event) }
            }
        }
    }
    #endif

    private static func findSurface(in view: NSView) -> TerminalEngine.SurfaceView? {
        if let surface = view as? TerminalEngine.SurfaceView { return surface }
        for sub in view.subviews {
            if let surface = findSurface(in: sub) { return surface }
        }
        return nil
    }

    /// Config diagnostics (invalid override lines, etc.), including from
    /// an update that was rejected outright.
    var configErrors: [String] {
        app.lastConfigErrors ?? app.config.errors
    }

    static var configErrors: [String] { shared.engineApp == nil ? [] : shared.configErrors }

    fileprivate var app: TerminalEngine.App {
        if let engineApp { return engineApp }
        initEngineIfNeeded()
        let created = TerminalEngine.App(overrides: overrides)
        engineApp = created
        return created
    }

    private func initEngineIfNeeded() {
        guard !didInitEngine else { return }
        didInitEngine = true
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            TerminalEngine.logger.critical("ghostty_init failed")
        }
    }

    /// Create a terminal surface view running `command` (through the login shell,
    /// `/bin/sh -c`-style). The returned view accepts first
    /// responder; make it first responder to type into it.
    func makeTerminalView(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> NSView {
        makeSurfaceView(command: command, environment: environment, workingDirectory: workingDirectory)
    }

    fileprivate func makeSurfaceView(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> TerminalEngine.SurfaceView {
        guard let cApp = app.app else {
            fatalError("terminal engine app failed to initialize")
        }
        var config = TerminalEngine.SurfaceConfiguration()
        config.command = command.isEmpty ? nil : command
        config.environmentVariables = environment
        config.workingDirectory = workingDirectory
        return TerminalEngine.SurfaceView(cApp, baseConfig: config)
    }
}

/// Convenience free function mirroring the runtime method.
@MainActor
func makeTerminalView(command: String, environment: [String: String], workingDirectory: String?) -> NSView {
    OctetTerminalRuntime.shared.makeTerminalView(command: command, environment: environment, workingDirectory: workingDirectory)
}

/// SwiftUI host for a single terminal surface. The surface (and its child
/// process) is created once when the view is first made and lives as long as
/// the SwiftUI view identity; give it a new `.id(...)` to restart.
struct OctetTerminalView: NSViewRepresentable {
    let command: String
    let environment: [String: String]
    let workingDirectory: String?
    /// Terminal rows clipped off the top (Octet hides the engine's tab row).
    var hiddenTopRows = 0
    /// Where that row lands when content is anchored to the bottom.
    @ObservedObject var anchor: TerminalAnchor
    var onTitleChange: (String) -> Void = { _ in }
    var onExit: () -> Void = {}
    /// Hands over the surface once made: the window sends its keys to it.
    var onSurface: (TerminalEngine.SurfaceView) -> Void = { _ in }

    init(
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        hiddenTopRows: Int = 0,
        anchor: TerminalAnchor,
        onTitleChange: @escaping (String) -> Void = { _ in },
        onExit: @escaping () -> Void = {},
        onSurface: @escaping (TerminalEngine.SurfaceView) -> Void = { _ in }
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.hiddenTopRows = hiddenTopRows
        self.anchor = anchor
        self.onTitleChange = onTitleChange
        self.onExit = onExit
        self.onSurface = onSurface
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = OctetTerminalRuntime.shared.makeSurfaceView(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        )
        view.onTitleChange = onTitleChange
        view.onExit = onExit
        onSurface(view)

        // Grab keyboard focus once we're in a window.
        view.focusOnAttach = true
        guard hiddenTopRows > 0 else { return view }
        return TopRowClippingView(surfaceView: view, hiddenRows: hiddenTopRows, anchor: anchor)
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        // The band above bottom-anchored content shows this view's own
        // background; follow theme changes, not just the theme at launch.
        (nsView as? TopRowClippingView)?.refreshBackground()
        guard let view = (nsView as? TerminalEngine.SurfaceView)
            ?? (nsView as? TopRowClippingView)?.surfaceView else { return }
        // Keep callbacks current (closures may capture fresh SwiftUI state).
        view.onTitleChange = onTitleChange
        view.onExit = onExit
    }
}

/// Where the engine's own chrome row ends up once content is bottom
/// anchored, so SwiftUI can cover it — the terminal surface ignores AppKit
/// clipping, but SwiftUI overlays draw above it.
@MainActor
final class TerminalAnchor: ObservableObject {
    @Published var chromeCover: CGRect?
    /// What the grid shows right now, below the engine's chrome row.
    @Published var grid: TerminalGrid?
}

/// The terminal grid as the new-tab splash reads it: where the prompt is,
/// and whether anything but a prompt has been printed.
struct TerminalGrid: Equatable {
    /// The cursor's row, counting from the first row under the engine's chrome.
    let cursorRow: Int
    /// Its column: it moves right as a command is typed at the prompt.
    let cursorColumn: Int
    /// Rows from the top through the cursor that hold any text.
    let rowsInUse: Int
    /// The cursor row's top and bottom in the terminal view, in points, so a
    /// view laid over the terminal can keep clear of the prompt.
    let cursorTop: CGFloat
    let cursorBottom: CGFloat
}

/// A plain top-left-origin container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts a surface taller than itself, shifted up so its first `hiddenRows`
/// terminal rows sit above the visible bounds and are clipped away.
final class TopRowClippingView: NSView {
    let surfaceView: TerminalEngine.SurfaceView
    let hiddenRows: Int
    private var retryScheduled = false
    /// Blank rows below the cursor, so short output can sit at the bottom of
    /// the pane instead of clinging to the top.
    private var blankRowsBelow = 0
    private var anchorTimer: Timer?
    private var anchorPollingSuppressedUntil = Date.distantPast
    private var observations = Set<AnyCancellable>()
    private let stage = FlippedView()
    private let anchor: TerminalAnchor

    init(surfaceView: TerminalEngine.SurfaceView, hiddenRows: Int, anchor: TerminalAnchor) {
        self.surfaceView = surfaceView
        self.hiddenRows = hiddenRows
        self.anchor = anchor
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.masksToBounds = true
        // The stage clips the surface's hidden top rows; moving the stage
        // down bottom-anchors the content without resizing the grid, and the
        // outer clip hides whatever hangs below.
        stage.wantsLayer = true
        stage.layer?.masksToBounds = true
        stage.addSubview(surfaceView)
        addSubview(stage)
        surfaceView.$cellSize.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &observations)
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updatePollingLifecycle() }
                .store(in: &observations)
        }
    }

    deinit {
        anchorTimer?.invalidate()
    }

    /// Watches the cursor so the shift follows the prompt as output grows.
    private func startBottomAnchor() {
        guard anchorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBottomAnchor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        anchorTimer = timer
    }

    /// Hidden/minimized/fully covered windows need no main-thread grid scans.
    private func updatePollingLifecycle() {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !NSApp.isHidden else {
            anchorTimer?.invalidate()
            anchorTimer = nil
            return
        }
        updateBottomAnchor()
        startBottomAnchor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePollingLifecycle()
    }

    /// Blank space above bottom-anchored output is still part of the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return surfaceView
    }

    @MainActor
    private func updateBottomAnchor() {
        guard Date() >= anchorPollingSuppressedUntil else { return }
        let grid = measureGrid()
        if anchor.grid != grid { anchor.grid = grid }
        let rows = SettingsStore.shared.values.textPosition == .bottom ? measureBlankRowsBelowCursor() : 0
        guard rows != blankRowsBelow else { return }
        blankRowsBelow = rows
        needsLayout = true
    }

    /// Called by the hosted terminal for every wheel/trackpad event. The
    /// renderer owns scroll feedback; anchor measurements can resume once the
    /// gesture has settled.
    func terminalDidScroll() {
        anchorPollingSuppressedUntil = Date().addingTimeInterval(0.3)
    }

    /// How many rows the content can drop by: the run of blank rows under the
    /// cursor. Zero unless everything below the cursor really is empty, which
    /// also means a split pane's output never gets shifted out of view.
    @MainActor
    private func measureBlankRowsBelowCursor() -> Int {
        guard let surface = surfaceView.surface else { return 0 }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport else { return 0 }
        let below = Int(metrics.rows) - 1 - Int(metrics.cursor_row)
        guard below > 0 else { return 0 }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: 0, y: UInt32(metrics.cursor_row) + 1),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return 0 }
        defer { ghostty_surface_free_text(surface, &text) }
        let tail = String(cString: text.text)
        guard tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        return below
    }

    /// The grid from the first row under the engine's chrome through the
    /// cursor: how many of those rows hold text, and where the cursor's row
    /// sits in this view. Nil while the cursor is off screen or above the
    /// hidden rows, when there is no prompt to speak of.
    @MainActor
    private func measureGrid() -> TerminalGrid? {
        guard let surface = surfaceView.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport,
              Int(metrics.cursor_row) >= hiddenRows, metrics.columns > 0 else { return nil }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: 0, y: UInt32(hiddenRows)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(metrics.columns) - 1, y: UInt32(metrics.cursor_row)),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let rowsInUse = String(cString: text.text)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        // In this view's coordinates, which is what SwiftUI overlays sit on:
        // the stage shifts the surface down to bottom-anchor it.
        let top = stage.frame.origin.y + surfaceView.frame.origin.y
            + metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height
        return TerminalGrid(cursorRow: Int(metrics.cursor_row) - hiddenRows, cursorColumn: Int(metrics.cursor_column),
                            rowsInUse: rowsInUse,
                            cursorTop: top, cursorBottom: top + metrics.cell_height)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// One terminal row in points.
    var cellHeight: CGFloat {
        guard let surface = surfaceView.surface else { return 0 }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGFloat(ghostty_surface_size(surface).cell_height_px) / scale
    }

    /// Height of the hidden rows in points; 0 until the surface reports a grid.
    var hiddenHeight: CGFloat {
        guard let surface = surfaceView.surface else { return 0 }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGFloat(size.cell_height_px) / scale * CGFloat(hiddenRows)
    }

    func refreshBackground() {
        let color = Theme.palette.nsColor(\.background).cgColor
        if layer?.backgroundColor != color { layer?.backgroundColor = color }
    }

    override func layout() {
        super.layout()
        let offset = hiddenHeight
        // Shifting the surface down by the blank rows bottom-aligns the
        // content; the surface moves as a whole, so input still lands right.
        let drop = min(cellHeight * CGFloat(blankRowsBelow), max(0, bounds.height - cellHeight))
        // Set every pass: the backing layers don't exist yet at init, so
        // masking set there silently never applies.
        layer?.masksToBounds = true
        stage.layer?.masksToBounds = true
        stage.frame = NSRect(x: 0, y: drop, width: bounds.width, height: bounds.height)
        surfaceView.frame = NSRect(x: 0, y: -offset, width: bounds.width, height: bounds.height + offset)
        refreshBackground()
        // The engine's chrome row rides down with the content; hand its
        // position to SwiftUI, which can paint over the terminal.
        let cover = drop > 0 ? CGRect(x: 0, y: drop - offset, width: bounds.width, height: offset) : nil
        if anchor.chromeCover != cover { anchor.chromeCover = cover }
        if offset == 0, !retryScheduled {
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.retryScheduled = false
                self?.needsLayout = true
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

