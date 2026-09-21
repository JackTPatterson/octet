import Foundation

/// Workspaces on the same branch (or in the same worktree) read as one thing
/// in the sidebar: their cards sit together under a single branch chip
/// instead of each card repeating the branch name.
struct BranchRun: Identifiable, Equatable {
    /// Branch as git reports it for the workspace's folder.
    let branch: String?
    /// The worktree a workspace was opened in, when it is one.
    let worktreePath: String?
    var workspaces: [EngineWorkspace]

    /// Stable across refreshes: the run's key plus its first workspace.
    var id: String { "\(key)|\(workspaces.first?.workspaceId ?? "")" }
    var key: String { "\(branch ?? "")|\(worktreePath ?? "")" }
    /// Nothing to label: no branch and no worktree.
    var isBare: Bool { branch == nil && worktreePath == nil }

    var worktreeName: String? {
        worktreePath.map { ($0 as NSString).lastPathComponent }
    }
}

enum BranchRuns {
    /// Splits a project's workspaces into consecutive runs that share a
    /// branch and worktree, keeping the order the sidebar already uses.
    static func make(
        _ workspaces: [EngineWorkspace],
        branch: (EngineWorkspace) -> String?,
        worktree: (EngineWorkspace) -> EngineWorktree?
    ) -> [BranchRun] {
        var runs: [BranchRun] = []
        for workspace in workspaces {
            let worktreePath = worktree(workspace)?.path
            let branch = branch(workspace) ?? worktree(workspace)?.branch
            if var last = runs.last, last.branch == branch, last.worktreePath == worktreePath {
                last.workspaces.append(workspace)
                runs[runs.count - 1] = last
            } else {
                runs.append(BranchRun(branch: branch, worktreePath: worktreePath, workspaces: [workspace]))
            }
        }
        return runs
    }
}
