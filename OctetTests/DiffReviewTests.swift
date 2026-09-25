import XCTest

final class DiffReviewTests: XCTestCase {
    private let sample = """
    diff --git a/src/app.swift b/src/app.swift
    index 1111111..2222222 100644
    --- a/src/app.swift
    +++ b/src/app.swift
    @@ -10,4 +10,5 @@ struct App {
         let a = 1
    -    let b = 2
    +    let b = 3
    +    let c = 4
         let d = 5
    \\ No newline at end of file
    diff --git a/docs/new file.md b/docs/new file.md
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/docs/new file.md
    @@ -0,0 +1,2 @@
    +# Hello
    +world
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    index 4444444..0000000
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    diff --git a/logo.png b/logo.png
    index 5555555..6666666 100644
    Binary files a/logo.png and b/logo.png differ
    """

    func testReadsFilesHunksAndLineNumbers() throws {
        let files = ReviewDiff.parse(sample)
        XCTAssertEqual(files.map(\.path), ["src/app.swift", "docs/new file.md", "old.txt", "logo.png"])
        XCTAssertEqual(files.map(\.status), [.modified, .added, .deleted, .modified])
        XCTAssertEqual(files.map(\.added), [2, 2, 0, 0])
        XCTAssertEqual(files.map(\.removed), [1, 0, 1, 0])
        XCTAssertTrue(files[3].binary)

        let lines = try XCTUnwrap(files.first?.hunks.first?.lines)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(lines.map(\.oldNumber), [10, 11, nil, nil, 12])
        XCTAssertEqual(lines.map(\.newNumber), [10, nil, 11, 12, 13])
        XCTAssertEqual(lines[2].text, "    let b = 3")
        XCTAssertEqual(lines.map(\.number), [10, 11, 11, 12, 13])
        XCTAssertEqual(files[2].hunks.first?.lines.first?.oldNumber, 1)
    }

    func testAHugeFileIsCountedButNotDrawn() {
        let big = "diff --git a/big.json b/big.json\n--- a/big.json\n+++ b/big.json\n@@ -1,0 +1,50 @@\n"
            + (1...50).map { "+line \($0)" }.joined(separator: "\n")
            + "\ndiff --git a/small.txt b/small.txt\n--- a/small.txt\n+++ b/small.txt\n@@ -1 +1 @@\n-a\n+b"
        let files = ReviewDiff.parse(big, fileLimit: 20)
        XCTAssertTrue(files[0].tooLarge)
        XCTAssertEqual(files[0].added, 50)
        XCTAssertEqual(files[0].hunks, [])
        XCTAssertFalse(files[1].tooLarge)
        XCTAssertEqual(files[1].hunks.first?.lines.count, 2)
    }

    func testTheWholeDiffIsCappedToo() {
        let many = (1...5).map { "diff --git a/f\($0) b/f\($0)\n--- a/f\($0)\n+++ b/f\($0)\n@@ -0,0 +1,10 @@\n"
            + (1...10).map { "+x\($0)" }.joined(separator: "\n") }.joined(separator: "\n")
        let files = ReviewDiff.parse(many, fileLimit: 100, totalLimit: 25)
        XCTAssertEqual(files.map(\.tooLarge), [false, false, true, true, true])
        XCTAssertEqual(files.map(\.added), [10, 10, 10, 10, 10])
    }

    func testCommentsBecomeOnePromptInFileOrder() {
        let files = ReviewDiff.parse(sample)
        let lines = files[0].hunks[0].lines
        let prompt = ReviewComment.prompt([
            ReviewComment(path: "src/app.swift", line: lines[3], text: "c isn't used anywhere"),
            ReviewComment(path: "docs/new file.md", line: files[1].hunks[0].lines[0], text: "Title case,\nplease"),
            ReviewComment(path: "src/app.swift", line: lines[1], text: "why change b?"),
            ReviewComment(path: "src/app.swift", line: lines[0], text: "   "),
        ])
        XCTAssertEqual(prompt, """
        I reviewed your changes. Please address these comments:

        - docs/new file.md:1 `# Hello`
          Title case,
          please
        - src/app.swift:11 (removed line) `let b = 2`
          why change b?
        - src/app.swift:12 `let c = 4`
          c isn't used anywhere
        """)
        XCTAssertEqual(ReviewComment.prompt([]), "")
    }

    // MARK: - A real repository

    func testReadsAWorkingTreeIncludingNewFilesAgainstEitherBase() throws {
        let git = Git()
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("octet-review-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let identity = ["-c", "user.email=t@t", "-c", "user.name=t"]
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: repo)
        try git.run(identity + ["commit", "-qm", "base"], in: repo)
        try git.run(["switch", "-q", "-c", "feature"], in: repo)
        try "one\n2\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git.run(identity + ["commit", "-qam", "committed on the branch"], in: repo)
        try "one\n2\nthree\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "brand new\n".write(toFile: repo + "/ñew.txt", atomically: true, encoding: .utf8)

        let uncommitted = try XCTUnwrap(ReviewDiff.read(in: repo, base: .uncommitted, git: git))
        XCTAssertEqual(uncommitted.baseName, "HEAD")
        XCTAssertEqual(uncommitted.files.map(\.path), ["a.txt", "ñew.txt"])
        XCTAssertEqual(uncommitted.files.map(\.added), [1, 1])
        XCTAssertEqual(uncommitted.files[1].status, .added)

        let branch = try XCTUnwrap(ReviewDiff.read(in: repo, base: .branch, git: git))
        XCTAssertEqual(branch.baseName, "main")
        XCTAssertEqual(branch.files.first { $0.path == "a.txt" }?.added, 2)
        XCTAssertEqual(branch.files.first { $0.path == "a.txt" }?.removed, 1)
        // Nothing was staged to read it.
        XCTAssertEqual(try git.run(["diff", "--cached", "--name-only"], in: repo), "")
        XCTAssertNil(ReviewDiff.read(in: NSTemporaryDirectory() + "not-a-repo-\(UUID().uuidString)", base: .uncommitted, git: git))
    }

    func testCommitAllTakesNewFilesToo() throws {
        let git = Git()
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("octet-commit-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q"], in: repo)
        try git.run(["config", "user.email", "t@t"], in: repo)
        try git.run(["config", "user.name", "t"], in: repo)
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: repo)
        try git.run(["commit", "-qm", "base"], in: repo)
        try "b\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ReviewDiff.commitAll(message: "  ", in: repo, git: git))
        let hash = try ReviewDiff.commitAll(message: "Make greetings excited", in: repo, git: git)

        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(try git.run(["log", "-1", "--format=%s"], in: repo), "Make greetings excited")
        XCTAssertEqual(try git.run(["status", "--porcelain"], in: repo), "")
        XCTAssertEqual(ReviewDiff.read(in: repo, base: .uncommitted, git: git)?.files, [])
    }
}
