import Foundation

/// How Octet moves one window's engine client: by that client's own keys.
///
/// Each Octet window is its own client of the engine's session. Measured
/// against herdr with two clients attached: keys typed into one client move
/// only that client (tab 1 and tab 2 side by side), while an API focus call
/// (`tab.focus`, `workspace.focus`, or anything sent with `focus: true`)
/// moves every client at once (both jumped to tab 3). So with one window,
/// Octet navigates through the API as it always has; with more, a window goes
/// where it's asked by being sent these keys.
///
/// The engine's defaults leave workspace switching unbound, so Octet binds
/// what it uses in the engine config it writes (`keysConfig`). Workspace
/// moves are sent with Control: the terminal only encodes Option as Alt
/// when "Use Option as Alt" is on, and with it off (the default) a sent
/// Alt+2 arrived as a plain 2, which the engine read as "tab 2". The Alt
/// bindings stay for anyone who types them.
enum EngineNavigation {
    /// One key press: a `TerminalEngine.Input.Key` raw value and modifiers.
    struct Stroke: Equatable {
        let key: String
        var ctrl = false
        var alt = false

        /// The character a plain press types, for the terminal's text field;
        /// chords leave it to the terminal to encode.
        var text: String? {
            guard !ctrl, !alt else { return nil }
            if key.hasPrefix("digit") { return String(key.dropFirst(5)) }
            return key.count == 1 ? key : nil
        }

        /// The key's unshifted character, which terminals encode chords from.
        var codepoint: UInt32 {
            let character = key.hasPrefix("digit") ? String(key.dropFirst(5)) : key
            return character.count == 1 ? character.unicodeScalars.first!.value : 0
        }
    }

    /// Bindings Octet owns in the engine's config, so these moves never
    /// depend on what the engine's defaults happen to be.
    static let keysConfig = """
    [keys]
    prefix = "ctrl+b"
    switch_tab = "prefix+1..9"
    next_tab = "prefix+n"
    previous_tab = "prefix+p"
    switch_workspace = ["prefix+alt+1..9", "prefix+ctrl+1..9"]
    next_workspace = ["prefix+alt+n", "prefix+ctrl+n"]
    previous_workspace = ["prefix+alt+p", "prefix+ctrl+p"]
    """

    static let prefix = Stroke(key: "b", ctrl: true)

    /// Keys from the workspace at `current` to the one at `target`, both
    /// positions in the engine's order (0-based). The first nine are one
    /// indexed jump; past that, a jump to the ninth and steps from there, or
    /// steps from where the client is when that's known and nearer.
    static func toWorkspace(from current: Int?, to target: Int) -> [Stroke] {
        guard target >= 0, current != target else { return [] }
        return move(from: current, to: target, jump: { [prefix, Stroke(key: "digit\($0 + 1)", ctrl: true)] },
                    next: [prefix, Stroke(key: "n", ctrl: true)], previous: [prefix, Stroke(key: "p", ctrl: true)])
    }

    /// Keys from the tab at `current` to the one at `target`, both positions
    /// in the workspace (0-based), the same way.
    static func toTab(from current: Int?, to target: Int) -> [Stroke] {
        guard target >= 0, current != target else { return [] }
        return move(from: current, to: target, jump: { [prefix, Stroke(key: "digit\($0 + 1)")] },
                    next: [prefix, Stroke(key: "n")], previous: [prefix, Stroke(key: "p")])
    }

    /// Positions 0–8 are indexed; anything further is reached by stepping.
    private static let indexed = 9

    private static func move(from current: Int?, to target: Int, jump: (Int) -> [Stroke],
                             next: [Stroke], previous: [Stroke]) -> [Stroke] {
        if target < indexed { return jump(target) }
        // From the ninth, or from where the client is if that's closer.
        let fromNinth = target - (indexed - 1)
        if let current, abs(target - current) < fromNinth {
            let steps = target - current
            return Array(repeating: steps > 0 ? next : previous, count: abs(steps)).flatMap { $0 }
        }
        return jump(indexed - 1) + Array(repeating: next, count: fromNinth).flatMap { $0 }
    }
}

/// Where something an engine call created ended up. Each create answers in
/// its own shape (`tab.create` with `tab`, `workspace.create` with
/// `workspace` and `tab`, `layout.apply` with `layout`, `pane.move` with
/// `move_result.pane`, `pane.split` with `pane`); this finds the ids in any
/// of them, so a window can be steered to what was just made.
struct EngineCreated: Equatable {
    var workspaceId: String?
    var tabId: String?
    var paneId: String?

    init(workspaceId: String? = nil, tabId: String? = nil, paneId: String? = nil) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.paneId = paneId
    }

    init(result: [String: Any]) {
        let move = result["move_result"] as? [String: Any]
        let places = [result["layout"], result["tab"], move?["pane"], result["pane"], result["root_pane"], result["workspace"]]
            .compactMap { $0 as? [String: Any] }
        workspaceId = places.lazy.compactMap { $0["workspace_id"] as? String }.first
        tabId = places.lazy.compactMap { $0["tab_id"] as? String }.first
            ?? (result["workspace"] as? [String: Any])?["active_tab_id"] as? String
        paneId = [move?["pane"], result["pane"], result["root_pane"]].lazy
            .compactMap { ($0 as? [String: Any])?["pane_id"] as? String }.first
            ?? (result["layout"] as? [String: Any])?["focused_pane_id"] as? String
    }
}
