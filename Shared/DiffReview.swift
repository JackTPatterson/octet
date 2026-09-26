import Foundation

/// What changed in a working tree, file by file, for reviewing an agent's
/// work and sending it comments. The working tree is read as a snapshot
/// (the way checkpoints are taken), so new files show without being added.
struct ReviewDiff: Equatable {
    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
        /// Position in its file's diff, for identity.
        let index: Int

        var id: Int { index }
        /// The line a comment on it refers to: the new file's, or the old
        /// one's for a removed line.
        var number: Int { newNumber ?? oldNumber ?? 0 }
    }

    struct Hunk: Equatable {
        let header: String
        let lines: [Line]

        /// One row of a side-by-side view: the old file's line on the left,
        /// the new one's on the right.
        struct Pair: Equatable, Identifiable {
            let left: Line?
            let right: Line?
            var id: Int { (left ?? right)?.index ?? 0 }
        }

        /// The lines side by side: context on both sides, and each run of
        /// removed lines against the added lines that replace it, row for
        /// row, with blanks where one side runs longer.
        var pairs: [Pair] {
            var result: [Pair] = []
            var removed: [Line] = []
            var added: [Line] = []
            func flush() {
                for row in 0..<max(removed.count, added.count) {
                    result.append(Pair(left: row < removed.count ? removed[row] : nil,
                                       right: row < added.count ? added[row] : nil))
                }
                removed = []
                added = []
            }
            for line in lines {
                switch line.kind {
                case .removed:
                    if !added.isEmpty { flush() }
                    removed.append(line)
                case .added:
                    added.append(line)
                case .context:
                    flush()
                    result.append(Pair(left: line, right: line))
                }
            }
            flush()
            return result
        }
    }

    struct File: Equatable, Identifiable {
        enum Status: Equatable { case added, deleted, modified }
        var path: String
        var status: Status
        var hunks: [Hunk] = []
        var added = 0
        var removed = 0
        var binary = false
        /// Too big to draw; counted but not shown.
        var tooLarge = false

        var id: String { path }
    }

    enum Base: Hashable {
        /// What isn't committed yet: against HEAD.
        case uncommitted
        /// The whole branch: against where it left the default branch.
        case branch
        /// Against a given commit: where a best-of-N attempt started.
        case since(commit: String, name: String)
    }

    var files: [File]
    /// The commit compared against, and what it's called.
    var baseCommit: String
    var baseName: String

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// Lines a single file may have before it's summarised instead of drawn,
    /// and the most drawn across the whole diff.
    static let fileLineLimit = 3_000
    static let totalLineLimit = 20_000

    // MARK: - Parsing `git diff`

    static func parse(_ text: String, fileLimit: Int = fileLineLimit, totalLimit: Int = totalLineLimit) -> [File] {
        var files: [File] = []
        var current: File?
        var hunkHeader: String?
        var hunkLines: [Line] = []
        var oldLine = 0, newLine = 0, drawn = 0

        func closeHunk() {
            if let header = hunkHeader, current != nil, !(current!.tooLarge) {
                current!.hunks.append(Hunk(header: header, lines: hunkLines))
            }
            hunkHeader = nil
            hunkLines = []
        }
        func closeFile() {
            closeHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                current = File(path: path(fromDiffHeader: line), status: .modified)
                continue
            }
            guard current != nil else { continue }
            if hunkHeader == nil {
                if line.hasPrefix("new file mode") { current!.status = .added; continue }
                if line.hasPrefix("deleted file mode") { current!.status = .deleted; continue }
                if line.hasPrefix("Binary files ") { current!.binary = true; continue }
                if line.hasPrefix("+++ b/") { current!.path = String(line.dropFirst(6)); continue }
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("index ") { continue }
            }
            if line.hasPrefix("@@") {
                closeHunk()
                let (old, new) = hunkStarts(line)
                oldLine = old
                newLine = new
                hunkHeader = line
                continue
            }
            guard hunkHeader != nil, let marker = line.first else { continue }
            let body = String(line.dropFirst())
            let kind: Line.Kind
            switch marker {
            case "+": kind = .added; current!.added += 1
            case "-": kind = .removed; current!.removed += 1
            case " ": kind = .context
            default: continue   // "\ No newline at end of file"
            }
            if current!.added + current!.removed > fileLimit || drawn >= totalLimit { current!.tooLarge = true }
            guard !current!.tooLarge else { continue }
            let index = current!.hunks.reduce(0) { $0 + $1.lines.count } + hunkLines.count
            hunkLines.append(Line(kind: kind, oldNumber: kind == .added ? nil : oldLine,
                                  newNumber: kind == .removed ? nil : newLine, text: body, index: index))
            drawn += 1
            if kind != .added { oldLine += 1 }
            if kind != .removed { newLine += 1 }
        }
        closeFile()
        for index in files.indices where files[index].tooLarge { files[index].hunks = [] }
        return files
    }

    /// `diff --git a/x b/x` → `x` (the b side; quoted paths unquoted).
    static func path(fromDiffHeader line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        if let range = rest.range(of: " b/", options: .backwards) { return String(rest[range.upperBound...]) }
        return rest
    }

    /// `@@ -12,5 +14,7 @@` → (12, 14).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(after marker: Character) -> Int {
            guard let part = header.split(separator: " ").first(where: { $0.first == marker }) else { return 1 }
            return Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (start(after: "-"), start(after: "+"))
    }

    // MARK: - Committing

    /// Stages everything in the working tree and commits it with your own
    /// identity and hooks, as `git commit` would. Returns the new commit's
    /// short hash.
    @discardableResult
    static func commitAll(message: String, in directory: String, git: Git = Git()) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw Checkpoints.GitError(description: "A commit needs a message") }
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        try git.run(["add", "-A", "--", "."], in: top)
        try git.run(["commit", "-q", "-m", message], in: top)
        return try git.run(["rev-parse", "--short", "HEAD"], in: top)
    }

    // MARK: - Reading a working tree

    /// The diff for the tree `directory` is in, or nil outside a repository.
    static func read(in directory: String, base: Base, git: Git = Git()) -> ReviewDiff? {
        guard let top = git.topLevel(directory), let tree = try? Checkpoints.snapshotTree(top: top, git: git) else { return nil }
        guard let (commit, name) = resolveBase(base, top: top, git: git) else {
            // No commits yet: everything is new.
            let empty = (try? git.run(["hash-object", "-t", "tree", "/dev/null"], in: top)) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            let text = (try? git.run(diffArguments(empty, tree), in: top)) ?? ""
            return ReviewDiff(files: parse(text), baseCommit: empty, baseName: "nothing")
        }
        let text = (try? git.run(diffArguments(commit, tree), in: top)) ?? ""
        return ReviewDiff(files: parse(text), baseCommit: commit, baseName: name)
    }

    static func diffArguments(_ from: String, _ to: String) -> [String] {
        // Unicode paths as they are, not octal-escaped.
        ["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3", from, to]
    }

    /// HEAD, or where HEAD's branch left the default branch.
    static func resolveBase(_ base: Base, top: String, git: Git) -> (commit: String, name: String)? {
        if case .since(let commit, let name) = base { return (commit, name) }
        guard let head = try? git.run(["rev-parse", "-q", "--verify", "HEAD"], in: top), !head.isEmpty else { return nil }
        guard base == .branch, let main = defaultBranch(top: top, git: git),
              let fork = try? git.run(["merge-base", "HEAD", main], in: top), !fork.isEmpty else { return (head, "HEAD") }
        return (fork, main)
    }

    /// `origin/main` when there's a remote default, else a local main or master.
    static func defaultBranch(top: String, git: Git) -> String? {
        if let remote = try? git.run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: top), !remote.isEmpty {
            return remote
        }
        for name in ["main", "master", "trunk", "develop"] {
            if (try? git.run(["rev-parse", "-q", "--verify", "refs/heads/" + name], in: top)) != nil { return name }
        }
        return nil
    }
}

/// A reviewer's note on one line, and the prompt the notes become.
struct ReviewComment: Equatable, Identifiable {
    let id: UUID
    let path: String
    let line: ReviewDiff.Line
    var text: String

    init(path: String, line: ReviewDiff.Line, text: String, id: UUID = UUID()) {
        self.id = id
        self.path = path
        self.line = line
        self.text = text
    }

    /// One message for the agent: each note with where it is and the line
    /// it's about, in file order.
    static func prompt(_ comments: [ReviewComment]) -> String {
        let notes = comments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.path, $0.line.number) < ($1.path, $1.line.number) }
        guard !notes.isEmpty else { return "" }
        var text = "I reviewed your changes. Please address these comments:\n"
        for note in notes {
            let side = note.line.kind == .removed ? " (removed line)" : ""
            let code = note.line.text.trimmingCharacters(in: .whitespaces)
            text += "\n- \(note.path):\(note.line.number)\(side)"
            if !code.isEmpty { text += " `\(code.count > 120 ? String(code.prefix(119)) + "…" : code)`" }
            text += "\n  " + note.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  ")
        }
        return text
    }
}
