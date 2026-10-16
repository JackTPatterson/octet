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
}
