import Foundation

/// The Git panel's one primary button, whose label follows the checkout:
/// commit what's changed (and push it when that's all it takes), else pull,
/// push, publish or open a pull request, and a disabled "Sync" with the
/// reason when the branch has diverged. After T3 Code's quick git action.
struct GitPrimaryAction: Equatable {
    enum Kind: Equatable {
        case commit, commitAndPush, push, pull, publish, pushAndCreatePullRequest, sync
    }

    let kind: Kind
    /// Why it can't run now; nil when it can.
    let blocked: String?

    var enabled: Bool { blocked == nil }

    var title: String {
        switch kind {
        case .commit: "Commit"
        case .commitAndPush: "Commit & Push"
        case .push: "Push"
        case .pull: "Pull"
        case .publish: "Publish Branch"
        case .pushAndCreatePullRequest: "Push & Create PR"
        case .sync: "Sync"
        }
    }

    var icon: String {
        switch kind {
        case .commit: "check"
        case .commitAndPush, .push, .publish: "arrow.up"
        case .pull: "arrow.down"
        case .pushAndCreatePullRequest: "pull.request"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }

    /// The label while it runs, shown in the button.
    var progressTitle: String {
        switch kind {
        case .commit: "Committing…"
        case .commitAndPush: "Committing…"
        case .push: "Pushing…"
        case .pull: "Pulling…"
        case .publish, .pushAndCreatePullRequest: "Publishing…"
        case .sync: "Syncing…"
        }
    }

    /// - Parameters:
    ///   - changes: changed files in the working tree.
    ///   - commitBlock: why a commit can't happen now (no message, conflicts).
    ///   - hasRemote: the repository has somewhere to push.
    ///   - onBase: the branch is the default branch, where a pull request
    ///     makes no sense.
    ///   - aheadOfBase: commits the branch has that the default doesn't.
    static func resolve(branch: AgentGit.Branch, changes: Int, commitBlock: GitCommitBlock?,
                        hasRemote: Bool, onBase: Bool, aheadOfBase: Int) -> GitPrimaryAction {
        if changes > 0 {
            // Behind, a push would be refused; commit only.
            let pushes = branch.name != nil && branch.upstream != nil && branch.behind == 0
            return GitPrimaryAction(kind: pushes ? .commitAndPush : .commit, blocked: commitBlock?.reason)
        }
        guard let name = branch.name else {
            return GitPrimaryAction(kind: .commit, blocked: "HEAD is detached; check out a branch first.")
        }
        guard let upstream = branch.upstream else {
            guard hasRemote else {
                return GitPrimaryAction(kind: .publish, blocked: "This repository has no remote to publish to.")
            }
            if !onBase && aheadOfBase > 0 { return GitPrimaryAction(kind: .pushAndCreatePullRequest, blocked: nil) }
            return GitPrimaryAction(kind: .publish, blocked: nil)
        }
        if branch.ahead > 0 && branch.behind > 0 {
            return GitPrimaryAction(kind: .sync, blocked:
                "\(name) has diverged from \(upstream): \(branch.ahead) ahead, \(branch.behind) behind. Rebase or merge first.")
        }
        if branch.behind > 0 { return GitPrimaryAction(kind: .pull, blocked: nil) }
        if branch.ahead > 0 { return GitPrimaryAction(kind: .push, blocked: nil) }
        return GitPrimaryAction(kind: .push, blocked: "Up to date with \(upstream).")
    }
}
