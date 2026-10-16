import Foundation

/// The sidebar's search: which workspaces a query finds, from what each
/// one shows or is about, its name, tabs, branch, folders and agents.
enum SidebarSearch {
    /// The words of a query, each to be found somewhere in a workspace.
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether every word of the query is in at least one of `fields`,
    /// ignoring case and accents.
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = terms(query).map(fold)
        guard !terms.isEmpty else { return true }
        let haystack = fields.map(fold)
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// What a workspace can be found by: its name, its group, its branch and
    /// worktree, each tab's name, each pane's folder and title, and the
    /// agents running in it. `extra` adds what the app knows beyond the
    /// session server, like Octet's own conversations' titles.
    static func fields(of workspace: EngineWorkspace, in snapshot: EngineSnapshot, group: String?,
                       branch: String?, extra: [String] = []) -> [String] {
        var fields = [workspace.label]
        if let group { fields.append(group) }
        if let branch { fields.append(branch) }
        if let worktree = workspace.worktree {
            fields += [worktree.branch, worktree.path].compactMap { $0 }
        }
        let id = workspace.workspaceId
        fields += snapshot.tabs.filter { $0.workspaceId == id }.map(\.label)
        for pane in snapshot.panes where pane.workspaceId == id {
            fields += [pane.cwd, pane.foregroundCwd, pane.terminalTitle].compactMap { $0 }
        }
        for agent in snapshot.agents where agent.workspaceId == id {
            fields += [agent.agent, agent.name, agent.displayAgent].compactMap { $0 }
        }
        return (fields + extra).filter { !$0.isEmpty }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - What was said, and how a project is drawn

extension SidebarSearch {
    /// Where a search found its words in a conversation: who said it, and
    /// the words around the match, cut to fit one line.
    struct Snippet: Equatable {
        let fromYou: Bool
        let before: String
        let match: String
        let after: String
    }

    /// The newest message holding the query, as a snippet; nil for a query
    /// under two characters or one no message holds.
    static func snippet(_ query: String, in messages: [(fromYou: Bool, text: String)], radius: Int = 32) -> Snippet? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return nil }
        for message in messages.reversed() {
            let flat = message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard let range = flat.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
            let before = (start > flat.startIndex ? "…" : "") + flat[start..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = flat[range.upperBound..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
            let gapBefore = flat[start..<range.lowerBound].last == " " ? " " : ""
            let gapAfter = flat[range.upperBound..<end].first == " " ? " " : ""
            return Snippet(fromYou: message.fromYou, before: before + gapBefore, match: String(flat[range]), after: gapAfter + after)
        }
        return nil
    }

    /// A project's initials for its badge: the first letters of its first
    /// two words ("octet-plugins" → "OP"), else its first two letters.
    static func monogram(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        return String((words.first ?? Substring(name)).prefix(2)).uppercased()
    }

    /// A colour for a project that stays the same across launches: an index
    /// into a palette of `count`.
    static func colorIndex(_ name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return sum % count
    }
}
