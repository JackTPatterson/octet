import XCTest

final class SkillCallTests: XCTestCase {
    /// Claude Code's own `Skill` tool input.
    private let claude: [String: Any] = ["skill": "frontend-design", "args": "Give the settings page a calmer look\nand more"]

    func testTheRowIsTitledWithTheSkillsNameAndItsArgsAreTheLine() {
        let call = AgentToolCall(name: "Skill", summary: AgentConversation.toolSummary(name: "Skill", input: claude),
                                 input: "", inputData: try? JSONSerialization.data(withJSONObject: claude))
        XCTAssertEqual(call.displayName, "frontend-design")
        XCTAssertEqual(call.summary, "Give the settings page a calmer look")
        XCTAssertEqual(call.iconName, "sparkles")
    }

    func testASkillWithNoArgsOrNoInputYet() {
        XCTAssertEqual(AgentConversation.toolSummary(name: "Skill", input: ["skill": "commit"]), "")
        // Before the input has streamed in, the tool's own name stands in.
        XCTAssertEqual(AgentToolCall(name: "Skill", summary: "", input: "", inputData: nil).displayName, "Skill")
    }

    func testOpenCodesSkillAndSlashNames() {
        XCTAssertEqual(SkillCall.name(in: ["name": "pdf"]), "pdf")
        XCTAssertEqual(SkillCall.name(in: ["command": "/review"]), "review")
        XCTAssertNil(SkillCall.name(in: ["skill": "  "]))
        XCTAssertTrue(SkillCall.isSkill("skill"))
        XCTAssertFalse(SkillCall.isSkill("Bash"))
    }

    func testTheTwinWritesItTheWayClaudeCodeDoes() {
        XCTAssertEqual(TwinTranscript.toolSummary(name: "Skill", input: claude), "frontend-design")
        // Other tools are untouched.
        XCTAssertEqual(TwinTranscript.toolSummary(name: "Bash", input: ["command": "ls"]), "ls")
    }

    func testASubagentsViewerNamesTheSkill() {
        XCTAssertEqual(SubagentTranscriptRenderer.toolSummary(claude), "frontend-design")
    }
}
