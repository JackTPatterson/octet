import XCTest

final class CloudAgentsTests: XCTestCase {
    func testClaudeStartsACloudSessionWithTheTask() {
        XCTAssertEqual(CloudAgents.start(for: "claude"), .withTask)
        XCTAssertEqual(CloudAgents.arguments(for: "claude", task: "  Fix the login bug \n"), ["--cloud", "Fix the login bug"])
        XCTAssertNil(CloudAgents.arguments(for: "claude", task: "   "))
        XCTAssertNil(CloudAgents.arguments(for: "claude", task: nil))
    }

    func testCodexOpensItsCloudTasks() {
        XCTAssertEqual(CloudAgents.start(for: "codex"), .browser)
        XCTAssertEqual(CloudAgents.arguments(for: "codex", task: nil), ["cloud"])
    }

    func testOtherAgentsHaveNoCloud() {
        XCTAssertNil(CloudAgents.start(for: "opencode"))
        XCTAssertNil(CloudAgents.arguments(for: "opencode", task: "x"))
    }

    func testTabLabelIsTheShortenedTask() {
        XCTAssertEqual(CloudAgents.tabLabel(agentName: "Claude Code", task: "Fix it\nwith more"), "☁ Fix it")
        XCTAssertEqual(CloudAgents.tabLabel(agentName: "Claude Code", task: String(repeating: "a", count: 40)),
                       "☁ " + String(repeating: "a", count: 31) + "…")
        XCTAssertEqual(CloudAgents.tabLabel(agentName: "Codex", task: nil), "Codex Cloud")
    }
}
