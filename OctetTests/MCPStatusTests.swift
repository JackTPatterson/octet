import XCTest

final class MCPStatusTests: XCTestCase {
    func testClaudeCodesAnswerAsTheCLIGivesIt() {
        // From Claude Code 2.1.285's mcp_status, with Octet's own server.
        let servers = MCPServerState.list([
            ["name": "broken", "status": "failed", "error": "ENOENT: no such file or directory", "scope": "dynamic"],
            ["name": "octet", "status": "connected"],
            ["name": "Linear", "status": "needs-auth"],
        ])
        XCTAssertEqual(servers.map(\.name), ["broken", "Linear"], "Octet's own permission server is hidden")
        XCTAssertEqual(servers[0].status, .failed)
        XCTAssertEqual(servers[0].detail, "ENOENT: no such file or directory")
        XCTAssertEqual(servers[1].status, .needsAuth)
        XCTAssertTrue(servers.allSatisfy(\.status.isProblem))
    }

    func testCodexStatusList() {
        let servers = MCPServerState.codex(["data": [
            ["name": "docs", "runtimeStatus": "connected", "tools": ["search": [:], "fetch": [:]]],
            ["name": "gh", "runtimeStatus": "authenticationRequired"],
            ["name": "db", "runtimeStatus": "failed", "toolsError": "timed out"],
        ], "nextCursor": NSNull()])
        XCTAssertEqual(servers.map(\.name), ["db", "docs", "gh"])
        XCTAssertEqual(servers.map(\.status), [.failed, .connected, .needsAuth])
        XCTAssertEqual(servers[0].detail, "timed out")
        XCTAssertEqual(servers[1].detail, "2 tools")
    }

    func testOpenCodeStatusMap() {
        let servers = MCPServerState.openCode([
            "fs": ["status": "connected"],
            "jira": ["status": "needs_auth"],
            "old": ["status": "disabled"],
            "bad": ["status": "failed", "error": "exit 1"],
        ])
        XCTAssertEqual(servers.map(\.status), [.failed, .connected, .needsAuth, .disabled])
        XCTAssertEqual(servers.first?.detail, "exit 1")
    }

    func testAnInitEventCarriesTheServers() {
        var conversation = AgentConversation()
        conversation.apply(["type": "system", "subtype": "init", "session_id": "s",
                            "mcp_servers": [["name": "docs", "status": "connected"], ["name": "octet", "status": "connected"]]])
        XCTAssertEqual(conversation.mcpServers, [MCPServerState(name: "docs", status: .connected)])
    }
}
