import Foundation

/// The branches the picker lists, and the rules for switching between them.
/// Pure text in, values out, so they test without a repository.
enum GitBranches {
    struct Entry: Equatable, Identifiable {
        /// `main`, or `origin/feature` for a branch that exists only on a remote.
        let name: String
        var isCurrent = false
        var isRemote = false
        var upstream: String?
        var ahead = 0
        var behind = 0
        /// The last commit's time, for ordering.
        var date: Date?
        /// Where another worktree has it checked out.
        var worktree: String?

        var id: String { (isRemote ? "remote:" : "local:") + name }
        /// A branch can't be checked out twice.
        var checkedOutElsewhere: Bool { worktree != nil && !isCurrent }
    }

    /// `git for-each-ref refs/heads` with `listFormat`.
    static let listFormat = "%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(committerdate:unix)%09%(worktreepath)"
    /// `git for-each-ref refs/remotes` with `remoteFormat`; the full name, as
    /// the short one calls `origin/HEAD` just `origin`.
    static let remoteFormat = "%(refname)%09%(committerdate:unix)"

    /// "ahead 2, behind 1", "ahead 3", "gone" or "".
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int) {
        var ahead = 0, behind = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }

    static func parseLocal(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[1].isEmpty else { return nil }
            let track = parseTrack(fields[3])
            return Entry(name: fields[1], isCurrent: fields[0] == "*",
                         upstream: fields[2].isEmpty ? nil : fields[2],
                         ahead: track.ahead, behind: track.behind,
                         date: TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) },
                         worktree: fields.count > 5 && !fields[5].isEmpty ? fields[5] : nil)
        }
    }

    /// Remote branches no local branch tracks by the same name, `HEAD` aside.
    static func parseRemote(_ text: String, local: [Entry]) -> [Entry] {
        let prefix = "refs/remotes/"
        let have = Set(local.map(\.name))
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, fields[0].hasPrefix(prefix) else { return nil }
            let name = String(fields[0].dropFirst(prefix.count))
            guard let slash = name.firstIndex(of: "/"), name[name.index(after: slash)...] != "HEAD" else { return nil }
            guard !have.contains(String(name[name.index(after: slash)...])) else { return nil }
            return Entry(name: name, isRemote: true, date: TimeInterval(fields[1]).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// The current branch first, then local branches and remote-only ones,
    /// each most recent first.
    static func sorted(_ entries: [Entry]) -> [Entry] {
        func rank(_ entry: Entry) -> Int { entry.isCurrent ? 0 : entry.isRemote ? 2 : 1 }
        return entries.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let (x, y) = (a.date ?? .distantPast, b.date ?? .distantPast)
            return x != y ? x > y : a.name < b.name
        }
    }

    /// What the search box keeps: names containing every word typed.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in words.allSatisfy { entry.name.lowercased().contains($0) } }
    }

    // MARK: - Rules

    enum Switch: Equatable {
        case proceed
        /// Tracked changes would travel with, or be lost to, the switch.
        case needsStash(files: Int)
    }

    /// Switching never discards anything: with changes in the tree the person
    /// stashes them first or stays. Untracked files don't block a switch.
    static func switchPlan(porcelain: String) -> Switch {
        let tracked = porcelain.split(separator: "\n").filter { !$0.hasPrefix("??") }.count
        return tracked == 0 ? .proceed : .needsStash(files: tracked)
    }

    /// Whether `name` could be a new branch. Git has the last word.
    static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix(".lock"), !name.hasSuffix("."), !name.contains(".."), !name.contains("//"),
              !name.contains("@{"), name != "@" else { return false }
        return !name.contains { $0.isWhitespace || $0.isNewline || "~^:?*[\\".contains($0) || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }
    }

    /// `<folder>/<repository>/<branch>`, the branch's slashes made dashes.
    static func worktreePath(folder: String, repository: String, branch: String) -> String {
        let root = (folder as NSString).expandingTildeInPath
        let leaf = branch.replacingOccurrences(of: "/", with: "-")
        return ((root as NSString).appendingPathComponent(repository) as NSString).appendingPathComponent(leaf)
    }

    /// The local name a remote branch becomes when checked out.
    static func localName(ofRemote name: String) -> String {
        name.firstIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name
    }

    /// "3 hours ago", for the row's trailing note.
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 60): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 30)))mo"
        }
    }
}
