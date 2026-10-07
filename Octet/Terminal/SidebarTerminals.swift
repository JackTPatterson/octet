import AppKit
import GhosttyKit

/// The terminal in each window's right panel, so an agent that's been let
/// in can read what it shows (`TerminalAccessCenter`). Each window has its
/// own; the registry holds the surface weakly and learns when its shell exits.
@MainActor
final class SidebarTerminals {
    static let shared = SidebarTerminals()

    struct Entry {
        weak var view: TerminalEngine.SurfaceView?
        var title = ""
        var exited = false
    }

    private var entries: [UUID: Entry] = [:]

    func register(window: UUID, view: TerminalEngine.SurfaceView) {
        entries[window] = Entry(view: view)
    }

    func titleChanged(window: UUID, _ title: String) {
        entries[window]?.title = title
    }

    func exited(window: UUID) {
        entries[window]?.exited = true
    }

    /// The terminal in `window`, else the only one there is. With several
    /// windows open and none in the one asked about, there is no good guess,
    /// so none is made.
    func entry(for window: UUID?) -> Entry? {
        if let window, let entry = entries[window], entry.view != nil { return entry }
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
}
