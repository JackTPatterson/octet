import Foundation

/// A small line diff for showing an agent's edits: unchanged lines at both
/// ends are trimmed to a little context, and the middle shows what went and
/// what came. Enough for Edit-sized changes without a full diff algorithm.
enum LineDiff {
    struct Line: Equatable {
        enum Kind: Equatable { case context, removed, added }
        let kind: Kind
        let text: String
        /// 1-based positions within the snippet: the old text for context
        /// and removed lines, the new text for context and added lines.
        var oldNumber: Int?
        var newNumber: Int?

        init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
        }

        /// The number to show in a single gutter: the new file's line, or
        /// the old one for a removed line.
        var number: Int? { kind == .removed ? oldNumber : newNumber }

        static func == (lhs: Line, rhs: Line) -> Bool { lhs.kind == rhs.kind && lhs.text == rhs.text }
    }

    static func lines(old: String, new: String, context: Int = 2) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }

        var result: [Line] = []
        for index in max(0, prefix - context)..<prefix {
            result.append(Line(kind: .context, text: before[index], oldNumber: index + 1, newNumber: index + 1))
        }
        for index in prefix..<(before.count - suffix) {
            result.append(Line(kind: .removed, text: before[index], oldNumber: index + 1))
        }
        for index in prefix..<(after.count - suffix) {
            result.append(Line(kind: .added, text: after[index], newNumber: index + 1))
        }
        let tailStart = before.count - suffix
        let shift = after.count - before.count
        for index in tailStart..<min(before.count, tailStart + context) {
            result.append(Line(kind: .context, text: before[index], oldNumber: index + 1, newNumber: index + shift + 1))
        }
        return result
    }

    /// A new file: every line added.
    static func added(_ content: String) -> [Line] {
        content.components(separatedBy: "\n").enumerated().map { Line(kind: .added, text: $1, newNumber: $0 + 1) }
    }

    /// Where `snippet` starts in `file`, as a 1-based line number, so a
    /// snippet's numbers can be shown as the file's.
    static func startLine(of snippet: String, in file: String) -> Int? {
        guard !snippet.isEmpty, let range = file.range(of: snippet) else { return nil }
        return file[file.startIndex..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
