import Foundation

/// A project's own todo list: the markdown checkboxes in `TODO.md` at its
/// root. A file rather than a server, so every agent can read and tick it
/// with no setup, it's versioned with the code, and any editor can change it.
/// Edits touch only the line they're about, so the rest of the file (prose,
/// headings, an item's wrapped lines) stays as written.
struct ProjectTodoList: Equatable {
    struct Item: Equatable, Identifiable {
        /// The item's line in the file, 0-based: where writes go, checked
        /// against the text first.
        let line: Int
        /// The first line's text, with markdown emphasis taken off.
        let text: String
        let status: AgentTodo.Status
        /// The `#` heading it sits under, if any.
        let section: String?
        /// Which of the items with this heading and text it is, from the top.
        var occurrence = 0

        /// Who it is from its content, not its line, so an edit above it
        /// doesn't make it a different row (and the list doesn't jump).
        /// Ticking it keeps it; rewording it makes it a new item.
        var id: String { ProjectTodos.identity(section: section, text: text, occurrence: occurrence) }
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
            let occurrence = items.filter { $0.section == section && $0.text == text }.count
            items.append(.init(line: index, text: text, status: status(parts[1]), section: section, occurrence: occurrence))
        }
        return ProjectTodoList(path: path, items: items)
    }

    static func identity(section: String?, text: String, occurrence: Int) -> String {
        "\(section ?? "")\u{1f}\(text)\u{1f}\(occurrence)"
    }

    /// The file with the item on `line` reworded, keeping its mark, its
    /// bullet and its indent; nil when that line isn't an item any more, or
    /// the new text is empty.
    static func editing(_ text: String, line: Int, in contents: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        var all = lines(contents)
        guard !text.isEmpty, all.indices.contains(line), let parts = match(itemPattern, all[line]) else { return nil }
        all[line] = parts[0] + parts[1] + parts[2] + text
        return join(all, like: contents)
    }

    /// The file without the item on `line` and the lines wrapped under it.
    static func removing(line: Int, in contents: String) -> String? {
        var all = lines(contents)
        guard let block = block(at: line, in: all) else { return nil }
        all.removeSubrange(block)
        return join(all, like: contents)
    }

    /// The file with the item on `line` (and its wrapped lines) moved to
    /// just before the item on `before`; nil when either line isn't an item.
    static func moving(line: Int, before target: Int, in contents: String) -> String? {
        let all = lines(contents)
        guard let block = block(at: line, in: all), let destination = self.block(at: target, in: all) else { return nil }
        guard line != target else { return contents }
        return join(moved(all, block: block, to: destination.lowerBound), like: contents)
    }

    /// The same, landing just after the item on `after` and its wrapped lines.
    static func moving(line: Int, after target: Int, in contents: String) -> String? {
        let all = lines(contents)
        guard let block = block(at: line, in: all), let destination = self.block(at: target, in: all) else { return nil }
        guard line != target else { return contents }
        return join(moved(all, block: block, to: destination.upperBound), like: contents)
    }

    /// A plan's steps as a checklist under its own heading, to add to a
    /// list: numbered and bulleted lines become `- [ ]` items, the rest is
    /// left out. Nil when the plan has no steps.
    static func checklist(fromPlan markdown: String, title: String?) -> String? {
        let stepPattern = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX~/-]\]\s+)?(.+)$"#)
        let steps = lines(markdown).compactMap { line -> String? in
            guard let text = match(stepPattern, line)?.first else { return nil }
            let cleaned = clean(text)
            return cleaned.isEmpty ? nil : "- [ ] " + cleaned
        }
        guard !steps.isEmpty else { return nil }
        let heading = (title?.isEmpty == false ? title : nil) ?? "Plan"
        return (["## " + clean(heading), ""] + steps).joined(separator: "\n") + "\n"
    }

    /// The file with `block` (a heading and its items) at the end, a blank
    /// line apart from what's there.
    static func appending(_ block: String, to contents: String) -> String {
        var all = contents.isEmpty ? [] : lines(contents)
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        if !all.isEmpty { all.append("") }
        all += lines(block)
        var result = join(all, like: contents)
        if !result.hasSuffix("\n") { result += "\n" }
        return result
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

    /// What an agent is told when an item is handed to it. `file` is how
    /// to find the list: its name at the project root, or the full path
    /// of a list kept out of the checkout.
    static func prompt(for item: ProjectTodoList.Item, fileName file: String) -> String {
        "Work on this item from \(file): \(item.text)\n\nWhen it's done, tick it off in \(file) by changing its \"- [ ]\" to \"- [x]\"."
    }

    // MARK: - Helpers

    /// The item on `line` and the lines wrapped under it (indented, not
    /// blank, not items of their own).
    private static func block(at line: Int, in all: [String]) -> Range<Int>? {
        guard all.indices.contains(line), match(itemPattern, all[line]) != nil else { return nil }
        var end = line + 1
        while end < all.count, !all[end].trimmingCharacters(in: .whitespaces).isEmpty,
              all[end].first?.isWhitespace == true, match(itemPattern, all[end]) == nil {
            end += 1
        }
        return line..<end
    }

    /// `all` with `block` taken out and put back at `index`, an index into
    /// the lines as they were.
    private static func moved(_ all: [String], block: Range<Int>, to index: Int) -> [String] {
        guard index < block.lowerBound || index > block.upperBound else { return all }
        var rest = all
        let lifted = Array(all[block])
        rest.removeSubrange(block)
        let at = index > block.upperBound ? index - block.count : index
        rest.insert(contentsOf: lifted, at: at)
        return rest
    }

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
