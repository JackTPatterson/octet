import Foundation

/// Keeps a workspace's name on the work happening in it, the way
/// `TabAutoName` does for tabs: the task its agents report, else what its
/// conversation is about, else the branch it's on. A name has to hold still
/// before a rename, and a name you typed is never overwritten.
enum WorkspaceAutoName {
    static let maxLength = 28
    /// Longer than a tab's: a workspace names a whole piece of work, so it
    /// shouldn't chase every step of it.
    static let settleAfter: TimeInterval = 6

    /// What a workspace is doing, most telling first.
    struct Signals: Equatable {
        /// Task titles from the workspace's terminal agents, the ones that
        /// need you or are working first.
        var agentTitles: [String] = []
        /// The conversation shown in the workspace, else its latest.
        var chatTitle: String?
        var branch: String?
    }

    /// The name the work suggests, or nil when nothing says enough.
    static func name(for signals: Signals) -> String? {
        if let title = signals.agentTitles.lazy.compactMap(topic).first { return title }
        if let chat = signals.chatTitle.flatMap(topic) { return chat }
        return signals.branch.flatMap(branchName)
    }

    /// Whether `label` is one Octet may replace: blank, the session
    /// server's number, the folder's own name, or one it set itself.
    static func isAutomatic(_ label: String, folder: String?, previous: String?) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || Int(trimmed) != nil || trimmed == previous { return true }
        guard let folder else { return false }
        return trimmed.caseInsensitiveCompare((folder as NSString).lastPathComponent) == .orderedSame
    }

    // MARK: - Condensing

    /// Openers that say nothing about the task.
    private static let fillers = [
        "hey", "hi", "hello", "ok", "okay", "so", "now", "next", "also", "then", "and", "alright",
        "please", "pls", "can you", "could you", "would you", "will you", "can we", "could we",
        "i want you to", "i'd like you to", "i would like you to", "i need you to", "i want to",
        "i need to", "we need to", "help me", "go ahead and", "let's", "lets", "let us",
        "try to", "make sure to", "quickly",
    ]

    /// A title or prompt as a short name for the work: filler off the
    /// front, the first clause, the first letter capitalised, cut at a word.
    static func topic(_ text: String) -> String? {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands and pasted paths aren't topics.
        guard !line.isEmpty, !line.hasPrefix("/"), !line.hasPrefix("~") else { return nil }
        var changed = true
        while changed {
            changed = false
            let lower = line.lowercased()
            for filler in fillers where lower.hasPrefix(filler) {
                let rest = line.dropFirst(filler.count)
                // Whole words only: "now" isn't the start of "nowcast".
                guard rest.isEmpty || rest.first.map({ !$0.isLetter }) == true else { continue }
                line = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-—"))
                changed = true
                break
            }
        }
        // The first clause: a sentence end, or a comma well into it.
        if let stop = line.firstIndex(where: { ".?!;\n".contains($0) }) { line = String(line[..<stop]) }
        if let comma = line.firstIndex(of: ","), line.distance(from: line.startIndex, to: comma) >= 12 {
            line = String(line[..<comma])
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard line.count >= 3,
              !TabAutoName.uninformative.contains(line.lowercased()) else { return nil }
        let capitalised = line.prefix(1).uppercased() + line.dropFirst()
        return TabAutoName.truncate(capitalised, limit: maxLength)
    }

    /// Branches that name no piece of work.
    private static let trunkBranches: Set<String> = ["main", "master", "develop", "dev", "trunk", "head", "staging", "production"]

    /// `feat/login-redesign` → "Login redesign"; a trunk branch → nil.
    static func branchName(_ branch: String) -> String? {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        guard !trunkBranches.contains(last.lowercased()) else { return nil }
        // A leading ticket number stays: "ENG-142 retry backoff".
        let words = last.replacingOccurrences(of: "_", with: " ")
            .split(separator: "-", omittingEmptySubsequences: true)
        var parts: [String] = []
        var index = 0
        if words.count >= 2, words[0].allSatisfy(\.isLetter), words[0].count <= 5,
           words[1].allSatisfy(\.isNumber), words[0] == words[0].uppercased() {
            parts.append("\(words[0])-\(words[1])")
            index = 2
        }
        parts += words[index...].map(String.init)
        let text = parts.joined(separator: " ")
        guard text.count >= 3 else { return nil }
        return TabAutoName.truncate(text.prefix(1).uppercased() + text.dropFirst(), limit: maxLength)
    }

    // MARK: - Settling

    /// One workspace's proposed name, and since when.
    struct Candidate: Equatable {
        let label: String
        var since: Date
    }

    /// A workspace as naming sees it.
    struct Subject {
        let workspaceId: String
        let label: String
        let folder: String?
        let signals: Signals
    }

    /// The workspaces to rename. `manual` holds ones the user named;
    /// `named` what Octet last named each, so a name it set may change
    /// again; `pending` carries candidates between rounds so a name has
    /// to hold for `settleAfter`.
    static func renames(
        _ subjects: [Subject],
        manual: Set<String>,
        named: [String: String],
        pending: inout [String: Candidate],
        now: Date = Date()
    ) -> [(workspaceId: String, label: String)] {
        var renames: [(String, String)] = []
        var next: [String: Candidate] = [:]
        for subject in subjects where !manual.contains(subject.workspaceId) {
            guard isAutomatic(subject.label, folder: subject.folder, previous: named[subject.workspaceId]),
                  let label = name(for: subject.signals), label != subject.label else { continue }
            let candidate = pending[subject.workspaceId].flatMap { $0.label == label ? $0 : nil }
                ?? Candidate(label: label, since: now)
            if now.timeIntervalSince(candidate.since) >= settleAfter {
                renames.append((subject.workspaceId, label))
            } else {
                next[subject.workspaceId] = candidate
            }
        }
        pending = next
        return renames
    }
}
