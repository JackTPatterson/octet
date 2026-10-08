import Foundation

/// What an idle workspace still holds: work that isn't saved anywhere else
/// (uncommitted changes, commits on no remote), servers still listening,
/// and whether it is a worktree whose branch has been merged. Read for the
/// Idle dock's rows, and before closing or sleeping workspaces, so nothing
/// is thrown away without being said.
struct IdleWork: Equatable, Codable {
    var branch: String?
    /// Changed, staged and untracked files.
    var uncommitted = 0
    /// Commits on this branch that no remote has.
    var unpushed = 0
    var ports: [Int] = []
    /// A worktree whose branch is merged into the default branch.
    var mergedWorktree = false

    /// Nothing that closing would lose or leave running.
    var isClean: Bool { uncommitted == 0 && unpushed == 0 && ports.isEmpty }

    /// "3 uncommitted · 2 unpushed · :3000", or nil when clean.
    var summary: String? {
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) uncommitted") }
        if unpushed > 0 { parts.append("\(unpushed) unpushed") }
        parts += ports.prefix(2).map { ":\($0)" }
        if ports.count > 2 { parts.append("+\(ports.count - 2) ports") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What closing would lose, for a confirmation: "3 uncommitted files,
    /// 2 unpushed commits and a server on :3000".
    var risks: String? {
        var parts: [String] = []
        if uncommitted > 0 { parts.append(Recap.count(uncommitted, "uncommitted file")) }
        if unpushed > 0 { parts.append(Recap.count(unpushed, "unpushed commit")) }
        if ports.count == 1 { parts.append("a server on :\(ports[0])") }
        if ports.count > 1 { parts.append("servers on " + ports.map { ":\($0)" }.joined(separator: ", ")) }
        guard let last = parts.popLast() else { return nil }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }

    /// `git status --porcelain=v2 --branch`: the branch and how many files
    /// differ from HEAD.
    static func parseStatus(_ text: String) -> (branch: String?, uncommitted: Int) {
        var branch: String?
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? nil : head
            } else if !line.hasPrefix("#") {
                count += 1
            }
        }
        return (branch, count)
    }

    /// Reads it for one folder. `git` decides the repository; a folder
    /// outside one has nothing uncommitted.
    static func read(directory: String, ports: [Int], isWorktree: Bool, git: Git = Git()) -> IdleWork {
        var work = IdleWork(ports: ports)
        guard let top = git.topLevel(directory) else { return work }
        if let status = try? git.run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: top) {
            let parsed = parseStatus(status)
            work.branch = parsed.branch
            work.uncommitted = parsed.uncommitted
        }
        // Commits no remote has; with no remote at all, nothing counts as
        // unpushed, since there's nowhere to push.
        if let remotes = try? git.run(["remote"], in: top), !remotes.isEmpty,
           let count = try? git.run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: top) {
            work.unpushed = Int(count) ?? 0
        }
        if isWorktree, let branch = work.branch,
           let base = ReviewDiff.defaultBranch(top: top, git: git), base != branch,
           let merged = try? git.run(["branch", "--format=%(refname:short)", "--merged", base], in: top) {
            work.mergedWorktree = merged.split(separator: "\n").map(String.init).contains(branch)
        }
        return work
    }
}
