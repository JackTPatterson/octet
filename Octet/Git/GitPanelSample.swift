#if DEBUG
import Foundation

/// Made-up checkouts for looking at the git panel without a repository
/// (`OCTET_OPEN_WINDOW=planes:git:sample`). Never touches git.
extension GitPanelModel {
    func loadSample(opened: Bool) {
        let claude = Worker(paneId: "p1", tabId: "t1", workspaceId: "w1", agent: "claude", name: "Claude", isSubagent: false)
        let codex = Worker(paneId: "p2", tabId: "t2", workspaceId: "w1", agent: "codex", name: "Codex", isSubagent: false)
        let files: [AgentGit.FileChange] = [
            .init(path: "Octet/Git/GitPanel.swift", kind: .modified, staged: true, added: 84, removed: 212),
            .init(path: "Octet/Git/GitHeader.swift", kind: .added, staged: true, added: 140, removed: 0),
            .init(path: "Octet/Sidebar/SidePanel.swift", kind: .modified, staged: false, added: 3, removed: 4),
            .init(path: "Shared/AgentGit.swift", kind: .modified, staged: false, added: 12, removed: 1),
            .init(path: "OctetTests/GitPanelLogicTests.swift", kind: .untracked, staged: false),
            .init(path: "docs/notes/a-rather-long-directory-name/and-a-long-file-name-too.md", kind: .untracked, staged: false),
        ]
        let now = Date()
        var checkout = AgentGit.Checkout(top: "/Users/sample/Developer/octet")
        checkout.branch = .init(name: "feat/git-panel-revamp", upstream: "origin/feat/git-panel-revamp", ahead: 2, behind: 0)
        checkout.base = "origin/main"
        checkout.aheadOfBase = 3
        checkout.behindBase = 1
        checkout.files = files
        checkout.commits = [
            .init(sha: "1345a66aaaaaaa", subject: "A head-profile brain for Agents", author: "Jack", date: now.addingTimeInterval(-3600)),
            .init(sha: "8dcd606bbbbbbb", subject: "Merge pull request #36", author: "Jack", date: now.addingTimeInterval(-86400)),
        ]
        checkout.checkpoints = [.init(ref: "refs/octet/checkpoints/1", commit: "abc", date: now.addingTimeInterval(-1800), label: "Tidy the git panel")]
        let group = Group(checkout: checkout, workers: [claude, codex],
                          editors: [files[0].path: [claude], files[1].path: [claude], files[2].path: [codex]])
        let worktrees: [AgentGit.Worktree] = [
            .init(path: "/Users/sample/Developer/octet", branch: "feat/git-panel-revamp", isMain: true, dirty: true, aheadOfBase: 3),
            .init(path: "/Users/sample/Developer/octet-wt/fix", branch: "fix/tabs", isMain: false, merged: true),
        ]
        showSample(groups: [group], worktrees: worktrees,
                   openSections: opened ? ["history", "worktrees", "handoff"] : [])
    }
}
#endif
