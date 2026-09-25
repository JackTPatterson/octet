import XCTest

final class AgentLocationTests: XCTestCase {
    /// `/repo` is a checkout with a linked worktree at `/repo/.claude/worktrees/agent-1`
    /// and a second repository at `/other`.
    private let repos: [String: AgentLocations.GitLocation] = [
        "/repo": ("/repo/.git", "/repo", false),
        "/repo/.claude/worktrees/agent-1": ("/repo/.git/worktrees/agent-1", "/repo/.claude/worktrees/agent-1", true),
        "/other": ("/other/.git", "/other", false),
    ]

    private func locate(_ cwd: String, home: String?) -> AgentLocation? {
        AgentLocations.locate(cwd, home: home, gitLocation: { path in
            // The nearest repository at or above the path, deepest first.
            self.repos.keys.sorted { $0.count > $1.count }
                .first { path == $0 || path.hasPrefix($0 + "/") }
                .flatMap { self.repos[$0] }
        }, branch: { $0 == "/repo/.claude/worktrees/agent-1" ? "fix-login" : "main" })
    }

    func testStillHomeIsNoLocation() {
        XCTAssertNil(locate("/repo", home: "/repo"))
        XCTAssertNil(locate("/repo/", home: "/repo"))
    }

    func testWorktreeIsNamedByItsFolderWithItsBranch() throws {
        let location = try XCTUnwrap(locate("/repo/.claude/worktrees/agent-1/src", home: "/repo"))
        XCTAssertEqual(location.kind, .worktree)
        XCTAssertEqual(location.name, "agent-1")
        XCTAssertEqual(location.root, "/repo/.claude/worktrees/agent-1")
        XCTAssertEqual(location.branch, "fix-login")
        XCTAssertEqual(location.phrase, "worktree agent-1")
    }

    func testAnotherRepository() throws {
        let location = try XCTUnwrap(locate("/other/web", home: "/repo"))
        XCTAssertEqual(location.kind, .repository)
        XCTAssertEqual(location.name, "other")
    }

    func testSubfolderIsNamedFromTheRepositoryRoot() throws {
        let location = try XCTUnwrap(locate("/repo/server/api", home: "/repo/server"))
        XCTAssertEqual(location.kind, .subfolder)
        XCTAssertEqual(location.name, "server/api")
        XCTAssertNil(location.branch)
        XCTAssertEqual(locate("/repo", home: "/repo/server")?.name, "repo")
    }

    func testFolderOutsideAnyRepository() throws {
        let location = try XCTUnwrap(locate("/notes/drafts", home: "/notes"))
        XCTAssertEqual(location.kind, .folder)
        XCTAssertEqual(location.name, "drafts")
    }

    func testAgentsInOnePlaceShareAChip() throws {
        let a = try XCTUnwrap(locate("/repo/.claude/worktrees/agent-1", home: "/repo"))
        let b = try XCTUnwrap(locate("/repo/.claude/worktrees/agent-1/src", home: "/repo"))
        let c = try XCTUnwrap(locate("/repo/server", home: "/repo"))
        let grouped = AgentLocations.grouped([a, c, b])
        XCTAssertEqual(grouped.map(\.location.root), [a.root, c.root])
        XCTAssertEqual(grouped.map(\.count), [2, 1])
    }

    func testRendererReportsEachNewFolderOnce() {
        let renderer = SubagentTranscriptRenderer()
        renderer.home = "/repo"
        var reported: [String] = []
        renderer.onDirectory = { reported.append($0) }
        func line(_ cwd: String) -> Data {
            Data(#"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[]}}"#.utf8)
        }
        renderer.render(line: line("/repo"))
        renderer.render(line: line("/repo"))
        renderer.render(line: line("/repo/server"))
        renderer.render(line: line("/repo"))
        XCTAssertEqual(reported, ["/repo", "/repo/server", "/repo"])
    }
}

final class ContextWindowTests: XCTestCase {
    func testAnOverfullGuessedClaudeWindowIsTheLongOne() {
        var usage = TwinUsage()
        usage.contextWindow = TwinUsage.window(forModel: "claude-opus-5-5")
        usage.currentContextTokens = 216_509
        XCTAssertEqual(usage.effectiveContextWindow, 1_000_000)
        XCTAssertEqual(usage.label, "22%")
        usage.currentContextTokens = 150_000
        XCTAssertEqual(usage.label, "75%")
    }
}
