import Foundation

/// The git panel's decisions that need no view: how the changed files group,
/// which single sync action leads the header, and which sections are worth
/// showing now. Kept apart so they can be tested without a repository.

/// The changed files in the three groups the list shows.
struct GitChangeGroups: Equatable {
    enum Kind: String, CaseIterable {
        case staged, changes, untracked

        var title: String {
            switch self {
            case .staged: "Staged"
            case .changes: "Changes"
            case .untracked: "Untracked"
            }
        }
    }

    struct Group: Equatable, Identifiable {
        let kind: Kind
        let files: [AgentGit.FileChange]
        var id: Kind { kind }
    }

    let staged: [AgentGit.FileChange]
    let changes: [AgentGit.FileChange]
    let untracked: [AgentGit.FileChange]

    init(files: [AgentGit.FileChange]) {
        staged = files.filter(\.staged)
        let rest = files.filter { !$0.staged }
        untracked = rest.filter { $0.kind == .untracked }
        changes = rest.filter { $0.kind != .untracked }
    }

    var count: Int { staged.count + changes.count + untracked.count }

    /// Only the groups that have files: no "Staged" header over nothing.
    var visible: [Group] {
        Kind.allCases.compactMap { kind in
            let files = self.files(kind)
            return files.isEmpty ? nil : Group(kind: kind, files: files)
        }
    }

    func files(_ kind: Kind) -> [AgentGit.FileChange] {
        switch kind {
        case .staged: staged
        case .changes: changes
        case .untracked: untracked
        }
    }

    enum BulkAction: Equatable { case stageAll, unstageAll }

    /// The group header's bulk action. Staging everything also takes the
    /// untracked files, so Untracked offers it only when Changes isn't there
    /// to, which keeps the label true.
    func bulkAction(for kind: Kind) -> BulkAction? {
        switch kind {
        case .staged: .unstageAll
        case .changes: .stageAll
        case .untracked: changes.isEmpty ? .stageAll : nil
        }
    }
}

/// The one sync action the header leads with.
enum GitSyncAction: Equatable {
    case pull(Int)
    case push(Int)
    case publish

    var title: String {
        switch self {
        case .pull(let count): count > 0 ? "Pull \(count)" : "Pull"
        case .push(let count): count > 0 ? "Push \(count)" : "Push"
        case .publish: "Publish"
        }
    }

    var icon: String {
        switch self {
        case .pull: "arrow.down"
        case .push, .publish: "arrow.up"
        }
    }

    /// Behind wins: pulling comes before pushing. In sync with an upstream
    /// there is nothing to lead with; a branch with no upstream is published;
    /// a detached HEAD has nothing to sync.
    static func primary(for branch: AgentGit.Branch) -> GitSyncAction? {
        guard branch.name != nil else { return nil }
        guard branch.upstream != nil else { return .publish }
        if branch.behind > 0 { return .pull(branch.behind) }
        if branch.ahead > 0 { return .push(branch.ahead) }
        return nil
    }
}

/// Which parts of one checkout are worth drawing right now.
struct GitSectionPlan: Equatable {
    var showHandoff: Bool
    var showChanges: Bool
    var showHistory: Bool
    var historyCount: Int
    var showFilter: Bool

    /// `promptable`: an agent here takes prompts, so chores can be handed
    /// to it. `hasEditors`: some agent's edit tool changed one of the files.
    init(checkout: AgentGit.Checkout, promptable: Bool, hasEditors: Bool) {
        showChanges = !checkout.files.isEmpty
        showHandoff = !AgentGitHandoff.offered(for: checkout).isEmpty && promptable
        historyCount = checkout.commits.count
        showHistory = !checkout.commits.isEmpty || !checkout.checkpoints.isEmpty
        showFilter = hasEditors
    }

    /// Worktrees only matter when the repository has more than one.
    static func showWorktrees(count: Int) -> Bool { count > 1 }
}

/// Why Commit is unavailable, for its tooltip; nil when it isn't.
enum GitCommitBlock: Equatable {
    case emptyMessage, busy, conflicts

    var reason: String {
        switch self {
        case .emptyMessage: "Write a commit message first."
        case .busy: "Wait for the current git operation to finish."
        case .conflicts: "Resolve the conflicts before committing."
        }
    }

    static func block(message: String, busy: Bool, conflicts: Int) -> GitCommitBlock? {
        if conflicts > 0 { return .conflicts }
        if busy { return .busy }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyMessage }
        return nil
    }
}
