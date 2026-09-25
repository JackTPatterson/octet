import XCTest

final class AccountProfilesTests: XCTestCase {
    private let work = AccountProfile(id: "w", name: "Work", agent: "claude", home: "~/.claude-work")
    private let side = AccountProfile(id: "s", name: "Side", agent: "claude", home: "/accounts/side")
    private let codex = AccountProfile(id: "c", name: "Work", agent: "codex", home: "~/.codex-work")
    private var profiles: [AccountProfile] { [work, side, codex] }

    override func tearDown() {
        // The configuration is process-wide; leave it as other tests expect.
        AccountProfiles.configure(profiles: [], assignments: [])
        super.tearDown()
    }

    func testTheDeepestAssignedFolderWinsPerAgent() {
        let assignments = [AccountAssignment(folder: "/src", profileId: "w"),
                           AccountAssignment(folder: "/src/side-project", profileId: "s"),
                           AccountAssignment(folder: "/src", profileId: "c")]
        XCTAssertEqual(AccountProfiles.profiles(for: "/src/api", profiles: profiles, assignments: assignments).map(\.id), ["w", "c"])
        XCTAssertEqual(AccountProfiles.profiles(for: "/src/side-project/web", profiles: profiles, assignments: assignments).map(\.id),
                       ["s", "c"])
        XCTAssertEqual(AccountProfiles.profiles(for: "/elsewhere", profiles: profiles, assignments: assignments), [])
        // A sibling that only shares a prefix isn't inside.
        XCTAssertEqual(AccountProfiles.profiles(for: "/src-old", profiles: profiles, assignments: assignments), [])
    }

    func testAWorktreeFollowsItsMainCheckout() {
        let assignments = [AccountAssignment(folder: "/src/api", profileId: "w")]
        XCTAssertEqual(AccountProfiles.profiles(for: "/Users/me/.octet/worktrees/api/feat", root: "/src/api",
                                                profiles: profiles, assignments: assignments).map(\.id), ["w"])
    }

    func testEnvironmentPointsEachAgentAtItsFolder() {
        let assignments = [AccountAssignment(folder: "/src", profileId: "w"), AccountAssignment(folder: "/src", profileId: "c")]
        XCTAssertEqual(AccountProfiles.environment(for: "/src/x", profiles: profiles, assignments: assignments, userHome: "/Users/me"),
                       ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "CODEX_HOME": "/Users/me/.codex-work"])
    }

    func testEveryShellStartingRequestGetsTheEnvironment() {
        let env: (String) -> [String: String] = { $0.hasPrefix("/src") ? ["CLAUDE_CONFIG_DIR": "/w"] : [:] }
        for method in ["workspace.create", "tab.create", "pane.split"] {
            let out = AccountProfiles.inject(method, ["cwd": "/src/api", "focus": true], environment: env)
            XCTAssertEqual(out["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": "/w"], method)
            XCTAssertEqual(out["focus"] as? Bool, true)
        }
        // Elsewhere, and for requests that start nothing, the request is untouched.
        XCTAssertNil(AccountProfiles.inject("tab.create", ["cwd": "/tmp"], environment: env)["env"])
        XCTAssertNil(AccountProfiles.inject("tab.focus", ["cwd": "/src"], environment: env)["env"])
    }

    func testARequestWithoutAFolderUsesItsPanesOrWorkspaces() {
        let env: (String) -> [String: String] = { $0 == "/src/api" ? ["CLAUDE_CONFIG_DIR": "/w"] : [:] }
        let out = AccountProfiles.inject("pane.split", ["target_pane_id": "w1:p1", "direction": "right"], environment: env,
                                         cwdOf: { $0["target_pane_id"] as? String == "w1:p1" ? "/src/api" : nil })
        XCTAssertEqual(out["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": "/w"])
    }

    func testLayoutsGetItInEveryPaneAndWhatTheCallerSetWins() throws {
        let env: (String) -> [String: String] = { _ in ["CLAUDE_CONFIG_DIR": "/w", "CODEX_HOME": "/c"] }
        let params: [String: Any] = ["tab_label": "x", "root": [
            "type": "split", "direction": "right",
            "first": ["type": "pane", "cwd": "/src/a"],
            "second": ["type": "pane", "cwd": "/src/b", "env": ["CLAUDE_CONFIG_DIR": "/signin"]],
        ] as [String: Any]]
        let root = try XCTUnwrap(AccountProfiles.inject("layout.apply", params, environment: env)["root"] as? [String: Any])
        XCTAssertEqual((root["first"] as? [String: Any])?["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": "/w", "CODEX_HOME": "/c"])
        XCTAssertEqual((root["second"] as? [String: Any])?["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": "/signin", "CODEX_HOME": "/c"])
    }

    func testTranscriptsAreLookedForInTheAccountsFolder() {
        AccountProfiles.configure(profiles: profiles, assignments: [AccountAssignment(folder: "/src/api", profileId: "w")])
        XCTAssertEqual(ClaudeTranscriptActivity.projectDirectory(forCwd: "/src/api", home: "/Users/me"),
                       "/Users/me/.claude-work/projects/-src-api")
        XCTAssertEqual(ClaudeTranscriptActivity.projectDirectory(forCwd: "/tmp/x", home: "/Users/me"),
                       "/Users/me/.claude/projects/-tmp-x")
        XCTAssertEqual(AgentConversation.claudeLogPath(sessionId: "abc", cwd: "/src/api", home: "/Users/me"),
                       "/Users/me/.claude-work/projects/-src-api/abc.jsonl")
        XCTAssertEqual(AccountProfiles.allClaudeHomes(home: "/Users/me"),
                       ["/Users/me/.claude", "/Users/me/.claude-work", "/accounts/side"])
        XCTAssertEqual(AccountProfiles.codexHome(forCwd: "/src/api", home: "/Users/me"), "/Users/me/.codex")
    }

    func testNothingChangesWithoutAssignments() {
        AccountProfiles.configure(profiles: profiles, assignments: [])
        let params: [String: Any] = ["cwd": "/src/api"]
        XCTAssertNil(AccountProfiles.prepare("tab.create", params)["env"])
        XCTAssertEqual(AccountProfiles.claudeHome(forCwd: "/src/api", home: "/Users/me"), "/Users/me/.claude")
    }

    func testSuggestedFoldersAreTidy() {
        XCTAssertEqual(AccountProfile.suggestedHome(agent: "claude", name: "Work"), "~/.claude-work")
        XCTAssertEqual(AccountProfile.suggestedHome(agent: "codex", name: "  Client A / 2 "), "~/.codex-client-a-2")
        XCTAssertEqual(AccountProfile.suggestedHome(agent: "claude", name: "!!"), "~/.claude-account")
    }
}
