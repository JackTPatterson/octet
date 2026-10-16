import AppKit
import Darwin
import GhosttyKit

/// The terminal in the right panel, one per workspace, so an agent that's
/// been let in can read what it shows (`TerminalAccessCenter`). The registry
/// holds each surface weakly, keyed by workspace, and learns when its shell
/// exits.
/// It also puts a command an agent suggests at the prompt, never running it.
@MainActor
final class SidebarTerminals {
    static let shared = SidebarTerminals()

    struct Entry {
        weak var view: TerminalEngine.SurfaceView?
        var title = ""
        var exited = false
    }

    /// The key for a workspace's terminal; a window with no workspace in
    /// front still gets one.
    static func key(_ workspaceId: String?) -> String { workspaceId ?? "" }

    private var entries: [String: Entry] = [:]

    func register(workspace: String, view: TerminalEngine.SurfaceView) {
        entries[workspace] = Entry(view: view)
    }

    func titleChanged(workspace: String, _ title: String) {
        entries[workspace]?.title = title
    }

    func exited(workspace: String) {
        entries[workspace]?.exited = true
    }

    /// The terminal of `workspace`, else the only one there is. With several
    /// open and none in the workspace asked about, there is no good guess,
    /// so none is made.
    func entry(for workspace: String?) -> Entry? {
        if let workspace, let entry = entries[workspace], entry.view != nil { return entry }
        let live = entries.values.filter { $0.view != nil }
        return live.count == 1 ? live.first : nil
    }

    var hasAny: Bool { entries.values.contains { $0.view != nil } }

    /// Everything the terminal holds, scrollback included, as plain text;
    /// the screen alone if the whole can't be read.
    func text(of view: TerminalEngine.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        for tag in [GHOSTTY_POINT_SCREEN, GHOSTTY_POINT_VIEWPORT] {
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: false)
            guard ghostty_surface_read_text(surface, selection, &text) else { continue }
            defer { ghostty_surface_free_text(surface, &text) }
            return String(cString: text.text)
        }
        return nil
    }

    // MARK: - A command for the person to run

    enum StageFailure: Error, CustomStringConvertible {
        case exited, busy(String), unavailable
        var description: String {
            switch self {
            case .exited: "The sidebar terminal's shell has exited. Ask the person to start it again."
            case .busy(let name): "The sidebar terminal is busy running \(name), not waiting at a prompt. Ask the person to stop it first, or read its output instead."
            case .unavailable: "Couldn't reach the sidebar terminal."
            }
        }
    }

    /// Types `command` at the prompt without Return, replacing whatever was
    /// being typed, but only while a shell is in front.
    func stage(_ command: String, in view: TerminalEngine.SurfaceView) throws {
        guard let model = view.surfaceModel else { throw StageFailure.unavailable }
        if view.processExited { throw StageFailure.exited }
        if let pid = model.foregroundPID {
            var name = [CChar](repeating: 0, count: 256)
            if proc_name(Int32(pid), &name, UInt32(name.count)) > 0 {
                let running = String(cString: name)
                if !TerminalControl.isShell(running) { throw StageFailure.busy(running) }
            }
        }
        model.sendText("\u{15}" + command)
        view.window?.makeFirstResponder(view)
    }

    /// Runs what is at the prompt: the person pressed Run.
    func run(in view: TerminalEngine.SurfaceView) {
        view.surfaceModel?.sendText("\r")
        view.window?.makeFirstResponder(view)
    }

    /// Clears the line without running it.
    func clearLine(in view: TerminalEngine.SurfaceView) {
        view.surfaceModel?.sendText("\u{15}")
        view.window?.makeFirstResponder(view)
    }

    func view(for workspace: String) -> TerminalEngine.SurfaceView? {
        entries[workspace]?.view
    }
}

/// The command an agent has put at a workspace's sidebar terminal, shown over it
/// with Run and Clear until the person acts or it goes stale.
@MainActor
final class SidebarSuggestions: ObservableObject {
    static let shared = SidebarSuggestions()

    struct Suggestion: Equatable {
        let command: String
        let at: Date
    }

    static let lifetime: TimeInterval = 120

    @Published private(set) var pending: [String: Suggestion] = [:]

    func set(_ command: String, workspace: String) {
        let suggestion = Suggestion(command: command, at: Date())
        pending[workspace] = suggestion
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in
            guard self?.pending[workspace] == suggestion else { return }
            self?.pending[workspace] = nil
        }
    }

    func dismiss(workspace: String) {
        pending[workspace] = nil
    }
}
