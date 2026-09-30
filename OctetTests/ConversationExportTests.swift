import XCTest

final class ConversationExportTests: XCTestCase {
    func testAConversationReadsAsMarkdown() {
        let items = [
            AgentItem(id: "1", kind: .user("Fix the login loop")),
            AgentItem(id: "2", kind: .thinking("hmm")),
            AgentItem(id: "3", kind: .tool(AgentToolCall(name: "Read", summary: "src/auth.ts", input: ""))),
            AgentItem(id: "4", kind: .tool(AgentToolCall(name: "Bash", summary: "npm `test`", input: "", isError: true))),
            AgentItem(id: "5", kind: .text("Fixed: the redirect checked the wrong cookie.")),
            AgentItem(id: "6", kind: .tool(AgentToolCall(name: "Read", summary: "inner", input: "")), parent: "task"),
            AgentItem(id: "7", kind: .notice("Stopped")),
        ]
        let date = Date(timeIntervalSince1970: 0)
        let text = ConversationExport.markdown(title: "Login loop", agent: "Claude", cwd: nil, items: items, date: date)
        XCTAssertTrue(text.hasPrefix("# Login loop\n\n_Claude · "))
        XCTAssertTrue(text.contains("## You\n\nFix the login loop\n\n## Claude\n\n- **Read** `src/auth.ts`\n- **Bash** `npm 'test'` (failed)\n\nFixed: the redirect checked the wrong cookie.\n\n> Stopped\n"))
        XCTAssertFalse(text.contains("hmm"), "thinking is left out")
        XCTAssertFalse(text.contains("inner"), "subagents' inner steps are left out")
    }
}
