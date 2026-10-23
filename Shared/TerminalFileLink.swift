import Foundation

/// A file path ⌘-clicked in a terminal, as the file it names and the line it
/// points at: `src/app.swift:42:7`, `./notes.md`, `~/todo.txt`, `file:///…`.
/// Relative paths are the shell's, so they resolve against its folder.
enum TerminalFileLink {
    struct Target: Equatable {
        let path: String
        let line: Int?
    }

    /// Whether a link could be a path. `main.swift:42` parses as a URL
    /// whose scheme is `main.swift`, so a scheme alone doesn't make it one:
    /// only `://` (other than `file://`) or `mailto:` does.
    static func mayBeFile(_ link: String) -> Bool {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.hasPrefix("file:") || (!raw.contains("://") && !raw.hasPrefix("mailto:"))
    }

    /// Nil for a web address, a folder, or a path to nothing.
    static func resolve(_ link: String, cwd: String?, isFile: (String) -> Bool) -> Target? {
        guard mayBeFile(link) else { return nil }
        var raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("file:"), let url = URL(string: raw) { raw = url.path }
        guard !raw.isEmpty else { return nil }
        // The path as written first, in case its name has a colon in it.
        var candidates: [(path: String, line: Int?)] = [(raw, nil)]
        if let located = located(raw) { candidates.append(located) }
        // `a/src/x.swift` and `b/…`, as a diff prints them.
        for candidate in candidates where candidate.path.hasPrefix("a/") || candidate.path.hasPrefix("b/") {
            candidates.append((String(candidate.path.dropFirst(2)), candidate.line))
        }
        for (path, line) in candidates {
            guard let full = absolute(path, cwd: cwd), isFile(full) else { continue }
            return Target(path: full, line: line)
        }
        return nil
    }

    /// The word under `column` of a terminal row: what a ⌘-click on a bare
    /// path (`src/app.swift:12`, which the terminal doesn't underline) means.
    /// Quotes, brackets and a sentence's closing punctuation aren't part of it.
    static func word(inLine line: String, column: Int) -> String? {
        let characters = Array(line)
        guard column >= 0, column < characters.count else { return nil }
        let breaks = Set(" \t\"'`()[]{}<>|,;")
        guard !breaks.contains(characters[column]) else { return nil }
        var start = column, end = column
        while start > 0, !breaks.contains(characters[start - 1]) { start -= 1 }
        while end + 1 < characters.count, !breaks.contains(characters[end + 1]) { end += 1 }
        var word = String(characters[start...end])
        while let last = word.last, ".!?".contains(last) { word.removeLast() }
        return word.isEmpty ? nil : word
    }

    /// `path:12`, `path:12:3` and `path(12,3)`, as compilers and test
    /// runners print them.
    private static func located(_ raw: String) -> (String, Int?)? {
        for pattern in [#"^(.+?):(\d+)(?::\d+)?:?$"#, #"^(.+?)\((\d+)(?:,\d+)?\)$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let path = Range(match.range(at: 1), in: raw), let line = Range(match.range(at: 2), in: raw) else { continue }
            return (String(raw[path]), Int(raw[line]))
        }
        return nil
    }

    private static func absolute(_ path: String, cwd: String?) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}
