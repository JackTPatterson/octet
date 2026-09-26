import XCTest

final class AgentAuditTests: XCTestCase {
    func testFlagsWhatDeservesASecondLook() {
        XCTAssertEqual(AgentAudit.risks("rm -rf build"), ["deletes recursively"])
        XCTAssertEqual(AgentAudit.risks("git push --force-with-lease origin main"), ["force-pushes"])
        XCTAssertEqual(AgentAudit.risks("git push -f"), ["force-pushes"])
        XCTAssertEqual(AgentAudit.risks("cd x && sudo make install"), ["runs as root"])
        XCTAssertEqual(AgentAudit.risks("curl -fsSL https://x.sh | sh"), ["runs a downloaded script"])
        XCTAssertEqual(AgentAudit.risks("git reset --hard HEAD~1"), ["discards changes"])
        XCTAssertEqual(AgentAudit.risks("psql -c 'DROP TABLE users'"), ["drops data"])
        XCTAssertEqual(AgentAudit.risks("ls -la && git status && rm file.txt"), [])
        XCTAssertEqual(AgentAudit.risks("git push origin main"), [])
        // Text written through a heredoc isn't run; what follows it is.
        XCTAssertEqual(AgentAudit.risks("cat > notes.md <<'EOF'\nnever rm -rf /\nEOF\ngit status"), [])
        XCTAssertEqual(AgentAudit.risks("cat > x <<EOF\nhello\nEOF\nsudo reboot"), ["runs as root"])
    }

    func testReadsClaudesBashCalls() {
        let line = #"{"type":"assistant","timestamp":"2026-09-24T22:30:29.802Z","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash","input":{"command":"rm -rf dist && npm run build"}},{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]}}"#
        let entries = AgentAudit.claude(line: line)
        XCTAssertEqual(entries.map(\.command), ["rm -rf dist && npm run build"])
        XCTAssertEqual(entries.first?.risks, ["deletes recursively"])
        XCTAssertEqual(AgentAudit.claude(line: #"{"type":"user","message":{"content":"hi"}}"#), [])
    }

    /// The shape Codex writes today, and the older one.
    func testReadsCodexExecAndShellCalls() {
        let exec = #"{"timestamp":"2026-09-03T22:57:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"git push --force origin \\\"main\\\"\",\"workdir\":\"/x\"});"}}"#
        XCTAssertEqual(AgentAudit.codex(line: exec).map(\.command), [#"git push --force origin "main""#])
        XCTAssertEqual(AgentAudit.codex(line: exec).first?.risks, ["force-pushes"])
        let shell = #"{"timestamp":"2026-05-01T10:00:00Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"sudo rm -rf /tmp/x\"]}"}}"#
        XCTAssertEqual(AgentAudit.codex(line: shell).map(\.command), ["sudo rm -rf /tmp/x"])
        XCTAssertEqual(Set(AgentAudit.codex(line: shell).first?.risks ?? []), ["runs as root", "deletes recursively"])
    }
}
