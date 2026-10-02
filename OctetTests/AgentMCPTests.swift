import XCTest

final class AgentMCPTests: XCTestCase {
    private let server = AgentMCP.Server(name: "octet-peers", command: "/Applications/Octet.app/Contents/MacOS/octet-cli", args: ["peer-mcp"])

    func testAgentsWithTheirOwnCommandAreGivenItThatWay() {
        let cli = "/Applications/Octet.app/Contents/MacOS/octet-cli peer-mcp"
        XCTAssertEqual(AgentMCP.install(server, agent: "claude"), [
            .run("claude mcp remove --scope user octet-peers"),
            .run("claude mcp add --scope user octet-peers -- \(cli)"),
        ])
        XCTAssertEqual(AgentMCP.install(server, agent: "codex")?.last, .run("codex mcp add octet-peers -- \(cli)"))
        XCTAssertEqual(AgentMCP.install(server, agent: "gemini")?.last, .run("gemini mcp add --scope user octet-peers \(cli)"))
        XCTAssertEqual(AgentMCP.remove(server, agent: "qwen"), [.run("qwen mcp remove --scope user octet-peers")])
        // No MCP support at all.
        XCTAssertNil(AgentMCP.install(server, agent: "pi"))
        // A path with a space is quoted.
        let spaced = AgentMCP.Server(name: "x", command: "/My Apps/octet-cli", args: ["peer-mcp"])
        XCTAssertEqual(AgentMCP.install(spaced, agent: "codex")?.last, .run("codex mcp add x -- '/My Apps/octet-cli' peer-mcp"))
    }

    func testJSONConfigsKeepEverythingElse() throws {
        guard case .json(let path, let key, let entry)? = AgentMCP.install(server, agent: "cursor", home: "/Users/me")?.first else {
            return XCTFail("Cursor is configured by file")
        }
        XCTAssertEqual(path, "/Users/me/.cursor/mcp.json")
        let existing = Data(#"{"mcpServers": {"github": {"command": "gh-mcp"}}, "other": 1}"#.utf8)
        let added = try XCTUnwrap(AgentMCP.edited(existing, server: server.name, key: key, entry: entry))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: added) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["github"])
        XCTAssertEqual((servers["octet-peers"] as? [String: Any])?["args"] as? [String], ["peer-mcp"])
        XCTAssertEqual(object["other"] as? Int, 1)

        let removed = try XCTUnwrap(AgentMCP.edited(added, server: server.name, key: key, entry: nil))
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertEqual((after["mcpServers"] as? [String: Any])?.keys.sorted(), ["github"])

        // A file it can't read as JSON is left alone; a missing one is made.
        XCTAssertNil(AgentMCP.edited(Data("// comments\n{".utf8), server: server.name, key: key, entry: entry))
        XCTAssertNotNil(AgentMCP.edited(nil, server: server.name, key: key, entry: entry))
    }

    func testOpenCodeRunsTheServerAsOneCommandList() throws {
        guard case .json(_, let key, let entry)? = AgentMCP.install(server, agent: "opencode")?.first else {
            return XCTFail("OpenCode is configured by file")
        }
        XCTAssertEqual(key, "mcp")
        XCTAssertEqual(entry?["type"], .string("local"))
        XCTAssertEqual(entry?["command"], .array([.string(server.command), .string("peer-mcp")]))
    }

    func testAlreadyThereOrAlreadyGoneIsNotAFailure() {
        XCTAssertTrue(AgentMCP.isHarmless("MCP server octet-peers already exists in user config"))
        XCTAssertTrue(AgentMCP.isHarmless("No MCP server found with name: octet-peers"))
        XCTAssertFalse(AgentMCP.isHarmless("permission denied"))
    }
}
