import XCTest

final class HandoffBriefTests: XCTestCase {
    private func user(_ id: String, _ text: String) -> AgentItem { AgentItem(id: id, kind: .user(text)) }
    private func said(_ id: String, _ text: String, parent: String? = nil) -> AgentItem { AgentItem(id: id, kind: .text(text), parent: parent) }

    private func tool(_ id: String, _ name: String, _ input: [String: Any], failed: Bool = false) -> AgentItem {
        AgentItem(id: id, kind: .tool(AgentToolCall(name: name, summary: "", input: "",
                                                    inputData: try? JSONSerialization.data(withJSONObject: input),
                                                    result: "ok", isError: failed)))
    }

    private var items: [AgentItem] {
        [user("u1", "Fix the login bug where the token never refreshes."),
         tool("t1", "Read", ["file_path": "/r/app/Auth.swift"]),
         tool("t2", "Edit", ["file_path": "/r/app/Auth.swift"]),
         tool("t3", "Edit", ["file_path": "/r/app/Auth.swift"]),
         tool("t4", "Write", ["file_path": "/r/app/Refresh.swift"]),
         tool("t5", "Bash", ["command": "swift test"], failed: true),
         said("s1", "A subagent's side note", parent: "t9"),
         said("m1", "The refresh now runs before expiry, but one test still fails.\n\nI was looking at the clock.")]
    }

    func testTheBriefSaysWhatHappened() {
        let text = HandoffBrief.build(.init(agentName: "Claude Code", cwd: "/r", branch: "fix/login", items: items, reason: .limit))
        XCTAssertTrue(text.hasPrefix("Carrying on work started in Claude Code in /r on fix/login. That conversation stopped because it hit its usage limit."), text)
        XCTAssertTrue(text.contains("## What was asked\n- Fix the login bug where the token never refreshes."))
        XCTAssertTrue(text.contains("## Where it got to\nThe refresh now runs before expiry, but one test still fails."))
        // Not a subagent's words.
        XCTAssertFalse(text.contains("side note"))
        XCTAssertTrue(text.contains("- app/Auth.swift (2 edits)\n- app/Refresh.swift"))
        XCTAssertTrue(text.contains("- `swift test` (failed)"))
        XCTAssertTrue(text.contains("## Checks\nTests failed after the last edit."))
        XCTAssertTrue(text.hasSuffix("Don't redo what's already done."))
    }

    func testReasonsOpenDifferently() {
        func opening(_ reason: HandoffBrief.Reason) -> String {
            HandoffBrief.build(.init(agentName: "Codex", cwd: "/r", items: items, reason: reason)).components(separatedBy: "\n").first ?? ""
        }
        XCTAssertEqual(opening(.switching(from: "Codex")), "Carrying on work started in Codex in /r.")
        XCTAssertTrue(opening(.fresh).contains("starts clean with a summary"))
    }

    func testEmptySectionsAreLeftOut() {
        let text = HandoffBrief.build(.init(agentName: "Claude Code", cwd: "/r", items: [user("u", "Hello")], reason: .fresh))
        XCTAssertFalse(text.contains("## Files it changed"))
        XCTAssertFalse(text.contains("## The last commands"))
        XCTAssertFalse(text.contains("## Checks"))
        XCTAssertFalse(text.contains("## Where it got to"))
        XCTAssertTrue(text.contains("## What was asked"))
    }

    func testALongConversationKeepsTheFirstAndTheLastRequests() {
        let many = (1...10).map { user("u\($0)", "request \($0)") }
        XCTAssertEqual(HandoffBrief.requests(in: many), ["request 1", "request 6", "request 7", "request 8", "request 9", "request 10"])
        XCTAssertEqual(HandoffBrief.requests(in: Array(many.prefix(3))), ["request 1", "request 2", "request 3"])
        // Commands to the app, and blanks, aren't requests.
        XCTAssertEqual(HandoffBrief.requests(in: [user("a", "/compact"), user("b", "  "), user("c", "do it")]), ["do it"])
    }

    func testItNeverGrowsPastTheLimit() {
        var big = items
        big.append(said("long", String(repeating: "word ", count: 5000)))
        for index in 0..<200 { big.append(tool("e\(index)", "Edit", ["file_path": "/r/f\(index).swift"])) }
        let text = HandoffBrief.build(.init(agentName: "Claude Code", cwd: "/r", items: big, reason: .limit))
        XCTAssertLessThanOrEqual(text.count, HandoffBrief.limit + 1)
        XCTAssertTrue(HandoffBrief.changedFiles(in: big, cwd: "/r").count > 25)
    }

    func testClipsAtAWord() {
        XCTAssertEqual(HandoffBrief.clip("one two three", 100), "one two three")
        XCTAssertEqual(HandoffBrief.clip("one two three four", 9), "one two…")
        XCTAssertEqual(HandoffBrief.relative("/r/app/a.swift", to: "/r"), "app/a.swift")
        XCTAssertEqual(HandoffBrief.relative("/elsewhere/a.swift", to: "/r"), "/elsewhere/a.swift")
        XCTAssertEqual(HandoffBrief.abbreviate(NSHomeDirectory() + "/Developer/x"), "~/Developer/x")
    }
}
