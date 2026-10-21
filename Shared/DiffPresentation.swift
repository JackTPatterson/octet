import Foundation

// How a diff reads on screen, decided without a view: which words changed
// inside a changed line, the syntax colours carried down a file, which files
// start folded and why, and the status mark every file row uses.

/// The words that changed between a removed line and the added line that
/// replaces it, so a one-word edit stands out from the rest of the line.
/// After the intraline highlighting of GitHub and T3 Code's diffs.
enum IntralineDiff {
    /// Character offsets (not UTF-16) of what changed on each side.
    struct Ranges: Equatable {
        var old: [Range<Int>]
        var new: [Range<Int>]
    }

    /// Lines with more tokens than this compare by their common ends only;
    /// the full comparison grows with the product of the two lengths.
    static let tokenLimit = 400

    /// What changed in each line; nil when the lines have so little in
    /// common that marking words would only mark everything.
    static func ranges(old: String, new: String) -> Ranges? {
        guard old != new else { return Ranges(old: [], new: []) }
        let a = tokens(old), b = tokens(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix].text == b[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix].text == b[b.count - 1 - suffix].text { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        var keptA = Set<Int>(), keptB = Set<Int>()
        if midA.count <= tokenLimit, midB.count <= tokenLimit {
            (keptA, keptB) = common(midA.map(\.text), midB.map(\.text))
        }
        let changedA = midA.indices.filter { !keptA.contains($0) }.map { midA[$0] }
        let changedB = midB.indices.filter { !keptB.contains($0) }.map { midB[$0] }

        // Only whitespace in common: the line was rewritten, not edited.
        let changedStarts = Set(changedA.map(\.start))
        let sharedSolid = a.filter { !$0.isSpace && !changedStarts.contains($0.start) }.count
        let solidA = a.filter { !$0.isSpace }.count, solidB = b.filter { !$0.isSpace }.count
        guard sharedSolid > 0, Double(sharedSolid) >= 0.25 * Double(max(solidA, solidB)) else { return nil }

        return Ranges(old: merged(changedA), new: merged(changedB))
    }

    /// The changed words of each removed/added pair in a hunk, keyed by the
    /// line's index in its file. Pairs line up as the side-by-side view
    /// lines them up: each run of removed lines against the added lines
    /// that follow it, row for row.
    static func ranges(in hunk: ReviewDiff.Hunk) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        for pair in hunk.pairs {
            guard let left = pair.left, let right = pair.right,
                  left.kind == .removed, right.kind == .added,
                  let found = ranges(old: left.text, new: right.text) else { continue }
            if !found.old.isEmpty { result[left.index] = found.old }
            if !found.new.isEmpty { result[right.index] = found.new }
        }
        return result
    }

    struct Token: Equatable {
        let text: String
        /// Character offset in the line.
        let start: Int
        var end: Int { start + text.count }
        var isSpace: Bool { text.allSatisfy(\.isWhitespace) }
    }

    /// Words (letters, digits, underscores), runs of whitespace, and every
    /// other character on its own, so `foo(bar)` → `foo` `(` `bar` `)`.
    static func tokens(_ line: String) -> [Token] {
        var result: [Token] = []
        var current = "", start = 0, offset = 0
        var currentClass = 0
        func flush() {
            if !current.isEmpty { result.append(Token(text: current, start: start)) }
            current = ""
        }
        for character in line {
            let kind = character.isLetter || character.isNumber || character == "_" ? 1
                : character.isWhitespace ? 2 : 3
            if kind == 3 || kind != currentClass { flush(); start = offset }
            current.append(character)
            currentClass = kind
            offset += 1
        }
        flush()
        return result
    }

    /// Indices of the tokens on each side that belong to their longest
    /// common subsequence.
    static func common(_ a: [String], _ b: [String]) -> (Set<Int>, Set<Int>) {
        guard !a.isEmpty, !b.isEmpty else { return ([], []) }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var keptA = Set<Int>(), keptB = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                keptA.insert(i); keptB.insert(j)
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keptA, keptB)
    }

    /// Neighbouring changed tokens as one range; whitespace alone between
    /// two changes joins them, so a changed phrase reads as one mark.
    static func merged(_ tokens: [Token]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for token in tokens where !token.isSpace {
            if let last = result.last, token.start - last.upperBound <= 1 {
                result[result.count - 1] = last.lowerBound..<token.end
            } else {
                result.append(token.start..<token.end)
            }
        }
        return result
    }
}

