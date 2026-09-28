import Foundation

/// What the git panel shows for one checkout an agent works in: its branch
/// and where it stands against the default branch, the files changed, the
/// commits and checkpoints made on the way, and any merge or rebase under
/// way. Read in one pass off the main thread.
enum AgentGit {
    struct FileChange: Equatable, Identifiable {
        enum Kind: String { case modified, added, deleted, renamed, untracked, conflicted }

        let path: String
        let kind: Kind
        /// Something of it is in the index.
        let staged: Bool
        /// Lines, against HEAD; nil for binary files and untracked ones.
        var added: Int?
        var removed: Int?

        var id: String { path }
    }

    struct Branch: Equatable {
        /// Nil when HEAD is detached.
        var name: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
    }

    struct Commit: Equatable, Identifiable {
        let sha: String
        let subject: String
        let author: String
        let date: Date

        var id: String { sha }
        var shortSha: String { String(sha.prefix(7)) }
    }

    struct Checkout: Equatable, Identifiable {
        let top: String
        var branch = Branch()
        /// The branch this one is measured against: `origin/main`, `main`, …
        var base: String?
        /// Commits this branch has that the base doesn't, and the reverse.
        var aheadOfBase = 0
        var behindBase = 0
        /// On the base branch itself, where "this branch's commits" means
        /// the latest ones.
        var onBase = false
        var files: [FileChange] = []
        var commits: [Commit] = []
        var checkpoints: [Checkpoint] = []
        var operation = GitOperation()
        var isLinkedWorktree = false

        var id: String { top }
        var conflicted: [FileChange] { files.filter { $0.kind == .conflicted } }
        var added: Int { files.compactMap(\.added).reduce(0, +) }
        var removed: Int { files.compactMap(\.removed).reduce(0, +) }
    }

    struct Worktree: Equatable, Identifiable {
        let path: String
        let branch: String?
        let isMain: Bool
        var merged = false
        var dirty = false
        var aheadOfBase = 0
        var behindBase = 0

        var id: String { path }
        var removable: Bool { !isMain && merged && !dirty }
    }

    // MARK: - Parsing

    /// `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ text: String) -> (Branch, [FileChange]) {
        var branch = Branch()
        var files: [FileChange] = []
        var entries = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("# ") {
                let parts = entry.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.head": branch.name = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": branch.upstream = parts[2]
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    branch.ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    branch.behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
                continue
            }
            guard let marker = entry.first else { continue }
            switch marker {
            case "?":
                files.append(FileChange(path: String(entry.dropFirst(2)), kind: .untracked, staged: false))
            case "1", "2":
                // 1 XY sub mH mI mW hH hI path; 2 adds a score, then the
                // original path follows as its own entry.
                let fields = entry.split(separator: " ", maxSplits: marker == "1" ? 8 : 9, omittingEmptySubsequences: false)
                guard fields.count >= (marker == "1" ? 9 : 10), let xy = fields.dropFirst().first, xy.count == 2 else { continue }
                if marker == "2" { _ = entries.popFirst() }
                let index = xy.first!, worktree = xy.last!
                let kind: FileChange.Kind
                if marker == "2" { kind = .renamed }
                else if index == "A" { kind = .added }
                else if index == "D" || worktree == "D" { kind = .deleted }
                else { kind = .modified }
                files.append(FileChange(path: String(fields.last!), kind: kind, staged: index != "."))
            case "u":
                let fields = entry.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count >= 11 else { continue }
                files.append(FileChange(path: String(fields.last!), kind: .conflicted, staged: false))
            default:
                continue
            }
        }
        return (branch, files)
    }

    /// `git diff --numstat -z`: lines per path; binary files report `-`.
    static func parseNumstat(_ text: String) -> [String: (added: Int?, removed: Int?)] {
        var result: [String: (added: Int?, removed: Int?)] = [:]
        for entry in text.split(separator: "\0") {
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            result[String(fields[2])] = (Int(fields[0]), Int(fields[1]))
        }
        return result
    }

    static let logFormat = "%H%x1f%s%x1f%an%x1f%ct%x1e"

    /// `git log --format=<logFormat>`.
    static func parseLog(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, let seconds = TimeInterval(fields[3]) else { return nil }
            return Commit(sha: fields[0], subject: fields[1], author: fields[2], date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// `git rev-list --left-right --count A...B`: (only in A, only in B).
    static func parseLeftRight(_ text: String) -> (left: Int, right: Int)? {
        let counts = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return (counts[0], counts[1])
    }

    // MARK: - Reading

    /// Everything about the checkout at `top`. Slow-ish (a handful of git
    /// calls); run it off the main thread.
    static func read(top: String, git: Git = Git(), commitLimit: Int = 30) -> Checkout? {
        guard let status = try? git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: top)
        else { return nil }
        var checkout = Checkout(top: top)
        (checkout.branch, checkout.files) = parseStatus(status)

        let hasHead = (try? git.run(["rev-parse", "-q", "--verify", "HEAD"], in: top)).map { !$0.isEmpty } ?? false
        if hasHead, let numstat = try? git.run(["-c", "core.quotepath=off", "diff", "--numstat", "--no-renames",
                                                "--no-ext-diff", "--no-textconv", "-z", "HEAD"], in: top) {
            let counts = parseNumstat(numstat)
            for index in checkout.files.indices {
                guard let count = counts[checkout.files[index].path] else { continue }
                checkout.files[index].added = count.added
                checkout.files[index].removed = count.removed
            }
        }

        if let location = GitBranch.location(for: top) {
            checkout.isLinkedWorktree = location.isLinkedWorktree
            checkout.operation = GitOperation.read(gitDir: location.gitDir)
            checkout.operation.conflicts = checkout.conflicted.count
        }

        checkout.base = ReviewDiff.defaultBranch(top: top, git: git)
        if hasHead, let base = checkout.base {
            let baseName = base.replacingOccurrences(of: "origin/", with: "")
            checkout.onBase = checkout.branch.name == baseName || checkout.branch.name == base
            if !checkout.onBase,
               let counts = (try? git.run(["rev-list", "--left-right", "--count", "\(base)...HEAD"], in: top)).flatMap(parseLeftRight) {
                (checkout.behindBase, checkout.aheadOfBase) = counts
            }
        }
        if hasHead {
            let range = checkout.onBase || checkout.base == nil ? ["-15"] : ["-\(commitLimit)", "\(checkout.base!)..HEAD"]
            if let log = try? git.run(["log", "--no-color", "--format=\(logFormat)"] + range, in: top) {
                checkout.commits = parseLog(log)
            }
        }
        checkout.checkpoints = Array(Checkpoints.list(in: top, git: git).prefix(20))
        return checkout
    }

    /// Every worktree of the repository `top` is in, with how far each has
    /// gone from the default branch.
    static func worktrees(top: String, git: Git = Git()) -> [Worktree] {
        let base = ReviewDiff.defaultBranch(top: top, git: git)
        return WorktreeCleanup.list(in: top, git: git).map { listed in
            var worktree = Worktree(path: listed.path, branch: listed.branch, isMain: listed.isMain,
                                    merged: listed.merged, dirty: listed.dirty)
            if let base, let branch = listed.branch, !listed.isMain,
               let counts = (try? git.run(["rev-list", "--left-right", "--count", "\(base)...\(branch)"], in: top))
                .flatMap(parseLeftRight) {
                (worktree.behindBase, worktree.aheadOfBase) = counts
            }
            return worktree
        }
    }
}

