import Foundation

/// The terminal find bar's search. The session server's own search covers
/// the whole retained buffer. Octet's build of it takes `case_sensitive` and
/// `regex`; a stock Herdr takes a literal query and matches case only when
/// the query has a capital in it. With a stock one, a regular expression,
/// or matching case on an all-lowercase query, is searched here instead,
/// over the rows `pane.read` returns (the most recent thousand).
enum OutputFind {
    /// The most rows `pane.read` hands back.
    static let readableRows = 1000

    enum Failure: Error, Equatable {
        case badPattern
    }

    /// `serverHasOptions`: the server is Octet's build, which takes both.
    static func searchesLocally(query: String, caseSensitive: Bool, regex: Bool, serverHasOptions: Bool) -> Bool {
        guard !serverHasOptions else { return false }
        return regex || (caseSensitive && !query.contains(where: \.isUppercase))
    }

    /// The `pane.copy_search` parameters for the query and toggles. A stock
    /// server ignores the options, so the query itself is lower-cased when
    /// case doesn't matter, since a capital would make it match case.
    static func serverParameters(query: String, caseSensitive: Bool, regex: Bool) -> [String: Any] {
        ["query": caseSensitive || regex ? query : query.lowercased(), "case_sensitive": caseSensitive, "regex": regex]
    }

    /// Every match in `lines`, top down, in buffer coordinates: line `i` is
    /// row `firstRow + i`, columns are terminal cells. Matches don't span
    /// lines, and an empty match (a pattern like `a*`) isn't one.
    static func matches(in lines: [String], firstRow: Int, query: String,
                        caseSensitive: Bool, regex: Bool) throws -> [TerminalSearchMatch] {
        guard !query.isEmpty else { return [] }
        var options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        if !regex { options.insert(.ignoreMetacharacters) }
        let expression: NSRegularExpression
        do { expression = try NSRegularExpression(pattern: query, options: options) } catch { throw Failure.badPattern }
        var found: [TerminalSearchMatch] = []
        for (offset, line) in lines.enumerated() {
            let whole = NSRange(line.startIndex..., in: line)
            for result in expression.matches(in: line, range: whole) where result.range.length > 0 {
                guard let range = Range(result.range, in: line) else { continue }
                let start = CellWidth.columns(line, upTo: line.distance(from: line.startIndex, to: range.lowerBound))
                let end = CellWidth.columns(line, upTo: line.distance(from: line.startIndex, to: range.upperBound)) - 1
                let row = firstRow + offset
                found.append(TerminalSearchMatch(start: .init(row: row, col: start), end: .init(row: row, col: max(start, end))))
            }
        }
        return found
    }

    /// Scrolls `match` to about the middle of the view, never past the
    /// buffer: the `offset_from_bottom` for `pane.scroll`.
    static func scrollOffset(for match: TerminalSearchMatch, maximum: Int, viewportRows: Int) -> Int {
        let top = max(0, match.start.row - max(0, viewportRows) / 2)
        return max(0, min(maximum, maximum - top))
    }

    /// The lines of a `pane.read` text, one per row: a trailing newline
    /// isn't a row of its own.
    static func rows(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The next match from `index` going up (`backward`, toward older output)
    /// or down, wrapping round; nil starts from the newest.
    static func step(from index: Int?, backward: Bool, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return count - 1 }
        return ((backward ? index - 1 : index + 1) % count + count) % count
    }

    /// What the bar shows, beside a field ringed in red, for a regular
    /// expression that doesn't compile (or that matches empty text).
    static let invalidPattern = "Invalid pattern"

    /// What the bar says when a search fails, in words rather than codes.
    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure, failure == .badPattern { return invalidPattern }
        if let socket = error as? EngineSocketError {
            switch socket {
            case .server(let code, _) where code == "invalid_regex": return invalidPattern
            case .server(let code, _) where code == "not_found": return "This pane has closed"
            case .server(let code, _) where code == "stale_content": return "The output kept changing; try again"
            case .server(let code, _) where code == "query_too_large": return "That's too long to search for"
            case .connectFailed, .closed, .writeFailed: return "Lost the connection to the terminal"
            default: break
            }
        }
        return "Couldn't search this pane"
    }
}
