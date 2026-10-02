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
