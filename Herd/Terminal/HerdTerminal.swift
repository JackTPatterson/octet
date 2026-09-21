// Herd-facing API over the embedded terminal engine.
//
// Usage:
//   HerdTerminalRuntime.configure(overrides: "background = 050505")   // once, at launch
//   HerdTerminalView(command: "...", environment: [...], workingDirectory: ..., onTitleChange: ..., onExit: ...)
//
// The engine glue lives in ./Engine.

import AppKit
import GhosttyKit
import SwiftUI

/// Owns the process-wide terminal engine app and configuration.
@MainActor
final class HerdTerminalRuntime {
    static let shared = HerdTerminalRuntime()

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
        precondition(runtime.engineApp == nil, "HerdTerminalRuntime.configure must be called before any terminal is created")
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
    /// the cell size — the anchor Herd draws its own prompt line at.
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

    /// Makes the key window's terminal surface first responder again.
    static func focusTerminal() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                  let content = window.contentView,
                  let surface = findSurface(in: content) else { return }
            window.makeFirstResponder(surface)
        }
    }

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
    HerdTerminalRuntime.shared.makeTerminalView(command: command, environment: environment, workingDirectory: workingDirectory)
}

/// SwiftUI host for a single terminal surface. The surface (and its child
/// process) is created once when the view is first made and lives as long as
/// the SwiftUI view identity; give it a new `.id(...)` to restart.
struct HerdTerminalView: NSViewRepresentable {
    let command: String
    let environment: [String: String]
    let workingDirectory: String?
    /// Terminal rows clipped off the top (Herd hides the engine's tab row).
    var hiddenTopRows = 0
    /// Where that row lands when content is anchored to the bottom.
    @ObservedObject var anchor: TerminalAnchor
    var onTitleChange: (String) -> Void = { _ in }
    var onExit: () -> Void = {}

    init(
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        hiddenTopRows: Int = 0,
        anchor: TerminalAnchor,
        onTitleChange: @escaping (String) -> Void = { _ in },
        onExit: @escaping () -> Void = {}
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.hiddenTopRows = hiddenTopRows
        self.anchor = anchor
        self.onTitleChange = onTitleChange
        self.onExit = onExit
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = HerdTerminalRuntime.shared.makeSurfaceView(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        )
        view.onTitleChange = onTitleChange
        view.onExit = onExit

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
    private let stage = FlippedView()
    private let anchor: TerminalAnchor
    private var lastCursorRow: UInt16 = .max

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
        startBottomAnchor()
    }

    deinit {
        anchorTimer?.invalidate()
    }

    /// Watches the cursor so the shift follows the prompt as output grows.
    private func startBottomAnchor() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBottomAnchor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        anchorTimer = timer
    }

    @MainActor
    private func updateBottomAnchor() {
        let rows = SettingsStore.shared.values.textPosition == .bottom ? measureBlankRowsBelowCursor() : 0
        guard rows != blankRowsBelow else { return }
        blankRowsBelow = rows
        needsLayout = true
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
        lastCursorRow = metrics.cursor_row

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
