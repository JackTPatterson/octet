import XCTest

final class WorktreeCleanupTests: XCTestCase {
    func testReadsPorcelainSkippingBareAndMarkingTheMainCheckout() {
        let text = """
        worktree /src/repo
        HEAD 1111
        branch refs/heads/main

        worktree /wt/repo/feat
        HEAD 2222
        branch refs/heads/feat/login

        worktree /wt/repo/detached
        HEAD 3333
        detached
        """
        let worktrees = WorktreeCleanup.parse(text)
        XCTAssertEqual(worktrees.map(\.path), ["/src/repo", "/wt/repo/feat", "/wt/repo/detached"])
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feat/login", nil])
        XCTAssertEqual(worktrees.map(\.isMain), [true, false, false])
    }

    func testFindsMergedCleanWorktreesInARealRepository() throws {
        let git = Git()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-wtc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let id = ["-c", "user.email=t@t", "-c", "user.name=t"]
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: repo)
        try git.run(id + ["commit", "-qm", "base"], in: repo)
        // done: merged and clean. busy: merged but edited. open: not merged.
        for name in ["done", "busy", "open"] {
            try git.run(["worktree", "add", "-q", "-b", name, base + "/" + name], in: repo)
        }
        try "open work\n".write(toFile: base + "/open/b.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: base + "/open")
        try git.run(id + ["commit", "-qm", "unmerged work"], in: base + "/open")
        try "edited\n".write(toFile: base + "/busy/a.txt", atomically: true, encoding: .utf8)

        let worktrees = WorktreeCleanup.list(in: repo, git: git)
        let byBranch = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.branch ?? "", $0) })
        XCTAssertEqual(byBranch["done"]?.removable, true)
        XCTAssertEqual(byBranch["busy"]?.merged, true)
        XCTAssertEqual(byBranch["busy"]?.dirty, true)
        XCTAssertEqual(byBranch["busy"]?.removable, false)
        XCTAssertEqual(byBranch["open"]?.merged, false)
        XCTAssertEqual(byBranch["main"]?.removable, false)
        XCTAssertGreaterThan(WorktreeCleanup.measure(base + "/done") ?? 0, 0)

        try WorktreeCleanup.remove(try XCTUnwrap(byBranch["done"]), in: repo, git: git)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/done"))
        // A worktree with uncommitted changes isn't removed.
        XCTAssertThrowsError(try WorktreeCleanup.remove(try XCTUnwrap(byBranch["busy"]), in: repo, git: git))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base + "/busy/a.txt"))
        XCTAssertEqual(WorktreeCleanup.list(in: repo, git: git).count, 3)
    }
}
