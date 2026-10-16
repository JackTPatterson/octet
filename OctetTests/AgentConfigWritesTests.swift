import XCTest

final class AgentConfigWritesTests: XCTestCase {
    func testThrowawayCopiesNeverWriteAgentConfigs() {
        let none: [String: String] = [:]
        XCTAssertTrue(AgentConfigWrites.allowed(bundlePath: "/Applications/Octet.app", environment: none, temporaryDirectory: "/var/folders/x/T/"))
        XCTAssertTrue(AgentConfigWrites.allowed(bundlePath: "/Users/me/dev/octet/build/DerivedData/Build/Products/Debug/Octet.app",
                                                environment: none, temporaryDirectory: "/var/folders/x/T/"))
        XCTAssertFalse(AgentConfigWrites.allowed(bundlePath: "/private/tmp/claude-501/s/scratchpad/verify/Octet.app", environment: none))
        XCTAssertFalse(AgentConfigWrites.allowed(bundlePath: "/var/folders/x/T/copy/Octet.app", environment: none, temporaryDirectory: "/var/folders/x/T/"))
        XCTAssertFalse(AgentConfigWrites.allowed(bundlePath: "/Users/me/dev/octet/.claude/worktrees/agent-1/build/Octet.app", environment: none))
        XCTAssertFalse(AgentConfigWrites.allowed(bundlePath: "/Applications/Octet.app", environment: ["OCTET_NO_AGENT_CONFIG": "1"]))
    }

    func testLayoutRectsBecomeWindowFramesOnTheScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        let left = PaneLayoutNode.Rect(x: 0, y: 0, width: 0.5, height: 1).windowFrame(in: visible)
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 500, height: 800))
        let topRight = PaneLayoutNode.Rect(x: 0.5, y: 0, width: 0.5, height: 0.5).windowFrame(in: visible)
        XCTAssertEqual(topRight, CGRect(x: 500, y: 425, width: 500, height: 400))
    }
}
