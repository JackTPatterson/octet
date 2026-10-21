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
        /// One agent turn: from the checkpoint it started at to the next
        /// one, or to now for the latest turn. After T3 Code's turn diffs.
        case turn(from: String, to: String?, name: String)
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

    // MARK: - Staging

    /// One hunk as a patch `git apply` takes, against the file's old side.
    static func patch(for file: File, hunk: Hunk) -> String {
        var text = "diff --git a/\(file.path) b/\(file.path)\n"
        switch file.status {
        case .added: text += "new file mode 100644\n--- /dev/null\n+++ b/\(file.path)\n"
        case .deleted: text += "deleted file mode 100644\n--- a/\(file.path)\n+++ /dev/null\n"
        case .modified: text += "--- a/\(file.path)\n+++ b/\(file.path)\n"
        }
        text += hunk.header + "\n"
        for line in hunk.lines {
            switch line.kind {
            case .context: text += " "
            case .added: text += "+"
            case .removed: text += "-"
            }
            text += line.text + "\n"
        }
        return text
    }

    /// Stages one hunk of a diff against HEAD.
    static func stage(_ patch: String, in directory: String, git: Git = Git()) throws {
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("octet-hunk-\(UUID().uuidString).patch")
        try patch.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try git.run(["apply", "--cached", "--recount", "--whitespace=nowarn", file.path], in: top)
    }

    static func stage(path: String, in directory: String, git: Git = Git()) throws {
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        try git.run(["add", "-A", "--", path], in: top)
    }

    static func unstage(path: String, in directory: String, git: Git = Git()) throws {
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        try git.run(["reset", "-q", "--", path], in: top)
    }

    /// Paths with anything staged, relative to the top of the repository.
    static func stagedPaths(in directory: String, git: Git = Git()) -> Set<String> {
        guard let top = git.topLevel(directory),
              let output = try? git.run(["-c", "core.quotepath=off", "diff", "--cached", "--name-only", "--no-renames"], in: top)
        else { return [] }
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// Commits what's staged, leaving the rest as it is.
    static func commitStaged(message: String, in directory: String, git: Git = Git()) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw Checkpoints.GitError(description: "A commit needs a message") }
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        try git.run(["commit", "-q", "-m", message], in: top)
        return try git.run(["rev-parse", "--short", "HEAD"], in: top)
    }

    // MARK: - Reading a working tree

    /// The diff for the tree `directory` is in, or nil outside a repository
    /// or when git fails.
    static func read(in directory: String, base: Base, ignoreWhitespace: Bool = false, git: Git = Git()) -> ReviewDiff? {
        try? readResult(in: directory, base: base, ignoreWhitespace: ignoreWhitespace, git: git).get()
    }

    /// Why a diff couldn't be read: outside a repository, which is a fact
    /// about the folder, or git failing, which a retry may get past.
    enum ReadFailure: Error, Equatable {
        case notARepository
        case git(String)
    }

    /// The diff for the tree `directory` is in, or why there isn't one, so
    /// a failing git shows as an error with Retry rather than "No changes".
    static func readResult(in directory: String, base: Base, ignoreWhitespace: Bool = false,
                           git: Git = Git()) -> Result<ReviewDiff, ReadFailure> {
        guard let top = git.topLevel(directory) else { return .failure(.notARepository) }
        func run(_ arguments: [String]) throws -> String {
            do { return try git.run(arguments, in: top) } catch { throw ReadFailure.git(String(describing: error)) }
        }
        do {
            let tree = try Checkpoints.snapshotTree(top: top, git: git)
            if case .turn(let from, let to?, let name) = base {
                let text = try run(diffArguments(from, to, ignoreWhitespace: ignoreWhitespace))
                return .success(ReviewDiff(files: parse(text), baseCommit: from, baseName: name))
            }
            guard let (commit, name) = resolveBase(base, top: top, git: git) else {
                // No commits yet: everything is new.
                let empty = (try? git.run(["hash-object", "-t", "tree", "/dev/null"], in: top)) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
                let text = try run(diffArguments(empty, tree, ignoreWhitespace: ignoreWhitespace))
                return .success(ReviewDiff(files: parse(text), baseCommit: empty, baseName: "nothing"))
            }
            let text = try run(diffArguments(commit, tree, ignoreWhitespace: ignoreWhitespace))
            return .success(ReviewDiff(files: parse(text), baseCommit: commit, baseName: name))
        } catch let failure as ReadFailure {
            return .failure(failure)
        } catch {
            return .failure(.git(String(describing: error)))
        }
    }

    /// `ignoreWhitespace` leaves out lines that changed only in spacing, as
    /// T3 Code's diff does; the review that stages hunks never asks for it,
    /// since such a hunk wouldn't apply.
    static func diffArguments(_ from: String, _ to: String, ignoreWhitespace: Bool = false) -> [String] {
        // Unicode paths as they are, not octal-escaped.
        ["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3"]
            + (ignoreWhitespace ? ["-w"] : []) + [from, to]
    }

    /// HEAD, or where HEAD's branch left the default branch.
    static func resolveBase(_ base: Base, top: String, git: Git) -> (commit: String, name: String)? {
        if case .since(let commit, let name) = base { return (commit, name) }
        if case .turn(let from, _, let name) = base { return (from, name) }
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
    /// The line the note is on, or the first of the lines it covers.
    let line: ReviewDiff.Line
    /// The last line of a note on several, shift-clicked; nil for one line.
    var through: ReviewDiff.Line?
    var text: String

    init(path: String, line: ReviewDiff.Line, through: ReviewDiff.Line? = nil, text: String, id: UUID = UUID()) {
        self.id = id
        self.path = path
        self.line = line
        self.through = through == line ? nil : through
        self.text = text
    }

    /// "12" or "12-15", as the prompt and the tray say where a note is.
    var location: String {
        guard let through, through.number != line.number else { return "\(line.number)" }
        return "\(min(line.number, through.number))-\(max(line.number, through.number))"
    }

    /// Whether the code the note is about has gone from `files`: the agent
    /// rewrote it since, so the note may no longer apply. A line still there
    /// with the same text counts as present wherever it moved to.
    func isOutdated(in files: [ReviewDiff.File]) -> Bool {
        guard let file = files.first(where: { $0.path == path }) else { return true }
        // A file too big to draw has no lines to look for; say nothing.
        if file.tooLarge { return false }
        let lines = file.hunks.flatMap(\.lines)
        func present(_ wanted: ReviewDiff.Line) -> Bool {
            lines.contains { $0.kind == wanted.kind && $0.text == wanted.text }
        }
        return !present(line) || !(through.map(present) ?? true)
    }

    /// The user's own message with the notes after it, for notes that
    /// ride along with the next prompt rather than going on their own.
    static func attaching(_ comments: [ReviewComment], to message: String) -> String {
        let notes = prompt(comments)
        guard !notes.isEmpty else { return message }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? notes : trimmed + "\n\n" + notes
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
            text += "\n- \(note.path):\(note.location)\(side)"
            if !code.isEmpty { text += " `\(code.count > 120 ? String(code.prefix(119)) + "…" : code)`" }
            text += "\n  " + note.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  ")
        }
        return text
    }
}

extension ReviewDiff {
    /// Each agent turn as a comparison, newest first: a turn runs from its
    /// checkpoint to the next one taken, the latest to now. `checkpoints`
    /// come newest first, as `Checkpoints.list` gives them.
    static func turns(_ checkpoints: [Checkpoint]) -> [(base: Base, title: String, date: Date)] {
        checkpoints.enumerated().map { index, point in
            let number = checkpoints.count - index
            let next = index > 0 ? checkpoints[index - 1].commit : nil
            return (.turn(from: point.commit, to: next, name: "turn \(number)"),
                    index == 0 ? "Latest Turn" : "Turn \(number)", point.date)
        }
    }
}
