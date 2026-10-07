import XCTest

final class RecapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func tool(_ id: String, _ name: String, input: [String: Any] = [:], error: Bool = false, at offset: TimeInterval = 0) -> AgentItem {
        let data = try? JSONSerialization.data(withJSONObject: input)
        return AgentItem(id: id, kind: .tool(AgentToolCall(name: name, summary: "", input: "", inputData: data, isError: error)),
                         createdAt: start.addingTimeInterval(offset))
    }

    private func text(_ id: String, _ body: String, at offset: TimeInterval = 0, parent: String? = nil) -> AgentItem {
        AgentItem(id: id, kind: .text(body), parent: parent, createdAt: start.addingTimeInterval(offset))
    }

    private func now(_ items: [AgentItem], running: Bool = false, error: String? = nil, waiting: String? = nil) -> Recap.ConversationNow {
        Recap.ConversationNow(id: "s1", agent: "claude", title: "Fix login", workspaceId: "w1", items: items,
                              isRunning: running, lastError: error, waitingOn: waiting)
    }

    func testAFinishedConversationSaysWhatItChangedAndSaidLast() throws {
        let before = [AgentItem(id: "u1", kind: .user("fix the login bug"))]
        let mark = Recap.ConversationMark(itemIds: Set(before.map(\.id)), wasRunning: true, lastError: nil)
        let items = before + [
            tool("t1", "Read", input: ["file_path": "/r/a.swift"], at: 0),
            tool("t2", "Edit", input: ["file_path": "/r/a.swift"], at: 60),
            tool("t3", "Edit", input: ["file_path": "/r/a.swift"], at: 120),
            tool("t4", "Write", input: ["file_path": "/r/b.swift"], at: 180),
            tool("t5", "Bash", input: ["command": "swift test"], at: 240),
            tool("t6", "Bash", input: ["command": "swift test"], error: true, at: 300),
            text("m0", "A subagent's note", at: 330, parent: "t9"),
            text("m1", "Fixed the token refresh.\n\nThe session now renews before it expires.", at: 360),
        ]
        let run = try XCTUnwrap(Recap.run(now(items), since: mark))
        XCTAssertEqual(run.outcome, .finished)
        XCTAssertEqual(run.files, ["/r/a.swift", "/r/b.swift"])
        XCTAssertEqual(run.commands, 2)
        XCTAssertEqual(run.failedTools, 1)
        XCTAssertEqual(run.turns, 1)
        XCTAssertEqual(run.workedFor, 360)
        XCTAssertEqual(run.lastMessage, "Fixed the token refresh.")
        XCTAssertEqual(run.summary, "Edited 2 files · ran 2 commands · 1 failed · worked 6m")
        XCTAssertEqual(run.source, .conversation("s1"))
    }

    func testWaitingOnYouAndErrorsComeFirst() throws {
        let mark = Recap.ConversationMark(itemIds: [], wasRunning: true, lastError: nil)
        let waiting = try XCTUnwrap(Recap.run(now([], running: true, waiting: "Asks to run Bash: rm -rf build"), since: mark))
        XCTAssertEqual(waiting.outcome, .needsYou)
        XCTAssertEqual(waiting.reason, "Asks to run Bash: rm -rf build")

        let stuck = try XCTUnwrap(Recap.run(now([text("m", "Trying")], error: "API Error: 529 overloaded"), since: mark))
        XCTAssertEqual(stuck.outcome, .stuck)
        XCTAssertEqual(stuck.reason, "API Error: 529 overloaded")

        // The same error it already had when you left isn't news.
        let old = Recap.ConversationMark(itemIds: [], wasRunning: false, lastError: "old")
        XCTAssertNil(Recap.run(now([], error: "old"), since: old))
    }

    func testQuietConversationsAreLeftOut() throws {
        let items = [AgentItem(id: "u1", kind: .user("hi")), text("m1", "Hello")]
        let mark = Recap.ConversationMark(itemIds: Set(items.map(\.id)), wasRunning: false, lastError: nil)
        XCTAssertNil(Recap.run(now(items), since: mark))
        // Working when you left, still working, nothing new: nothing to say yet.
        let busy = Recap.ConversationMark(itemIds: Set(items.map(\.id)), wasRunning: true, lastError: nil)
        XCTAssertNil(Recap.run(now(items, running: true), since: busy))
        // Working, with new steps: still working.
        let more = items + [tool("t1", "Bash", input: ["command": "make"])]
        XCTAssertEqual(Recap.run(now(more, running: true), since: busy)?.outcome, .working)
        // It finished with nothing new drawn: still a finish.
        XCTAssertEqual(Recap.run(now(items), since: busy)?.outcome, .finished)
    }

    func testEditedPathsFromEveryAgentsTools() {
        func call(_ name: String, _ input: [String: Any], summary: String = "") -> AgentToolCall {
            AgentToolCall(name: name, summary: summary, input: "", inputData: try? JSONSerialization.data(withJSONObject: input))
        }
        XCTAssertEqual(Recap.editedPaths(call("Edit", ["file_path": "/a"])), ["/a"])
        XCTAssertEqual(Recap.editedPaths(call("NotebookEdit", ["notebook_path": "/n.ipynb"])), ["/n.ipynb"])
        XCTAssertEqual(Recap.editedPaths(call("Edit", ["changes": [["path": "/x"], ["path": "/y"]]])), ["/x", "/y"])
        let patch = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n*** Add File: src/b.ts\n*** End Patch"
        XCTAssertEqual(Recap.editedPaths(call("ApplyPatch", ["patch": patch])), ["src/a.ts", "src/b.ts"])
        XCTAssertEqual(Recap.editedPaths(call("Read", ["file_path": "/a"])), [])
        var failed = call("Edit", ["file_path": "/a"])
        failed.isError = true
        XCTAssertEqual(Recap.editedPaths(failed), [])
    }

    func testExcerptKeepsTheFirstParagraphShort() {
        XCTAssertEqual(Recap.excerpt("One.\nTwo.\n\nThree."), "One. Two.")
        let long = String(repeating: "word ", count: 80)
        let cut = Recap.excerpt(long, limit: 40)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 41)
    }

    // MARK: - Terminal agents

    private func snapshot(_ statuses: [String: EngineAgentStatus]) -> EngineSnapshot {
        let tabs = statuses.keys.sorted().enumerated().map { index, pane in
            EngineTab(tabId: "t-\(pane)", workspaceId: "w1", number: index + 1, label: pane == "p1" ? "api server" : "",
                      focused: false, paneCount: 1, agentStatus: .idle)
        }
        let agents = statuses.map { pane, status in
            EngineAgent(paneId: pane, tabId: "t-\(pane)", workspaceId: "w1", agent: "claude", name: nil,
                        displayAgent: nil, agentStatus: status)
        }
        return EngineSnapshot(workspaces: [], tabs: tabs, panes: [], agents: agents,
                              focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil)
    }

    func testTerminalAgentsByTheirStatusChanges() {
        var log = Recap.TerminalLog()
        log.observe(snapshot(["p1": .working, "p2": .idle, "p3": .working, "p4": .working]), now: start)
        log.observe(snapshot(["p1": .done, "p2": .idle, "p3": .working, "p4": .blocked]), now: start.addingTimeInterval(600))
        let runs = Dictionary(uniqueKeysWithValues: log.runs(now: start.addingTimeInterval(900)).map { ($0.id, $0) })

        XCTAssertEqual(runs["terminal-p1"]?.outcome, .finished)
        XCTAssertEqual(runs["terminal-p1"]?.workedFor, 600)
        XCTAssertEqual(runs["terminal-p1"]?.title, "api server")
        XCTAssertEqual(runs["terminal-p1"]?.turns, 1)
        // Idle all along, or working all along: nothing to report.
        XCTAssertNil(runs["terminal-p2"])
        XCTAssertNil(runs["terminal-p3"])
        XCTAssertEqual(runs["terminal-p4"]?.outcome, .needsYou)
        // An unnamed tab is called after its agent.
        XCTAssertEqual(runs["terminal-p4"]?.title, "Claude Code")
    }

    func testRecapReadsNeedsYouFirst() {
        func run(_ id: String, _ outcome: Recap.Outcome) -> Recap.Run {
            Recap.Run(id: id, source: .conversation(id), agent: nil, title: id, workspaceId: nil, outcome: outcome)
        }
        let recap = Recap(leftAt: start, cameBackAt: start.addingTimeInterval(3600),
                          runs: Recap.ordered([run("b", .finished), run("a", .working), run("c", .needsYou), run("d", .finished)]))
        XCTAssertEqual(recap.runs.map(\.id), ["c", "b", "d", "a"])
        XCTAssertEqual(recap.headline, "1 needs you, 2 finished, 1 still working")
        XCTAssertEqual(recap.away, 3600)
        XCTAssertTrue(recap.isWorthShowing)
        XCTAssertFalse(Recap(leftAt: start, cameBackAt: start, runs: []).isWorthShowing)
    }
}
