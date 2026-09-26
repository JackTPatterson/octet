import Foundation

/// `octet-cli panes` and `read`: the session's panes as lines a script can
/// cut, and a screen without the blank rows below its last text.
enum PaneListing {
    /// id, agent (or -), status, folder, and * for the pane in front; tab-separated.
    static func lines(snapshot: [String: Any]) -> [String] {
        let focused = snapshot["focused_pane_id"] as? String
        let panes = snapshot["panes"] as? [[String: Any]] ?? []
        return panes.compactMap { pane in
            guard let id = pane["pane_id"] as? String else { return nil }
            let agent = (pane["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "-"
            let status = pane["agent_status"] as? String ?? "unknown"
            let folder = pane["foreground_cwd"] as? String ?? pane["cwd"] as? String ?? ""
            return [id, agent, status, folder, id == focused ? "*" : ""].joined(separator: "\t")
        }
    }

    /// Trailing spaces on each line and blank rows at the end dropped.
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            while line.last == " " { line.removeLast() }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
