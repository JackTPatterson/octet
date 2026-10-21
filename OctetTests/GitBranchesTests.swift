import XCTest
@testable import Octet

final class GitBranchesTests: XCTestCase {
    private let local = """
    *\tmain\torigin/main\tahead 2, behind 1\t1700000300\t/repo
     \tfeature/a\torigin/feature/a\t\t1700000200\t
     \told\t\tgone\t1600000000\t/wt/old
    """

    func testParsesLocalBranches() {
        let entries = GitBranches.parseLocal(local)
        XCTAssertEqual(entries.map(\.name), ["main", "feature/a", "old"])
        XCTAssertTrue(entries[0].isCurrent)
        XCTAssertEqual(entries[0].ahead, 2)
        XCTAssertEqual(entries[0].behind, 1)
        XCTAssertEqual(entries[1].upstream, "origin/feature/a")
        XCTAssertNil(entries[1].worktree)
        XCTAssertTrue(entries[2].checkedOutElsewhere)
        XCTAssertFalse(entries[0].checkedOutElsewhere)
    }

    func testRemoteOnlySkipsHeadAndLocalNames() {
        let entries = GitBranches.parseLocal(local)
        let remote = "refs/remotes/origin/HEAD\t1\nrefs/remotes/origin/main\t1\nrefs/remotes/origin/fix/b\t1700000100\n"
        let only = GitBranches.parseRemote(remote, local: entries)
        XCTAssertEqual(only.map(\.name), ["origin/fix/b"])
        XCTAssertTrue(only[0].isRemote)
        XCTAssertEqual(GitBranches.localName(ofRemote: "origin/fix/b"), "fix/b")
    }

    func testSortsCurrentThenRecentThenRemote() {
        let entries = GitBranches.parseLocal(local)
        let remote = GitBranches.parseRemote("refs/remotes/origin/zzz\t1800000000\n", local: entries)
        XCTAssertEqual(GitBranches.sorted((entries + remote).reversed()).map(\.name), ["main", "feature/a", "old", "origin/zzz"])
    }

    func testFilterNeedsEveryWord() {
        let entries = GitBranches.parseLocal(local)
        XCTAssertEqual(GitBranches.filter(entries, query: "FEAT a").map(\.name), ["feature/a"])
        XCTAssertEqual(GitBranches.filter(entries, query: "").count, 3)
    }

    func testDirtyTreeGuard() {
        XCTAssertEqual(GitBranches.switchPlan(porcelain: ""), .proceed)
        XCTAssertEqual(GitBranches.switchPlan(porcelain: "?? new.txt\n"), .proceed)
        XCTAssertEqual(GitBranches.switchPlan(porcelain: " M a.swift\n?? b\nA  c\n"), .needsStash(files: 2))
    }

    func testNameValidationAndWorktreePath() {
        for good in ["fix", "feature/a-b", "v1.2"] { XCTAssertTrue(GitBranches.validName(good), good) }
        for bad in ["", "-x", "a b", "a..b", "a.lock", "a/", "a~1", "a:b", "x@{y}"] { XCTAssertFalse(GitBranches.validName(bad), bad) }
        XCTAssertEqual(GitBranches.worktreePath(folder: "/w", repository: "repo", branch: "feature/a"), "/w/repo/feature-a")
    }

    /// Against a real throwaway repository: the formats parse what git prints.
    func testListsARealRepository() throws {
        let dir = NSTemporaryDirectory() + "branches-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let git = Git()
        let identity = Git.identity
        try git.run(["init", "-q", "-b", "main"], in: dir)
        try git.run(["commit", "-q", "--allow-empty", "-m", "one"], in: dir, environment: identity)
        try git.run(["branch", "topic"], in: dir)
        let text = try git.run(["for-each-ref", "--format=" + GitBranches.listFormat, "refs/heads"], in: dir)
        let entries = GitBranches.sorted(GitBranches.parseLocal(text))
        XCTAssertEqual(entries.map(\.name), ["main", "topic"])
        XCTAssertTrue(entries[0].isCurrent)
        XCTAssertNotNil(entries[0].date)
    }
}
