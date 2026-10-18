import XCTest

final class GitPanelLogicTests: XCTestCase {
    private func file(_ path: String, _ kind: AgentGit.FileChange.Kind = .modified, staged: Bool = false) -> AgentGit.FileChange {
        AgentGit.FileChange(path: path, kind: kind, staged: staged)
    }

    func testChangesSplitIntoStagedChangesAndUntracked() {
        let groups = GitChangeGroups(files: [
            file("a", staged: true), file("b"), file("c", .untracked), file("d", .conflicted), file("e", .added, staged: true),
        ])
        XCTAssertEqual(groups.staged.map(\.path), ["a", "e"])
        XCTAssertEqual(groups.changes.map(\.path), ["b", "d"])
        XCTAssertEqual(groups.untracked.map(\.path), ["c"])
        XCTAssertEqual(groups.count, 5)
    }

    func testEmptyGroupsAreLeftOut() {
        XCTAssertEqual(GitChangeGroups(files: [file("b")]).visible.map(\.kind), [.changes])
        XCTAssertEqual(GitChangeGroups(files: [file("b", staged: true), file("c", .untracked)]).visible.map(\.kind), [.staged, .untracked])
        XCTAssertTrue(GitChangeGroups(files: []).visible.isEmpty)
    }

    func testBulkActionsKeepTheirLabelsTrue() {
        let both = GitChangeGroups(files: [file("a", staged: true), file("b"), file("c", .untracked)])
        XCTAssertEqual(both.bulkAction(for: .staged), .unstageAll)
        XCTAssertEqual(both.bulkAction(for: .changes), .stageAll)
        // Stage All would take the changes too, so Untracked doesn't offer it.
        XCTAssertNil(both.bulkAction(for: .untracked))
        let onlyUntracked = GitChangeGroups(files: [file("c", .untracked)])
        XCTAssertEqual(onlyUntracked.bulkAction(for: .untracked), .stageAll)
    }

    func testPrimarySyncAction() {
        typealias B = AgentGit.Branch
        XCTAssertNil(GitSyncAction.primary(for: B(name: nil)), "detached HEAD has nothing to sync")
        XCTAssertEqual(GitSyncAction.primary(for: B(name: "x")), .publish)
        XCTAssertNil(GitSyncAction.primary(for: B(name: "x", upstream: "origin/x")), "in sync")
        XCTAssertEqual(GitSyncAction.primary(for: B(name: "x", upstream: "origin/x", ahead: 2)), .push(2))
        XCTAssertEqual(GitSyncAction.primary(for: B(name: "x", upstream: "origin/x", behind: 3)), .pull(3))
        XCTAssertEqual(GitSyncAction.primary(for: B(name: "x", upstream: "origin/x", ahead: 1, behind: 3)), .pull(3), "pull first")
        XCTAssertEqual(GitSyncAction.pull(3).title, "Pull 3")
        XCTAssertEqual(GitSyncAction.push(0).title, "Push")
        XCTAssertEqual(GitSyncAction.publish.title, "Publish")
    }

    func testSectionsShowOnlyWhenRelevant() {
        let clean = AgentGit.Checkout(top: "/r")
        let plan = GitSectionPlan(checkout: clean, promptable: true, hasEditors: false)
        XCTAssertFalse(plan.showChanges)
        XCTAssertFalse(plan.showHistory)
        XCTAssertFalse(plan.showHandoff)
        XCTAssertFalse(plan.showFilter)

        var dirty = clean
        dirty.files = [file("a")]
        dirty.commits = [AgentGit.Commit(sha: "abc1234", subject: "s", author: "a", date: Date())]
        let busy = GitSectionPlan(checkout: dirty, promptable: true, hasEditors: true)
        XCTAssertTrue(busy.showFilter)
        XCTAssertTrue(busy.showChanges)
        XCTAssertTrue(busy.showHistory)
        XCTAssertTrue(busy.showHandoff, "an agent that takes prompts and a commit to ask for")
        XCTAssertEqual(busy.historyCount, 1)
        let shell = GitSectionPlan(checkout: dirty, promptable: false, hasEditors: false)
        XCTAssertFalse(shell.showHandoff, "no agent to ask")

        XCTAssertFalse(GitSectionPlan.showWorktrees(count: 1))
        XCTAssertTrue(GitSectionPlan.showWorktrees(count: 2))
    }

    func testCommitBlockExplainsWhy() {
        XCTAssertNil(GitCommitBlock.block(message: "fix", busy: false, conflicts: 0))
        XCTAssertEqual(GitCommitBlock.block(message: "  \n", busy: false, conflicts: 0), .emptyMessage)
        XCTAssertEqual(GitCommitBlock.block(message: "fix", busy: true, conflicts: 0), .busy)
        XCTAssertEqual(GitCommitBlock.block(message: "", busy: true, conflicts: 2), .conflicts)
    }
}
