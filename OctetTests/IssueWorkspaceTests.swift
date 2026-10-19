import XCTest

final class IssueWorkspaceTests: XCTestCase {
    func testBranchNamesFollowTheTracker() {
        XCTAssertEqual(IssueWorkspace.branchName(key: "ENG-12", title: "Fix login", tracker: .linear), "eng-12-fix-login")
        XCTAssertEqual(IssueWorkspace.branchName(key: "PROJ-7", title: "Fix login", tracker: .jira), "proj-7-fix-login")
        XCTAssertEqual(IssueWorkspace.branchName(key: "#142", title: "Fix login", tracker: .github), "issue-142-fix-login")
    }

    func testTitlesBecomeKebabCase() {
        XCTAssertEqual(IssueWorkspace.slug("  Crash on  “Café” sign-in!! (iOS) "), "crash-on-cafe-sign-in-ios")
        XCTAssertEqual(IssueWorkspace.slug("日本語"), "")
        XCTAssertEqual(IssueWorkspace.branchName(key: "ENG-1", title: "???", tracker: .linear), "eng-1")
    }

    func testBranchNamesAreCappedAtAWordAndNeverEndInADash() {
        let name = IssueWorkspace.branchName(
            key: "ENG-12", title: "Fix the login screen crash when the keyboard is dismissed during biometric prompt",
            tracker: .linear)
        XCTAssertLessThanOrEqual(name.count, IssueWorkspace.maxBranchLength)
        XCTAssertEqual(name, "eng-12-fix-the-login-screen-crash-when-the-keyboard-is")
        XCTAssertFalse(name.hasSuffix("-"))
    }

    func testSanitizingMakesValidRefs() {
        XCTAssertEqual(IssueWorkspace.sanitizeRef("a b..c"), "a-b.c")
        XCTAssertEqual(IssueWorkspace.sanitizeRef("/feat//x.lock/"), "feat/x")
        XCTAssertEqual(IssueWorkspace.sanitizeRef("x@{y}~^:?*[z\u{7}"), "x-y}-z")
        XCTAssertEqual(IssueWorkspace.sanitizeRef("trail..."), "trail")
        XCTAssertEqual(IssueWorkspace.sanitizeRef("a--b---c"), "a-b-c")
    }

    func testTakenNamesGetANumber() {
        XCTAssertEqual(IssueWorkspace.uniqueBranch("eng-1-x", existing: ["main"]), "eng-1-x")
        XCTAssertEqual(IssueWorkspace.uniqueBranch("eng-1-x", existing: ["eng-1-x"]), "eng-1-x-2")
        XCTAssertEqual(IssueWorkspace.uniqueBranch("eng-1-x", existing: ["eng-1-x", "eng-1-x-2"]), "eng-1-x-3")
    }

    func testFindsWhereABranchIsCheckedOut() {
        let porcelain = """
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /wt/repo/eng-1-x
        HEAD def
        branch refs/heads/eng-1-x

        worktree /wt/repo/detached
        HEAD 123
        detached
        """
        XCTAssertEqual(IssueWorkspace.worktreePath(forBranch: "eng-1-x", porcelain: porcelain), "/wt/repo/eng-1-x")
        XCTAssertEqual(IssueWorkspace.worktreePath(forBranch: "main", porcelain: porcelain), "/repo")
        XCTAssertNil(IssueWorkspace.worktreePath(forBranch: "eng-1", porcelain: porcelain))
    }

    func testPromptCarriesTheIssueAndTheAsk() {
        let prompt = IssueWorkspace.prompt(key: "ENG-12", title: "Fix login", url: URL(string: "https://linear.app/x/issue/ENG-12"),
                                           labels: ["bug", "auth"], body: "Login fails.\n\nSteps: 1")
        let lines = prompt.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Work on ENG-12: Fix login")
        XCTAssertEqual(lines[1], "https://linear.app/x/issue/ENG-12")
        XCTAssertEqual(lines[2], "Labels: bug, auth")
        XCTAssertTrue(prompt.contains("Login fails.\n\nSteps: 1"))
        XCTAssertTrue(prompt.hasSuffix("the worktree and branch are already set up."))
    }

    func testPromptLeavesOutWhatTheIssueLacks() {
        let prompt = IssueWorkspace.prompt(key: "#1", title: "T", url: nil, labels: [], body: "  \n")
        XCTAssertEqual(prompt, "Work on #1: T\n\nCreate a branch-appropriate fix; the worktree and branch are already set up.")
    }

    func testLongDescriptionsAreCutAndSaySo() {
        let prompt = IssueWorkspace.prompt(key: "#1", title: "T", url: nil, labels: [],
                                           body: String(repeating: "x", count: IssueWorkspace.maxBodyLength + 50))
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: IssueWorkspace.maxBodyLength) + "\n[description truncated]"))
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: IssueWorkspace.maxBodyLength + 1)))
    }

    func testPicksTheAgent() {
        func agent(_ id: String, installed: Bool = true) -> DiscoveredAgent {
            DiscoveredAgent(id: id, displayName: id, executablePath: installed ? "/bin/\(id)" : nil, command: id)
        }
        let all = [agent("pi"), agent("codex"), agent("claude")]
        XCTAssertEqual(IssueWorkspace.agent(preferred: nil, among: all)?.id, "claude")
        XCTAssertEqual(IssueWorkspace.agent(preferred: "codex", among: all)?.id, "codex")
        XCTAssertEqual(IssueWorkspace.agent(preferred: nil, among: [agent("pi"), agent("codex")])?.id, "codex")
        XCTAssertNil(IssueWorkspace.agent(preferred: "pi", among: all))
        XCTAssertNil(IssueWorkspace.agent(preferred: nil, among: [agent("claude", installed: false)]))
    }
}
