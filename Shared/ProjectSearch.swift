import Foundation

/// Searching a project's file contents, after T3 Code's project content
/// search: what to look for, a match, and reading the tools' output. The
/// search itself (ripgrep, else `git grep`, else a scan) runs in Octet; these
/// are the parts that can be tested without a process.
struct ProjectSearchOptions: Equatable {
    var query: String
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    /// Files to include, as globs separated by commas or spaces; a leading
    /// "!" leaves matching files out ("*.swift, !*Tests*").
    var include = ""

    var globs: [String] {
        include.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "!" }
    }

    /// ripgrep's arguments, run in the project folder: JSON out, .gitignore
    /// respected, dotfiles in but never `.git` itself.
    var ripgrepArguments: [String] {
        var arguments = ["--json", "--no-messages", "--hidden", "--glob", "!.git",
                         "--max-columns", "4000", "--max-filesize", "4M", "--max-count", "200",
                         caseSensitive ? "--case-sensitive" : "--ignore-case"]
        if wholeWord { arguments.append("--word-regexp") }
        if !regex { arguments.append("--fixed-strings") }
        for glob in globs { arguments += ["--glob", glob] }
        arguments += ["--regexp", query, "--", "."]
        return arguments
    }

    /// `git grep`'s: NUL-separated path and line number, tracked and
    /// untracked-but-not-ignored files, text only.
    var gitGrepArguments: [String] {
        var arguments = ["grep", "-z", "-n", "-I", "--no-color", "--untracked"]
        if !caseSensitive { arguments.append("-i") }
        if wholeWord { arguments.append("-w") }
        arguments.append(regex ? "-E" : "-F")
        arguments += ["-e", query, "--"]
        let specs = globs.map { $0.hasPrefix("!") ? ":(exclude)" + $0.dropFirst() : $0 }
        // Exclusions alone need something to exclude from.
        if !specs.isEmpty, specs.allSatisfy({ $0.hasPrefix(":(exclude)") }) { arguments.append(".") }
        return arguments + specs
    }
}

/// One matching line.
struct ProjectSearchMatch: Equatable, Identifiable {
    /// Relative to the folder searched.
    let path: String
    /// 1-based.
    let line: Int
    /// The line, without its line break.
    let text: String
    /// Where the query matched, as UTF-16 offsets into `text` (what
    /// NSString and the editor count in).
    let ranges: [Range<Int>]

    var id: String { "\(path):\(line)" }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }
}

/// The query as a regular expression, for the searches that don't report
/// where a line matched (`git grep`, the scan), and to catch a bad regex.
struct ProjectSearchMatcher {
    let expression: NSRegularExpression

    /// nil for an empty query, or one that isn't a valid expression.
    init?(_ options: ProjectSearchOptions) {
        guard !options.query.isEmpty else { return nil }
        var pattern = options.regex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: options.caseSensitive ? [] : [.caseInsensitive])
        else { return nil }
        self.expression = expression
    }

    func ranges(in text: String) -> [Range<Int>] {
        let length = (text as NSString).length
        return expression.matches(in: text, range: NSRange(location: 0, length: length)).compactMap { match in
            match.range.length > 0 ? match.range.location..<(match.range.location + match.range.length) : nil
        }
    }
}

/// ripgrep's `--json` output, one event per line.
enum RipgrepJSON {
    /// The match a "match" event describes; nil for the other events
    /// (begin, end, context, summary) and for lines that aren't UTF-8,
    /// which ripgrep sends as base64 bytes.
    static func match(fromLine line: String) -> ProjectSearchMatch? {
        guard line.contains("\"type\":\"match\""),
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "match",
              let body = object["data"] as? [String: Any],
              let path = text(body["path"]),
              let raw = text(body["lines"]),
              let number = body["line_number"] as? Int else { return nil }
        let bytes = Array(raw.utf8)
        let line = withoutLineBreak(raw)
        let length = (line as NSString).length
        let ranges: [Range<Int>] = (body["submatches"] as? [[String: Any]] ?? []).compactMap { submatch in
            guard let start = submatch["start"] as? Int, let end = submatch["end"] as? Int,
                  start >= 0, start <= end, end <= bytes.count else { return nil }
            let lower = min(utf16Offset(bytes, start), length)
            let upper = min(utf16Offset(bytes, end), length)
            return lower < upper ? lower..<upper : nil
        }
        return ProjectSearchMatch(path: relative(path), line: number, text: line, ranges: ranges)
    }

    /// ripgrep counts in bytes; Octet in UTF-16.
    static func utf16Offset(_ bytes: [UInt8], _ byteOffset: Int) -> Int {
        String(decoding: bytes[..<byteOffset], as: UTF8.self).utf16.count
    }

    private static func text(_ value: Any?) -> String? {
        (value as? [String: Any])?["text"] as? String
    }
}

/// `git grep -z -n` output: path, NUL, line number, NUL, the line.
enum GitGrepOutput {
    static func match(fromLine line: String, matcher: ProjectSearchMatcher) -> ProjectSearchMatch? {
        let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let number = Int(parts[1]), !parts[0].isEmpty else { return nil }
        let text = withoutLineBreak(String(parts[2]))
        return ProjectSearchMatch(path: relative(String(parts[0])), line: number, text: text,
                                  ranges: matcher.ranges(in: text))
    }
}

