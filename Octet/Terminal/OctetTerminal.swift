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
    static func cursorAnchor(rightEdge: Int? = nil) -> CursorAnchor? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let content = window.contentView,
              let surface = findSurface(in: content),
              let handle = surface.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(handle, &metrics), metrics.cursor_in_viewport else { return nil }
        // Measured in the pane grid's coordinates: that is what SwiftUI's
        // overlays on the terminal area sit on.
        var origin = CGPoint.zero
        var ancestor = surface.superview
        while let view = ancestor, !(view is NativePaneGrid.GridView) { ancestor = view.superview }
        if let grid = ancestor { origin = surface.convert(surface.bounds, to: grid).origin }
        let x = origin.x + metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width
        let y = origin.y + metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height
        return CursorAnchor(
            origin: CGPoint(x: x, y: y),
            cellWidth: metrics.cell_width,
            cellHeight: metrics.cell_height,
            columnsRemaining: max(0, min(Int(metrics.columns), rightEdge ?? Int.max) - Int(metrics.cursor_column))
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
        var codes: [String: UInt16] = ["return": 36, "tab": 48, "space": 49, "up": 126, "down": 125, "right": 124, "left": 123,
                                       "home": 115, "end": 119, "pgup": 116, "pgdn": 121]
        for (letter, code) in zip("asdfhgzxcv_bqweryt", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17] as [UInt16]) where letter != "_" {
            codes[String(letter)] = code
        }
        for (letter, code) in zip("ouipljkn m", [31, 32, 34, 35, 37, 38, 40, 45, 49, 46] as [UInt16]) where letter != " " {
            codes[String(letter)] = code
        }
        let tokens = keys.split(separator: " ")
        for (index, token) in tokens.enumerated() {
            // `wait:<seconds>` presses the rest later, as a person would
            // after a command finishes.
            if token.hasPrefix("wait:") {
                let rest = tokens[(index + 1)...].joined(separator: " ")
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(token.dropFirst(5)) ?? 1)) { debugPress(rest) }
                return
            }
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
            // `menu` writes the right-click menu's items to the snapshot folder.
            if token == "menu" {
                let titles = OctetTerminalMenu.menu(for: surface)?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                if let dir = ProcessInfo.processInfo.environment["OCTET_SNAPSHOT_DIR"] {
                    try? titles.joined(separator: "\n").write(toFile: dir + "/menu.txt", atomically: true, encoding: .utf8)
                }
                continue
            }
            // `drop-image:<png>` drops the image's data (no file) on the terminal.
            if token.hasPrefix("drop-image:"), let data = FileManager.default.contents(atPath: String(token.dropFirst(11))) {
                let board = NSPasteboard(name: NSPasteboard.Name("com.jpxsoftware.octet.debug-drop"))
                board.clearContents()
                board.setData(data, forType: .png)
                if let store = OctetKeyHook.store { _ = PasteHandler.handle(board, store: store) }
                continue
            }
            // `confirm-paste` presses Paste on a paste preview.
            if token == "confirm-paste" {
                if let store = OctetKeyHook.store { PastePreviewCenter.shared.send(store: store) }
                continue
            }
            // `app:<key>` goes through the app's event queue instead, so key
            // monitors (the new-tab splash's) see it as they'd see a real press.
            let viaApp = token.hasPrefix("app:")
            var parts = token.dropFirst(viaApp ? 4 : 0).split(separator: "+").map(String.init)
            let key = parts.removeLast()
            guard let code = codes[key] else { continue }
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("shift") { flags.insert(.shift) }
            if parts.contains("opt") { flags.insert(.option) }
            if parts.contains("ctrl") { flags.insert(.control) }
            if parts.contains("cmd") { flags.insert(.command) }
            let special: [String: String] = ["return": "\r", "tab": "\t", "space": " ",
                                             "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
                                             "home": "\u{F729}", "end": "\u{F72B}", "pgup": "\u{F72C}", "pgdn": "\u{F72D}"]
            let typed = special[key] ?? key
            let character = flags.contains(.shift) ? typed.uppercased() : typed
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: character, charactersIgnoringModifiers: typed,
                                                   isARepeat: false, keyCode: code) else { continue }
                if viaApp { NSApp.postEvent(event, atStart: false); continue }
                if type == .keyDown { surface.keyDown(with: event) } else { surface.keyUp(with: event) }
            }
        }
    }
    #endif

    private static func findSurface(in view: NSView) -> TerminalEngine.SurfaceView? {
        // Natively drawn panes: the one the engine has in front.
        if let focused = WindowRegistry.shared.key?.focusedPaneId,
           let pane = findPane(focused, in: view) { return pane.surface }
        return firstSurface(in: view)
    }

    private static func findPane(_ paneId: String, in view: NSView) -> PaneMirrorView? {
        // Panes of other tabs are kept, hidden: never theirs.
        guard !view.isHidden else { return nil }
        if let pane = view as? PaneMirrorView, pane.paneId == paneId { return pane }
        return view.subviews.lazy.compactMap { findPane(paneId, in: $0) }.first
    }

    private static func firstSurface(in view: NSView) -> TerminalEngine.SurfaceView? {
        guard !view.isHidden else { return nil }
        if let surface = view as? TerminalEngine.SurfaceView { return surface }
        for sub in view.subviews {
            if let surface = firstSurface(in: sub) { return surface }
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

extension OctetTerminalRuntime {
    /// A terminal view with no process: it shows what's handed to
    /// `processOutput` and passes what's typed into it to `input`, encoded as
    /// a program reads it (keys, paste, mouse).
    func makeMirrorView(input: @escaping (Data) -> Void) -> TerminalEngine.SurfaceView {
        guard let cApp = app.app else {
            fatalError("terminal engine app failed to initialize")
        }
        var config = TerminalEngine.SurfaceConfiguration()
        config.mirror = TerminalEngine.MirrorInput(input)
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
    var retainedSurface: TerminalEngine.SurfaceView?
    let command: String
    let environment: [String: String]
    let workingDirectory: String?
    var onTitleChange: (String) -> Void = { _ in }
    var onExit: () -> Void = {}
    /// Hands over the surface once made: the window sends its keys to it.
    var onSurface: (TerminalEngine.SurfaceView) -> Void = { _ in }

    init(
        retainedSurface: TerminalEngine.SurfaceView? = nil,
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        onTitleChange: @escaping (String) -> Void = { _ in },
        onExit: @escaping () -> Void = {},
        onSurface: @escaping (TerminalEngine.SurfaceView) -> Void = { _ in }
    ) {
        self.retainedSurface = retainedSurface
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.onTitleChange = onTitleChange
        self.onExit = onExit
        self.onSurface = onSurface
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = retainedSurface ?? OctetTerminalRuntime.shared.makeSurfaceView(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        )
        view.onTitleChange = onTitleChange
        view.onExit = onExit
        onSurface(view)

        // Grab keyboard focus once we're in a window.
        view.focusOnAttach = true
        return view
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TerminalEngine.SurfaceView else { return }
        // Keep callbacks current (closures may capture fresh SwiftUI state).
        view.onTitleChange = onTitleChange
        view.onExit = onExit
    }
}

/// The terminal grid as the new-tab splash reads it: where the prompt is,
/// and whether anything but a prompt has been printed.
struct TerminalGrid: Equatable {
    /// The cursor's row, from the pane's top.
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
