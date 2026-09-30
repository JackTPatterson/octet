import Foundation

/// A project's own todo list: the markdown checkboxes in `TODO.md` at its
/// root. A file rather than a server, so every agent can read and tick it
/// with no setup, it's versioned with the code, and any editor can change it.
/// Edits touch only the line they're about, so the rest of the file (prose,
/// headings, an item's wrapped lines) stays as written.
struct ProjectTodoList: Equatable {
    struct Item: Equatable, Identifiable {
        /// The item's line in the file, 0-based.
        let line: Int
        /// The first line's text, with markdown emphasis taken off.
        let text: String
        let status: AgentTodo.Status
        /// The `#` heading it sits under, if any.
        let section: String?
        var id: Int { line }
    }

    let path: String
    let items: [Item]

    var open: [Item] { items.filter { $0.status != .completed } }
    var done: [Item] { items.filter { $0.status == .completed } }
}

enum ProjectTodos {
    /// Names looked for at the project root, in order.
    static let fileNames = ["TODO.md", "todo.md", "Todo.md", "TODO.markdown"]

    /// Where the list is (or would be made) for a project rooted at `root`.
    static func path(inRoot root: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String {
        fileNames.lazy.map { root + "/" + $0 }.first(where: exists) ?? root + "/" + fileNames[0]
    }

    // `- [ ] text`, `* [x] text`, `1. [~] text`, indented or not.
    private static let itemPattern = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX~/-])(\]\s+)(.*)$"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#)

    static func parse(_ contents: String, path: String) -> ProjectTodoList {
        var items: [ProjectTodoList.Item] = []
        var section: String?
        for (index, line) in lines(contents).enumerated() {
            if let heading = match(headingPattern, line)?.first {
                section = clean(heading)
                continue
            }
            guard let parts = match(itemPattern, line) else { continue }
            let text = clean(parts[3])
            guard !text.isEmpty else { continue }
            items.append(.init(line: index, text: text, status: status(parts[1]), section: section))
        }
        return ProjectTodoList(path: path, items: items)
    }

    /// The file with the item on `line` marked `status`; nil when that line
    /// isn't an item any more (the file changed underneath).
    static func setting(_ status: AgentTodo.Status, line: Int, in contents: String) -> String? {
        var all = lines(contents)
        guard all.indices.contains(line), let parts = match(itemPattern, all[line]) else { return nil }
        let mark: String
        switch status {
        case .completed: mark = "x"
        case .inProgress: mark = "~"
        case .pending: mark = " "
        }
        all[line] = parts[0] + mark + parts[2] + parts[3]
        return join(all, like: contents)
    }

    /// The file with a new open item: after the last item when there is
    /// one, so it lands in the list, else at the end.
    static func adding(_ text: String, to contents: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return contents }
        var all = contents.isEmpty ? [] : lines(contents)
        let last = all.indices.last { match(itemPattern, all[$0]) != nil }
        if let last {
            // After the item and any lines wrapped under it.
            var end = last + 1
            while end < all.count, !all[end].trimmingCharacters(in: .whitespaces).isEmpty,
                  all[end].first?.isWhitespace == true, match(itemPattern, all[end]) == nil {
                end += 1
            }
            all.insert("- [ ] " + text, at: end)
        } else {
            while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
            if all.isEmpty { all = ["# TODO", ""] } else { all.append("") }
            all.append("- [ ] " + text)
        }
        var result = join(all, like: contents)
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// What an agent is told when an item is handed to it.
    static func prompt(for item: ProjectTodoList.Item, fileName: String) -> String {
        "Work on this item from \(fileName): \(item.text)\n\nWhen it's done, tick it off in \(fileName) by changing its \"- [ ]\" to \"- [x]\"."
    }

    // MARK: - Helpers

    private static func status(_ mark: String) -> AgentTodo.Status {
        switch mark {
        case "x", "X": .completed
        case "~", "/", "-": .inProgress
        default: .pending
        }
    }

    /// Emphasis and code marks off, so `**Fix the thing** (high)` reads plainly.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func lines(_ contents: String) -> [String] {
        var all = contents.components(separatedBy: "\n")
        if contents.hasSuffix("\n") { all.removeLast() }
        return all.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func join(_ lines: [String], like original: String) -> String {
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        let body = lines.joined(separator: newline)
        return original.hasSuffix("\n") || original.isEmpty ? body + newline : body
    }

    /// The capture groups of `pattern` in `line`, or nil when it doesn't match.
    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let found = pattern.firstMatch(in: line, range: range) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