/// Turning a line and its match ranges into what a result row draws.
enum ProjectSearchHighlight {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    /// In bounds, non-empty, in order, and overlapping or touching ranges
    /// merged, as T3 Code's normalizeRanges does.
    static func normalized(_ ranges: [Range<Int>], length: Int) -> [Range<Int>] {
        let clamped = ranges
            .map { max(0, min(length, $0.lowerBound))..<max(0, min(length, $0.upperBound)) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in clamped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The line cut into plain and matched runs.
    static func segments(_ text: String, ranges: [Range<Int>]) -> [Segment] {
        let string = text as NSString
        var segments: [Segment] = []
        var cursor = 0
        for range in normalized(ranges, length: string.length) {
            if range.lowerBound > cursor {
                segments.append(Segment(text: string.substring(with: NSRange(location: cursor, length: range.lowerBound - cursor)),
                                        isMatch: false))
            }
            segments.append(Segment(text: string.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                                    isMatch: true))
            cursor = range.upperBound
        }
        if cursor < string.length {
            segments.append(Segment(text: string.substring(from: cursor), isMatch: false))
        }
        return segments
    }

    /// What a row shows of a line: its indentation dropped, and when the
    /// first match is far along, the start cut to "…" so the match is in
    /// view; long lines end at `maxLength`. Ranges move with the text.
    static func preview(_ text: String, ranges: [Range<Int>], lead: Int = 40,
                        maxLength: Int = 400) -> (text: String, ranges: [Range<Int>]) {
        let string = text as NSString
        let length = string.length
        let sorted = normalized(ranges, length: length)
        var start = 0
        while start < length, let scalar = UnicodeScalar(string.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) {
            start += 1
        }
        var prefix = ""
        if let first = sorted.first, first.lowerBound - start > lead {
            start = string.rangeOfComposedCharacterSequence(at: first.lowerBound - lead).location
            prefix = "…"
        }
        if let first = sorted.first, first.lowerBound < start { start = min(start, first.lowerBound) }
        var end = length
        if end - start > maxLength {
            let cut = start + maxLength
            end = string.rangeOfComposedCharacterSequence(at: cut).location
        }
        let body = string.substring(with: NSRange(location: start, length: max(0, end - start)))
        let shift = (prefix as NSString).length - start
        let moved = sorted.map { ($0.lowerBound + shift)..<($0.upperBound + shift) }
        let shown = prefix + body
        return (shown, normalized(moved, length: (shown as NSString).length).filter { $0.lowerBound >= (prefix as NSString).length })
    }
}

/// Files with matches, in the order they were found.
enum ProjectSearchGroups {
    struct Group: Equatable, Identifiable {
        let path: String
        /// (index into the flat list, match)
        var matches: [Indexed]
        var id: String { path }
    }

    struct Indexed: Equatable {
        let index: Int
        let match: ProjectSearchMatch
    }

    static func group(_ matches: [ProjectSearchMatch]) -> [Group] {
        var order: [String] = []
        var byPath: [String: [Indexed]] = [:]
        for (index, match) in matches.enumerated() {
            if byPath[match.path] == nil { order.append(match.path) }
            byPath[match.path, default: []].append(Indexed(index: index, match: match))
        }
        return order.map { Group(path: $0, matches: byPath[$0] ?? []) }
    }

    /// `batch` added to `groups`, the matches after the first `start`:
    /// each into its file's group, or a new group at the end. `index` says
    /// where each file's group is, and is kept up to date.
    static func append(_ batch: [ProjectSearchMatch], startingAt start: Int, to groups: inout [Group],
                       index: inout [String: Int]) {
        for (offset, match) in batch.enumerated() {
            let entry = Indexed(index: start + offset, match: match)
            if let at = index[match.path] {
                groups[at].matches.append(entry)
            } else {
                index[match.path] = groups.count
                groups.append(Group(path: match.path, matches: [entry]))
            }
        }
    }
}

/// The include field's globs, for the scan (ripgrep and git apply their own).
enum ProjectSearchGlobs {
    /// A path is in when it matches an including glob (or there are none)
    /// and no "!" one. A glob without "/" matches the file name anywhere.
    static func includes(_ path: String, globs: [String]) -> Bool {
        let including = globs.filter { !$0.hasPrefix("!") }
        let excluding = globs.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        if excluding.contains(where: { matches(path, glob: $0) }) { return false }
        return including.isEmpty || including.contains { matches(path, glob: $0) }
    }

    static func matches(_ path: String, glob: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let target = glob.contains("/") ? path : name
        let pattern = glob.hasPrefix("/") ? String(glob.dropFirst()) : glob
        // fnmatch without FNM_PATHNAME lets "*" cross folders, which is what
        // "src/**/*.ts" means anyway.
        return fnmatch(pattern, target, 0) == 0 || (glob.hasSuffix("/") && path.hasPrefix(pattern))
            || (!glob.contains("*") && !glob.contains("?") && path.split(separator: "/").contains { $0 == Substring(glob) })
    }
}

private func withoutLineBreak(_ line: String) -> String {
    // "\r\n" is one Character, so this takes either ending whole.
    var line = line
    if line.hasSuffix("\r\n") || line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
    return line
}

private func relative(_ path: String) -> String {
    path.hasPrefix("./") ? String(path.dropFirst(2)) : path
}
