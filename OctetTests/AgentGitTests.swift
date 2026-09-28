import XCTest

final class AgentGitParsingTests: XCTestCase {
    func testStatusReadsBranchAndEveryKindOfChange() {
        // `git status --porcelain=v2 --branch -z`, as git 2.4x prints it.
        let text = [
            "# branch.oid 59926f3205404e780a2bb8a11ea8f9918f34c8d3",
            "# branch.head feature",
            "# branch.upstream origin/feature",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 7898192 7898192 a.txt",
            "2 R. N... 100644 100644 100644 6178079 6178079 R100 b d.txt",
            "b c.txt",
            "1 .D N... 100644 100644 000000 286c5f5 286c5f5 d.txt",
            "1 A. N... 000000 100644 100644 0000000 19d9cc8 s.txt",
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.swift",
            "? n.txt",
        ].joined(separator: "\0") + "\0"
        let (branch, files) = AgentGit.parseStatus(text)
        XCTAssertEqual(branch, AgentGit.Branch(name: "feature", upstream: "origin/feature", ahead: 2, behind: 1))
        XCTAssertEqual(files.map(\.path), ["a.txt", "b d.txt", "d.txt", "s.txt", "conflict.swift", "n.txt"])
        XCTAssertEqual(files.map(\.kind), [.modified, .renamed, .deleted, .added, .conflicted, .untracked])
        XCTAssertEqual(files.map(\.staged), [false, true, false, true, false, false])
    }

    func testDetachedHeadHasNoBranchName() {
        let (branch, files) = AgentGit.parseStatus("# branch.oid abc\0# branch.head (detached)\0")
        XCTAssertNil(branch.name)
        XCTAssertTrue(files.isEmpty)
    }

    func testNumstatLogAndCounts() {
        let counts = AgentGit.parseNumstat("2\t1\ta.txt\0-\t-\timage.png\0")
        XCTAssertEqual(counts["a.txt"]?.added, 2)
        XCTAssertEqual(counts["a.txt"]?.removed, 1)
        XCTAssertNotNil(counts["image.png"])
        XCTAssertNil(counts["image.png"]?.added ?? nil)

        let log = "abc123\u{1f}Fix the thing\u{1f}Ada\u{1f}1700000000\u{1e}\ndef456\u{1f}Add\u{1f}Bo\u{1f}1690000000\u{1e}"
        let commits = AgentGit.parseLog(log)
        XCTAssertEqual(commits.map(\.subject), ["Fix the thing", "Add"])
        XCTAssertEqual(commits.first?.date, Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(AgentGit.parseLeftRight("3\t5")?.left, 3)
        XCTAssertEqual(AgentGit.parseLeftRight("3\t5")?.right, 5)
        XCTAssertNil(AgentGit.parseLeftRight(""))
    }

    func testHandoffsFollowTheCheckoutsState() {
        var checkout = AgentGit.Checkout(top: "/repo")
        checkout.base = "main"
        XCTAssertEqual(AgentGitHandoff.offered(for: checkout), [])
        checkout.files = [AgentGit.FileChange(path: "a", kind: .modified, staged: false)]
        checkout.aheadOfBase = 2
        checkout.behindBase = 1
        XCTAssertEqual(AgentGitHandoff.offered(for: checkout), [.commit, .rebase, .describePR, .openPR])
        checkout.files.append(AgentGit.FileChange(path: "b", kind: .conflicted, staged: false))
        XCTAssertEqual(AgentGitHandoff.offered(for: checkout), [.resolveConflicts])
        XCTAssertTrue(AgentGitHandoff.resolveConflicts.prompt(checkout: checkout).contains("b"))
    }
}

/// Against a real repository, as the panel reads one.
final class AgentGitReadTests: XCTestCase {
    private var base: URL!
    private var repo: String { base.appendingPathComponent("repo").path }
    private let git = Git()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try run("init", "-q", "-b", "main")
        try write("a.txt", "a\n")
        try write("gone.txt", "gone\n")
        try commit("init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func run(_ args: String...) throws { try git.run(args, in: repo) }
    private func commit(_ message: String) throws {
        try run("add", "-A")
        try run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", message)
    }
    private func write(_ path: String, _ text: String) throws {
        try text.write(toFile: repo + "/" + path, atomically: true, encoding: .utf8)
    }

    func testReadsABranchAgainstMainWithItsChangesAndCommits() throws {
        try run("checkout", "-qb", "agent/task")
        try write("b.txt", "b\n")
        try commit("Add b")
        try write("a.txt", "a2\nmore\n")
        try FileManager.default.removeItem(atPath: repo + "/gone.txt")
        try write("new.txt", "new\n")

        let checkout = try XCTUnwrap(AgentGit.read(top: repo, git: git))
        XCTAssertEqual(checkout.branch.name, "agent/task")
        XCTAssertEqual(checkout.base, "main")
        XCTAssertFalse(checkout.onBase)
        XCTAssertEqual(checkout.aheadOfBase, 1)
        XCTAssertEqual(checkout.behindBase, 0)
        XCTAssertEqual(checkout.commits.map(\.subject), ["Add b"])
        let files = Dictionary(uniqueKeysWithValues: checkout.files.map { ($0.path, $0) })
        XCTAssertEqual(files["a.txt"]?.kind, .modified)
        XCTAssertEqual(files["a.txt"]?.added, 2)
        XCTAssertEqual(files["a.txt"]?.removed, 1)
        XCTAssertEqual(files["gone.txt"]?.kind, .deleted)
        XCTAssertEqual(files["new.txt"]?.kind, .untracked)
        XCTAssertEqual(AgentGitHandoff.offered(for: checkout), [.commit, .describePR, .openPR])
    }

    func testOnMainShowsRecentCommits() throws {
        let checkout = try XCTUnwrap(AgentGit.read(top: repo, git: git))
        XCTAssertTrue(checkout.onBase)
        XCTAssertEqual(checkout.commits.map(\.subject), ["init"])
        XCTAssertTrue(checkout.files.isEmpty)
    }
}
