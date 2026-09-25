import Foundation

/// Text copied out of an agent's terminal interface carries its layout: the
/// indent it draws under a bullet, the `⏺` and `⎿` markers, box edges, and
/// the spaces that pad every line to the pane's width. Pasted anywhere else
/// that's noise, so it's taken off; what's inside keeps its own shape, code
/// indentation included.
enum CopyTidy {
    /// Line-leading marks agents draw: Claude's `⏺`/`●` and `⎿`, Codex's `•`
    /// and `└`, then any spaces after.
    private static let markers: [Character] = ["⏺", "●", "⎿", "•", "└"]

    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { trimTrailing($0) }
        lines = stripBox(lines)
        lines = lines.map(stripMarker)
        lines = dedent(lines)
        // Blank lines the selection picked up above and below.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func trimTrailing(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\t" || last == "\u{00A0}" { line.removeLast() }
        return String(line)
    }

    /// `│ text │` on every non-blank line: the edges come off.
    private static func stripBox(_ lines: [String]) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let edges: Set<Character> = ["│", "┃", "║"]
        guard !content.isEmpty, content.allSatisfy({ line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.first.map(edges.contains) == true && trimmed.last.map(edges.contains) == true && trimmed.count >= 2
        }) else { return lines }
        return lines.map { line in
            var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
            guard trimmed.count >= 2 else { return "" }
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimTrailing(String(trimmed))
        }
    }

    /// The marker is replaced by as many spaces, so the lines under it
    /// (indented to line up with its text) dedent together with it.
    private static func stripMarker(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, markers.contains(first) else { return line }
        let after = rest.dropFirst()
        // A marker is followed by a space; "•item" isn't a marker.
        guard after.first == " " || after.isEmpty else { return line }
        return String(indent) + " " + after
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }
        guard let common = indents.min(), common > 0 else { return lines }
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(common)) }
    }
}

/// Markdown as the words it shows: marks and fences gone, links as their text.
enum MarkdownPlain {
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            var text = line
            if let hashes = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { text.removeSubrange(hashes) }
            text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}
