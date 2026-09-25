import XCTest

final class BroadcastTests: XCTestCase {
    private func workspace(_ id: String, _ number: Int) -> EngineWorkspace {
        EngineWorkspace(workspaceId: id, number: number, label: id, focused: false, paneCount: 1, tabCount: 1,
                        activeTabId: "\(id):t1", agentStatus: .idle, worktree: nil)
    }

    private func tab(_ id: String, _ workspaceId: String, _ number: Int, _ label: String) -> EngineTab {
        EngineTab(tabId: id, workspaceId: workspaceId, number: number, label: label, focused: false,
                  paneCount: 1, agentStatus: .idle)
    }

    private func pane(_ id: String, tab: String, workspace: String) -> EnginePane {
        EnginePane(paneId: id, tabId: tab, workspaceId: workspace, focused: false, cwd: "/r",
                   foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil)
    }

    private func agent(_ pane: String, tab: String, workspace: String, _ kind: String?,
                       viewer: Bool = false) -> EngineAgent {
        var agent = EngineAgent(paneId: pane, tabId: tab, workspaceId: workspace, agent: kind, name: nil,
                                displayAgent: nil, agentStatus: .working)
        if viewer { agent.tokens = [PaneAgentReporter.roleToken: PaneAgentReporter.subagentRole] }
        return agent
    }

    /// Two workspaces: `api` with Claude and Codex in two tabs (plus a
    /// subagent viewer and a plain shell split beside Claude), `web` with
    /// OpenCode.
    private var snapshot: EngineSnapshot {
        EngineSnapshot(
            workspaces: [workspace("web", 2), workspace("api", 1)],
            tabs: [tab("api:t1", "api", 1, "server"), tab("api:t2", "api", 2, "tests"),
                   tab("api:t3", "api", 3, "reviewer"), tab("web:t1", "web", 1, "ui")],
            panes: [pane("api:p1", tab: "api:t1", workspace: "api"), pane("api:p2", tab: "api:t1", workspace: "api"),
                    pane("api:p3", tab: "api:t2", workspace: "api"), pane("api:p4", tab: "api:t3", workspace: "api"),
                    pane("web:p1", tab: "web:t1", workspace: "web")],
            agents: [agent("web:p1", tab: "web:t1", workspace: "web", "opencode"),
                     agent("api:p3", tab: "api:t2", workspace: "api", "codex"),
                     agent("api:p1", tab: "api:t1", workspace: "api", "claude"),
                     agent("api:p4", tab: "api:t3", workspace: "api", "claude", viewer: true)],
            focusedWorkspaceId: "api", focusedTabId: "api:t1", focusedPaneId: "api:p1"
        )
    }

    func testTabScopeReachesEveryPaneInTheTabShellsIncluded() {
        let targets = Broadcast.targets(.tab, in: snapshot, workspaceId: "api", tabId: "api:t1")
        XCTAssertEqual(targets.map(\.paneId), ["api:p1", "api:p2"])
        XCTAssertEqual(targets.map(\.isAgent), [true, false])
        XCTAssertEqual(targets.map(\.name), ["Claude Code in server", "server"])
    }

    func testWorkspaceScopeReachesItsAgentsInTabOrderButNotSubagentViewers() {
        let targets = Broadcast.targets(.workspace, in: snapshot, workspaceId: "api", tabId: "api:t1")
        XCTAssertEqual(targets.map(\.paneId), ["api:p1", "api:p3"])
        XCTAssertTrue(targets.allSatisfy(\.isAgent))
    }

    func testEverywhereFollowsWorkspaceOrder() {
        let targets = Broadcast.targets(.everywhere, in: snapshot, workspaceId: nil, tabId: nil)
        XCTAssertEqual(targets.map(\.paneId), ["api:p1", "api:p3", "web:p1"])
    }

    func testNothingInFrontMeansNoTargets() {
        XCTAssertEqual(Broadcast.targets(.tab, in: snapshot, workspaceId: "api", tabId: nil), [])
        XCTAssertEqual(Broadcast.targets(.workspace, in: snapshot, workspaceId: nil, tabId: nil), [])
        XCTAssertEqual(Broadcast.targets(.workspace, in: snapshot, workspaceId: "gone", tabId: nil), [])
    }

    func testSummaryNamesFewAndCountsMany() {
        let all = Broadcast.targets(.everywhere, in: snapshot, workspaceId: nil, tabId: nil)
        XCTAssertEqual(Broadcast.summary([]), "nothing")
        XCTAssertEqual(Broadcast.summary(Array(all.prefix(1))), "Claude Code in server")
        XCTAssertEqual(Broadcast.summary(Array(all.prefix(2))), "Claude Code in server and Codex in tests")
        XCTAssertEqual(Broadcast.summary(all), "3 agents")
        let mixed = Broadcast.targets(.tab, in: snapshot, workspaceId: "api", tabId: "api:t1")
        XCTAssertEqual(Broadcast.summary(mixed + mixed), "4 panes")
    }

    /// A session server stand-in that records calls and refuses the listed ones.
    private final class FakeServer {
        let lock = NSLock()
        var calls: [(method: String, pane: String, text: String)] = []
        var refuse: Set<String> = []

        func call(_ method: String, _ params: [String: Any]) throws {
            let pane = (params["target"] ?? params["pane_id"]) as? String ?? ""
            lock.lock(); defer { lock.unlock() }
            calls.append((method, pane, params["text"] as? String ?? ""))
            if refuse.contains("\(method) \(pane)") { throw NSError(domain: "fake", code: 1) }
        }
    }

    func testAgentsGetAPromptAndShellsATypedLine() {
        let server = FakeServer()
        let targets = Broadcast.targets(.tab, in: snapshot, workspaceId: "api", tabId: "api:t1")
        let failed = Broadcast.deliver("run the tests", to: targets, call: server.call)
        XCTAssertEqual(failed, [])
        let sorted = server.calls.sorted { $0.pane < $1.pane }
        XCTAssertEqual(sorted.map(\.method), ["agent.prompt", "pane.send_text"])
        XCTAssertEqual(sorted.map(\.text), ["run the tests", "run the tests\r"])
    }

    func testAnAgentTheServerDoesntKnowIsTypedToInstead() {
        let server = FakeServer()
        server.refuse = ["agent.prompt api:p1"]
        let targets = Broadcast.targets(.workspace, in: snapshot, workspaceId: "api", tabId: nil)
        XCTAssertEqual(Broadcast.deliver("hi", to: targets, call: server.call), [])
        XCTAssertTrue(server.calls.contains { $0.method == "pane.send_text" && $0.pane == "api:p1" && $0.text == "hi\r" })
        XCTAssertFalse(server.calls.contains { $0.method == "pane.send_text" && $0.pane == "api:p3" })
    }

    func testOnePaneFailingDoesntStopTheRestAndIsNamed() {
        let server = FakeServer()
        server.refuse = ["agent.prompt web:p1", "pane.send_text web:p1"]
        let targets = Broadcast.targets(.everywhere, in: snapshot, workspaceId: nil, tabId: nil)
        XCTAssertEqual(Broadcast.deliver("hi", to: targets, call: server.call), ["OpenCode in ui"])
        XCTAssertEqual(Set(server.calls.filter { $0.method == "agent.prompt" }.map(\.pane)), ["api:p1", "api:p3", "web:p1"])
    }
}