/// What the panel asks an agent to do. Each is a prompt: the agent does the
/// git work its own way and can explain or ask, rather than Octet running
/// commands behind it.
enum AgentGitHandoff: String, CaseIterable, Identifiable {
    case commit, resolveConflicts, rebase, describePR, openPR, mergeWorktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commit: "Commit"
        case .resolveConflicts: "Resolve Conflicts"
        case .rebase: "Update from Base"
        case .describePR: "Describe PR"
        case .openPR: "Open PR"
        case .mergeWorktree: "Merge"
        }
    }

    /// The handoffs that make sense for a checkout as it stands.
    static func offered(for checkout: AgentGit.Checkout) -> [AgentGitHandoff] {
        if !checkout.conflicted.isEmpty || checkout.operation.kind != nil { return [.resolveConflicts] }
        var offered: [AgentGitHandoff] = []
        if !checkout.files.isEmpty { offered.append(.commit) }
        if !checkout.onBase, checkout.base != nil {
            if checkout.behindBase > 0 { offered.append(.rebase) }
            if checkout.aheadOfBase > 0 { offered += [.describePR, .openPR] }
        }
        return offered
    }

    /// `only` narrows a commit to those files.
    func prompt(checkout: AgentGit.Checkout, only paths: [String]? = nil) -> String {
        let branch = checkout.branch.name ?? "the current commit"
        let base = checkout.base ?? "the default branch"
        switch self {
        case .commit where paths?.isEmpty == false:
            return "Commit only these files in \(checkout.top): \(paths!.joined(separator: ", ")). "
                + "Leave every other change uncommitted. Write a clear message in this repository's style. Don't push."
        case .commit:
            return "Commit the uncommitted changes in \(checkout.top). Split unrelated changes into separate commits, "
                + "each with a clear message in this repository's style. Don't push."
        case .resolveConflicts:
            let files = checkout.conflicted.map(\.path)
            let what = checkout.operation.kind.map { " and continue the \($0.rawValue.lowercased())" } ?? ""
            return "Resolve the git conflicts in \(checkout.top)"
                + (files.isEmpty ? "" : " (\(files.joined(separator: ", ")))")
                + ", keeping what both sides meant\(what). Run the tests afterwards and tell me anything you weren't sure about."
        case .rebase:
            return "\(branch) is \(checkout.behindBase) commit\(checkout.behindBase == 1 ? "" : "s") behind \(base). "
                + "Bring it up to date with \(base) the way this repository prefers (rebase or merge), resolve any conflicts, "
                + "run the tests, and tell me what changed."
        case .describePR:
            return "Write a pull request title and description for \(branch) against \(base): what changed, why, "
                + "and how it was tested. Show it to me as Markdown; don't open the PR."
        case .openPR:
            return "Push \(branch) and open a pull request against \(base) with a clear title and description "
                + "(what changed, why, how it was tested). Follow the repository's PR template if it has one."
        case .mergeWorktree:
            return "Merge \(branch) into \(base) the way this repository prefers, resolve any conflicts, "
                + "and run the tests. Don't push unless I ask."
        }
    }

    /// The prompt to merge a worktree's branch, sent to an agent elsewhere.
    static func mergePrompt(worktree: AgentGit.Worktree, base: String?) -> String {
        "Merge the branch \(worktree.branch ?? "checked out") (worktree at \(worktree.path)) into \(base ?? "the default branch") "
            + "the way this repository prefers, resolve any conflicts, and run the tests. Don't push unless I ask."
    }
}