extension ReviewDiff.File {
    /// Syntax spans for each line, by index. The old and new sides each
    /// carry their own state down the whole file, across hunks, so a block
    /// comment a hunk leaves open still reads as one in the next.
    func syntaxSpans() -> [Int: [CodeHighlighter.Span]] {
        var result: [Int: [CodeHighlighter.Span]] = [:]
        var old = CodeHighlighter.State(), new = CodeHighlighter.State()
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    result[line.index] = CodeHighlighter.highlight(line.text, state: &old)
                case .added:
                    result[line.index] = CodeHighlighter.highlight(line.text, state: &new)
                case .context:
                    _ = CodeHighlighter.highlight(line.text, state: &old)
                    result[line.index] = CodeHighlighter.highlight(line.text, state: &new)
                }
            }
        }
        return result
    }

    /// Lines changed, the count the "Large" fold goes by.
    var changedLines: Int { added + removed }
}

/// Why a file starts folded in a diff: noise nobody reads line by line.
/// Each fold shows its reason and a "Show diff" to open it anyway.
enum DiffCollapse: Equatable {
    case lockfile
    case generated
    case large(lines: Int)

    /// More changed lines than this fold a file.
    static let largeLimit = 1_000

    static let lockfiles: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
        "Cargo.lock", "Gemfile.lock", "Podfile.lock", "composer.lock", "poetry.lock", "Pipfile.lock", "uv.lock",
        "Package.resolved", "go.sum", "flake.lock", "mix.lock", "pubspec.lock", "packages.lock.json", "deno.lock",
    ]

    /// Suffixes of files a tool writes.
    static let generatedSuffixes = [
        ".min.js", ".min.css", ".min.mjs", ".js.map", ".css.map", ".pbxproj", ".snap", ".xcscheme",
        ".pb.go", "_pb2.py", ".g.dart", ".freezed.dart", ".generated.swift", ".generated.ts", ".designer.cs",
    ]

    /// Folders whose files a tool writes.
    static let generatedFolders = ["__generated__", "__snapshots__", "generated", ".yarn"]

    static func reason(path: String, changedLines: Int) -> DiffCollapse? {
        let name = (path as NSString).lastPathComponent
        if lockfiles.contains(name) || name.hasSuffix(".lock") { return .lockfile }
        let lower = path.lowercased()
        if generatedSuffixes.contains(where: { lower.hasSuffix($0) }) { return .generated }
        let folders = path.split(separator: "/").dropLast().map(String.init)
        if folders.contains(where: { generatedFolders.contains($0) }) { return .generated }
        if changedLines > largeLimit { return .large(lines: changedLines) }
        return nil
    }

    static func reason(for file: ReviewDiff.File) -> DiffCollapse? {
        file.binary ? nil : reason(path: file.path, changedLines: file.changedLines)
    }

    /// "Lockfile", "Generated", "Large: 4,312 lines".
    func title(locale: Locale = .current) -> String {
        switch self {
        case .lockfile: return "Lockfile"
        case .generated: return "Generated"
        case .large(let lines):
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = locale
            return "Large: \(formatter.string(from: NSNumber(value: lines)) ?? String(lines)) lines"
        }
    }
}

/// A changed file's mark, the same in the Git panel, the Diff plane, the
/// review and a pull request: one letter and a tone the view colours with
/// the theme's success, warning and danger.
enum ChangeMark: Equatable {
    case added, modified, deleted, renamed, untracked, conflicted

    enum Tone: Equatable { case success, warning, danger }

    init(_ kind: AgentGit.FileChange.Kind) {
        switch kind {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        case .untracked: self = .untracked
        case .conflicted: self = .conflicted
        }
    }

    init(_ status: ReviewDiff.File.Status) {
        switch status {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        }
    }

    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var name: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }

    var tone: Tone {
        switch self {
        case .added, .untracked: .success
        case .modified, .renamed: .warning
        case .deleted, .conflicted: .danger
        }
    }
}
