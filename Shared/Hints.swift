import Foundation

/// Hints mode: everything worth opening on the screen (links, `file:line`
/// references, commit hashes) gets a short label to type, as kitty's hints
/// and WezTerm's QuickSelect do.
enum Hints {
    enum Kind: Equatable { case url, path, hash }

    struct Hint: Equatable {
        let label: String
        let kind: Kind
        let text: String
        /// Where it starts on screen, in cells.
        let row: Int
        let column: Int
        /// For a path: the line (and column) it points at.
        var line: Int?
        var lineColumn: Int?
    }

    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.url, try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#)),
        // `src/app.swift:12:5`, `./a/b.ts:3`, `Sources/x.swift`: a path with a
        // folder or a line, and an extension.
        (.path, try! NSRegularExpression(pattern: #"(?<![\w/.~-])(?:~|\.{1,2})?/?(?:[\w.@+-]+/)*[\w@+-][\w.@+-]*\.[A-Za-z][A-Za-z0-9]{0,9}(?::\d+(?::\d+)?)?"#)),
        (.hash, try! NSRegularExpression(pattern: #"(?<![\w])[0-9a-f]{7,40}(?![\w])"#)),
    ]

    /// Home-row letters first, then the rest; two letters once those run out.
    static func labels(count: Int) -> [String] {
        let letters = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)
        guard count > letters.count else { return Array(letters.prefix(count)) }
        var result: [String] = []
        for first in letters { for second in letters { result.append(first + second) } }
        return Array(result.prefix(count))
    }

    static func find(in lines: [String]) -> [Hint] {
        var found: [(Kind, String, Int, Int)] = []
        for (row, line) in lines.enumerated() {
            let ns = line as NSString
            var taken: [NSRange] = []
            for (kind, regex) in patterns {
                for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    var range = match.range
                    // Sentence punctuation after a link or path isn't part of it.
                    while range.length > 0, ".,;:)]}'\"".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                        range.length -= 1
                    }
                    guard range.length > 0, !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                    let text = ns.substring(with: range)
                    if kind == .path, !text.contains("/"), !text.contains(":") { continue }
                    if kind == .hash, !(text.contains(where: \.isLetter) && text.contains(where: \.isNumber)) { continue }
                    taken.append(range)
                    let column = (ns.substring(to: range.location) as String).count
                    found.append((kind, text, row, column))
                }
            }
        }
        found.sort { ($0.2, $0.3) < ($1.2, $1.3) }
        return zip(found, labels(count: found.count)).map { item, label in
            var hint = Hint(label: label, kind: item.0, text: item.1, row: item.2, column: item.3)
            if item.0 == .path {
                let parts = item.1.split(separator: ":")
                if parts.count >= 2 { hint.line = Int(parts[1]) }
                if parts.count >= 3 { hint.lineColumn = Int(parts[2]) }
            }
            return hint
        }
    }

    /// The file a path hint names, from the pane's folder.
    static func file(of hint: Hint, cwd: String?, home: String = NSHomeDirectory()) -> String {
        let path = String(hint.text.split(separator: ":").first ?? "")
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return home + path.dropFirst() }
        return ((cwd ?? home) as NSString).appendingPathComponent(path)
    }
}
