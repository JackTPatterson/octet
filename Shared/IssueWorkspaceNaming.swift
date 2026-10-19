import Foundation

/// Starting a workspace from an issue: the branch it gets, the prompt the
/// agent starts on, and the git facts that decide whether to reuse a
/// worktree. Pure text in, values out, so they test without a repository.
enum IssueWorkspace {
    /// The longest branch name made: long enough to read, short enough for a path.
    static let maxBranchLength = 60
    /// How much of an issue's description goes in the prompt.
    static let maxBodyLength = 6000

    // MARK: - Branch

    /// `issue-142-fix-login` for GitHub, `eng-12-fix-login` for Linear and Jira.
    static func branchName(key: String, title: String, tracker: IssueTracker) -> String {
        let id = slug(key.replacingOccurrences(of: "#", with: ""))
        let lead = tracker == .github ? "issue-\(id)" : id
        let words = slug(title)
        let name = words.isEmpty ? lead : "\(lead)-\(words)"
        return sanitizeRef(name.isEmpty ? "issue" : name)
    }

    /// Lowercase letters and digits joined by single dashes; accents fold away.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let pieces = folded.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(pieces).split(separator: "-").joined(separator: "-")
    }

    /// `name` as a valid git ref, at most `maxBranchLength` long: no spaces,
    /// control characters, `..`, `@{`, or the characters git forbids; no
    /// leading or trailing dash, dot or slash, and no `.lock` ending. A cut
    /// that lands mid-word backs up to the dash before it.
    static func sanitizeRef(_ name: String) -> String {
        let forbidden = Set(" ~^:?*[\\\u{7f}\"<>|")
        var text = String(name.map { $0.isASCII && !forbidden.contains($0) && ($0.asciiValue ?? 0) >= 0x20 ? $0 : "-" })
        text = text.replacingOccurrences(of: "@{", with: "-").replacingOccurrences(of: "//", with: "/")
        while text.contains("..") { text = text.replacingOccurrences(of: "..", with: ".") }
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        if text.count > maxBranchLength {
            let cut = String(text.prefix(maxBranchLength))
            let atWordEnd = text[text.index(text.startIndex, offsetBy: maxBranchLength)] == "-"
            text = atWordEnd ? cut : (cut.lastIndex(of: "-").map { String(cut[..<$0]) } ?? cut)
        }
        let edges = CharacterSet(charactersIn: "-./")
        text = text.trimmingCharacters(in: edges)
        while text.hasSuffix(".lock") { text = String(text.dropLast(5)).trimmingCharacters(in: edges) }
        return text
    }

    /// `name`, or `name-2`, `name-3`… when it's taken.
    static func uniqueBranch(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var number = 2
        while existing.contains("\(name)-\(number)") { number += 1 }
        return "\(name)-\(number)"
    }

    // MARK: - Worktrees

    /// Where `branch` is checked out, from `git worktree list --porcelain`.
    static func worktreePath(forBranch branch: String, porcelain: String) -> String? {
        var path: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return path
            }
        }
        return nil
    }

    // MARK: - Prompt

    /// What the agent starts on: the issue's key and title, where it lives,
    /// its labels and description (cut at `maxBodyLength`), and the ask.
    static func prompt(key: String, title: String, url: URL?, labels: [String], body: String) -> String {
        var lines = ["Work on \(key): \(title)"]
        if let url { lines.append(url.absoluteString) }
        if !labels.isEmpty { lines.append("Labels: " + labels.joined(separator: ", ")) }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let cut = text.count > maxBodyLength
            lines += ["", String(text.prefix(maxBodyLength)) + (cut ? "\n[description truncated]" : "")]
        }
        lines += ["", "Create a branch-appropriate fix; the worktree and branch are already set up."]
        return lines.joined(separator: "\n")
    }

    static func prompt(for issue: TrackerIssue) -> String {
        prompt(key: issue.key, title: issue.title, url: issue.url, labels: issue.labels.map(\.name), body: issue.body)
    }

    // MARK: - Agent

    /// The agent to start: `preferred` if it's installed, else Claude Code,
    /// else Codex. Only agents that take their prompt as an argument qualify.
    static func agent(preferred: String?, among agents: [DiscoveredAgent]) -> DiscoveredAgent? {
        let usable = agents.filter { $0.executablePath != nil && BestOfN.supported.contains($0.id) }
        if let preferred { return usable.first { $0.id == preferred } }
        return BestOfN.supported.lazy.compactMap { id in usable.first { $0.id == id } }.first
    }
}
