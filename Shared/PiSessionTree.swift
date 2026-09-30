import Foundation

/// Pi's session tree (`get_tree`) as an outline of the prompts in it: a
/// branch point indents its branches, and the branch Pi is on is marked.
enum PiSessionTree {
    struct Line: Equatable {
        let depth: Int
        let text: String
        /// On the branch the session is on now.
        let active: Bool
    }

    static func outline(_ tree: [[String: Any]], leafId: String?) -> [Line] {
        // The active branch: the leaf and everything above it.
        var parents: [String: String] = [:]
        func index(_ nodes: [[String: Any]]) {
            for node in nodes {
                let entry = node["entry"] as? [String: Any] ?? [:]
                if let id = entry["id"] as? String, let parent = entry["parentId"] as? String { parents[id] = parent }
                index(node["children"] as? [[String: Any]] ?? [])
            }
        }
        index(tree)
        var active: Set<String> = []
        var cursor = leafId
        while let id = cursor, active.insert(id).inserted { cursor = parents[id] }

        var lines: [Line] = []
        func walk(_ nodes: [[String: Any]], depth: Int) {
            for node in nodes {
                let entry = node["entry"] as? [String: Any] ?? [:]
                let id = entry["id"] as? String ?? ""
                if let text = prompt(entry) {
                    lines.append(Line(depth: depth, text: text, active: active.contains(id)))
                }
                let children = node["children"] as? [[String: Any]] ?? []
                // Only a fork in the road indents; a straight line stays put.
                walk(children, depth: children.count > 1 ? depth + 1 : depth)
            }
        }
        walk(tree, depth: 0)
        return lines
    }

    /// A user message's text, on one line.
    static func prompt(_ entry: [String: Any]) -> String? {
        guard entry["type"] as? String == "message", let message = entry["message"] as? [String: Any],
              message["role"] as? String == "user" else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else {
            text = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }

    /// Lines as text for a dialog: indented, the active branch marked.
    static func text(_ lines: [Line]) -> String {
        lines.map { String(repeating: "    ", count: $0.depth) + ($0.active ? "● " : "○ ") + $0.text }.joined(separator: "\n")
    }
}
