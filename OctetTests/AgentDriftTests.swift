import XCTest

final class AgentDriftTests: XCTestCase {
    /// Repositories at `/web` and `/api`; `/tmp` is in none.
    private func gitRoot(_ path: String) -> String? {
        ["/web", "/api"].first { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func claudeLine(_ command: String) -> String {
        let entry: [String: Any] = ["type": "assistant", "cwd": "/web", "message": ["content": [
            ["type": "tool_use", "name": "Bash", "input": ["command": command]],
        ]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    private func codexLine(_ arguments: [String: Any]) -> String {
        let raw = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let entry: [String: Any] = ["type": "response_item", "payload": ["type": "function_call", "name": "shell", "arguments": raw]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    func testLeadingCdIsWhereACommandRuns() {
        XCTAssertEqual(AgentDrift.directory(of: "cd /api && npm test", workdir: nil, base: "/web"), "/api")
        XCTAssertEqual(AgentDrift.directory(of: "cd \"/api/my app\"; ls", workdir: nil, base: "/web"), "/api/my app")
        XCTAssertEqual(AgentDrift.directory(of: "cd ../api && ls", workdir: nil, base: "/web"), "/api")
        XCTAssertEqual(AgentDrift.directory(of: "cd src", workdir: nil, base: "/web"), "/web/src")
        XCTAssertNil(AgentDrift.directory(of: "npm test", workdir: nil, base: "/web"))
        XCTAssertNil(AgentDrift.directory(of: "cd - && ls", workdir: nil, base: "/web"))
        XCTAssertEqual(AgentDrift.directory(of: "ls", workdir: "/api", base: "/web"), "/api")
        XCTAssertEqual(AgentDrift.directory(of: "cd src && ls", workdir: "/api", base: "/web"), "/api/src")
    }

    func testTargetsReadClaudeAndCodexTranscripts() {
        let lines = [
            claudeLine("cd /api && swift build"),
            codexLine(["command": ["bash", "-lc", "cd /api/Sources && ls"]]),
            codexLine(["cmd": "git status", "workdir": "/api"]),
            "not json",
            claudeLine("git status"),
        ]
        XCTAssertEqual(AgentDrift.targets(transcript: lines, base: "/web"), ["/api", "/api/Sources", "/api"])
    }

    func testThreeCommandsInAnotherRepositoryAreADestination() {
        XCTAssertEqual(AgentDrift.destination(targets: ["/api", "/api/src", "/api"], launchCwd: "/web", gitRoot: gitRoot), "/api")
    }

    func testFewerOrMixedCommandsAreNot() {
        XCTAssertNil(AgentDrift.destination(targets: ["/api", "/api"], launchCwd: "/web", gitRoot: gitRoot))
        XCTAssertNil(AgentDrift.destination(targets: ["/api", "/web", "/api"], launchCwd: "/web", gitRoot: gitRoot))
        // Only the last few count: it has come back.
        XCTAssertNil(AgentDrift.destination(targets: ["/api", "/api", "/api", "/web/src"], launchCwd: "/web", gitRoot: gitRoot))
    }

    func testTheSameProjectOrNoRepositoryIsNot() {
        XCTAssertNil(AgentDrift.destination(targets: ["/web/a", "/web/b", "/web"], launchCwd: "/web/a", gitRoot: gitRoot))
        XCTAssertNil(AgentDrift.destination(targets: ["/tmp", "/tmp", "/tmp"], launchCwd: "/web", gitRoot: gitRoot))
    }
}
