import XCTest

final class WorkspaceAutoNameTests: XCTestCase {
    func testAPromptBecomesAShortTopic() {
        XCTAssertEqual(WorkspaceAutoName.topic("can you fix the login redirect bug on safari, it loops forever"),
                       "Fix the login redirect bug…")
        XCTAssertEqual(WorkspaceAutoName.topic("lets add dark mode to settings"), "Add dark mode to settings")
        XCTAssertEqual(WorkspaceAutoName.topic("please, now refactor the parser."), "Refactor the parser")
        XCTAssertEqual(WorkspaceAutoName.topic("history page is blank"), "History page is blank")
    }

    func testNothingWorthNamingIsNil() {
        XCTAssertNil(WorkspaceAutoName.topic("/compact"))
        XCTAssertNil(WorkspaceAutoName.topic("ok"))
        XCTAssertNil(WorkspaceAutoName.topic("claude"))
        XCTAssertNil(WorkspaceAutoName.topic("~/code/octet"))
    }

    func testBranchNames() {
        XCTAssertEqual(WorkspaceAutoName.branchName("feat/login-redesign"), "Login redesign")
        XCTAssertEqual(WorkspaceAutoName.branchName("jack/ENG-142-retry-backoff"), "ENG-142 retry backoff")
        XCTAssertEqual(WorkspaceAutoName.branchName("fix_typo"), "Fix typo")
        XCTAssertNil(WorkspaceAutoName.branchName("main"))
        XCTAssertNil(WorkspaceAutoName.branchName("origin/master"))
    }

    func testAgentsBeatTheConversationWhichBeatsTheBranch() {
        typealias S = WorkspaceAutoName.Signals
        XCTAssertEqual(WorkspaceAutoName.name(for: S(agentTitles: ["Fixing flaky tests"], chatTitle: "add docs", branch: "feat/x-y")),
                       "Fixing flaky tests")
        XCTAssertEqual(WorkspaceAutoName.name(for: S(agentTitles: [], chatTitle: "add docs", branch: "feat/x-y")), "Add docs")
        XCTAssertEqual(WorkspaceAutoName.name(for: S(agentTitles: [], chatTitle: nil, branch: "feat/search-index")), "Search index")
        XCTAssertNil(WorkspaceAutoName.name(for: S(agentTitles: [], chatTitle: nil, branch: "main")))
    }

    func testOnlyNamesOctetOrTheServerGaveAreReplaced() {
        XCTAssertTrue(WorkspaceAutoName.isAutomatic("3", folder: "/a/octet", previous: nil))
        XCTAssertTrue(WorkspaceAutoName.isAutomatic("Octet", folder: "/a/octet", previous: nil))
        XCTAssertTrue(WorkspaceAutoName.isAutomatic("Fix bug", folder: "/a/octet", previous: "Fix bug"))
        XCTAssertFalse(WorkspaceAutoName.isAutomatic("API work", folder: "/a/octet", previous: nil))
    }

    func testANameHasToHoldStillAndManualNamesStay() {
        let start = Date()
        var pending: [String: WorkspaceAutoName.Candidate] = [:]
        let working = WorkspaceAutoName.Subject(workspaceId: "w1", label: "octet", folder: "/a/octet",
                                                signals: .init(agentTitles: ["Fix login"]))
        XCTAssertTrue(WorkspaceAutoName.renames([working], manual: [], named: [:], pending: &pending, now: start).isEmpty)
        let later = WorkspaceAutoName.renames([working], manual: [], named: [:], pending: &pending, now: start.addingTimeInterval(7))
        XCTAssertEqual(later.map(\.label), ["Fix login"])

        var fresh: [String: WorkspaceAutoName.Candidate] = [:]
        _ = WorkspaceAutoName.renames([working], manual: ["w1"], named: [:], pending: &fresh, now: start)
        XCTAssertTrue(WorkspaceAutoName.renames([working], manual: ["w1"], named: [:], pending: &fresh,
                                                now: start.addingTimeInterval(7)).isEmpty)

        // A name Octet gave may change again as the work does.
        let moved = WorkspaceAutoName.Subject(workspaceId: "w1", label: "Old task", folder: "/a/octet",
                                              signals: .init(agentTitles: ["New task"]))
        var again: [String: WorkspaceAutoName.Candidate] = [:]
        _ = WorkspaceAutoName.renames([moved], manual: [], named: ["w1": "Old task"], pending: &again, now: start)
        XCTAssertEqual(WorkspaceAutoName.renames([moved], manual: [], named: ["w1": "Old task"], pending: &again,
                                                 now: start.addingTimeInterval(7)).map(\.label), ["New task"])
    }
}
