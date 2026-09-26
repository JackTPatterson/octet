import XCTest

/// Against real repositories: what matters is what git and the files on
/// disk end up as.
final class CheckpointsTests: XCTestCase {
    private var base: URL!
    private var repo: String { base.appendingPathComponent("repo").path }
    private let git = Git()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try run("init", "-q")
        try write(".gitignore", "build/\n")
        try write("src/a.swift", "let a = 1\n")
        try write("README.md", "hello\n")
        try run("add", "-A")
        try run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func run(_ args: String...) throws { try git.run(args, in: repo) }
    private func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ path: String) -> String? { try? String(contentsOfFile: repo + "/" + path, encoding: .utf8) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: repo + "/" + path) }

    func testATurnCanBeUndoneIncludingFilesMadeAndDeleted() throws {
        try write("src/a.swift", "let a = 2 // mine, not committed\n")
        try write("notes.txt", "untracked but mine\n")
        let before = try XCTUnwrap(Checkpoints.create(in: repo + "/src", label: "Claude Code · api"))
        XCTAssertEqual(before.label, "Claude Code · api")

        // The agent's turn: edits, a new file, a deletion, and a build product.
        try write("src/a.swift", "let a = 3 // the agent's\n")
        try write("src/b.swift", "let b = 1\n")
        try FileManager.default.removeItem(atPath: repo + "/README.md")
        try write("build/out.o", "binary")
        XCTAssertEqual(Set(Checkpoints.changes(since: before, in: repo)), ["src/a.swift", "src/b.swift", "README.md"])

        let undo = try Checkpoints.restore(before, in: repo)

        XCTAssertEqual(read("src/a.swift"), "let a = 2 // mine, not committed\n")
        XCTAssertEqual(read("notes.txt"), "untracked but mine\n")
        XCTAssertEqual(read("README.md"), "hello\n")
        XCTAssertFalse(exists("src/b.swift"))
        // Ignored files are never part of it, either way.
        XCTAssertTrue(exists("build/out.o"))
        XCTAssertEqual(Checkpoints.changes(since: before, in: repo), [])

        // And the restore itself can be undone.
        try Checkpoints.restore(undo, in: repo)
        XCTAssertEqual(read("src/a.swift"), "let a = 3 // the agent's\n")
        XCTAssertTrue(exists("src/b.swift"))
        XCTAssertFalse(exists("README.md"))
    }

    func testNothingTheUserWorksWithIsTouched() throws {
        try write("src/a.swift", "let a = 2\n")
        try run("add", "src/a.swift")   // staged on purpose
        try write("src/a.swift", "let a = 3\n")
        let status = try git.run(["status", "--porcelain"], in: repo)
        let head = try git.run(["rev-parse", "HEAD"], in: repo)
        let branches = try git.run(["branch", "--list"], in: repo)

        let checkpoint = try XCTUnwrap(Checkpoints.create(in: repo, label: "turn"))

        XCTAssertEqual(try git.run(["status", "--porcelain"], in: repo), status)
        XCTAssertEqual(try git.run(["rev-parse", "HEAD"], in: repo), head)
        XCTAssertEqual(try git.run(["branch", "--list"], in: repo), branches)
        XCTAssertEqual(try git.run(["stash", "list"], in: repo), "")
        XCTAssertTrue(checkpoint.ref.hasPrefix(Checkpoints.refPrefix))
        // The staged version stays staged, the newer one in the file.
        XCTAssertEqual(try git.run(["show", ":src/a.swift"], in: repo), "let a = 2")
    }

    func testAnUnchangedTreeIsntCheckpointedTwice() throws {
        XCTAssertNotNil(Checkpoints.create(in: repo, label: "one"))
        XCTAssertNil(Checkpoints.create(in: repo, label: "two"))
        try write("src/a.swift", "changed\n")
        XCTAssertNotNil(Checkpoints.create(in: repo, label: "three"))
        XCTAssertEqual(Checkpoints.list(in: repo).map(\.label), ["three", "one"])
    }

    func testARepositoryWithNoCommitsYetStillWorks() throws {
        let fresh = base.appendingPathComponent("fresh").path
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        try git.run(["init", "-q"], in: fresh)
        try "draft\n".write(toFile: fresh + "/draft.md", atomically: true, encoding: .utf8)
        let checkpoint = try XCTUnwrap(Checkpoints.create(in: fresh, label: "first"))
        try "rewritten\n".write(toFile: fresh + "/draft.md", atomically: true, encoding: .utf8)
        try Checkpoints.restore(checkpoint, in: fresh)
        XCTAssertEqual(try String(contentsOfFile: fresh + "/draft.md", encoding: .utf8), "draft\n")
    }

    func testOutsideARepositoryThereIsNothingToDo() {
        XCTAssertNil(Checkpoints.create(in: base.path, label: "x"))
        XCTAssertEqual(Checkpoints.list(in: base.path), [])
        XCTAssertNil(Checkpoints.create(in: "/does/not/exist", label: "x"))
    }

    func testAWorktreeKeepsItsOwnCheckpoints() throws {
        let worktree = base.appendingPathComponent("wt").path
        try run("worktree", "add", "-q", "-b", "feat", worktree)
        try "wt change\n".write(toFile: worktree + "/README.md", atomically: true, encoding: .utf8)
        try write("README.md", "main change\n")
        XCTAssertNotNil(Checkpoints.create(in: worktree, label: "in worktree"))
        XCTAssertNotNil(Checkpoints.create(in: repo, label: "in main"))
        XCTAssertEqual(Checkpoints.list(in: worktree).map(\.label), ["in worktree"])
        XCTAssertEqual(Checkpoints.list(in: repo).map(\.label), ["in main"])
    }

    func testOnlyTheNewestAreKept() throws {
        for index in 0..<(Checkpoints.keep + 3) {
            try write("counter.txt", "\(index)\n")
            XCTAssertNotNil(Checkpoints.create(in: repo, label: "\(index)"))
        }
        let labels = Checkpoints.list(in: repo).map(\.label)
        XCTAssertEqual(labels.count, Checkpoints.keep)
        XCTAssertEqual(labels.first, "\(Checkpoints.keep + 2)")
    }

    func testFindsTheCheckpointForAPrompt() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        func point(_ offset: TimeInterval, _ label: String) -> Checkpoint {
            Checkpoint(ref: label, commit: label, date: t.addingTimeInterval(offset), label: label)
        }
        let list = [point(400, "third"), point(200, "second"), point(2, "first"), point(-500, "older")]
        XCTAssertEqual(Checkpoints.checkpoint(forPromptAt: t, nextPromptAt: t.addingTimeInterval(150), in: list)?.label, "first")
        XCTAssertEqual(Checkpoints.checkpoint(forPromptAt: t.addingTimeInterval(190), nextPromptAt: nil, in: list)?.label, "second")
        XCTAssertNil(Checkpoints.checkpoint(forPromptAt: t.addingTimeInterval(100), nextPromptAt: t.addingTimeInterval(150), in: list),
                     "no checkpoint between this prompt and the next")
    }
}
