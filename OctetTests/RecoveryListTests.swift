import XCTest

final class RecoveryListTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func agentRecord(_ kind: String = "claude", session: String? = "s1", terminal: String,
                             workspace: String = "app", tab: String = "", cwd: String = "/work/app",
                             ago: TimeInterval = 0) -> AgentSessionRecord {
        AgentSessionRecord(agent: kind, sessionId: session, cwd: cwd, workspaceLabel: workspace, tabLabel: tab,
                           terminalId: terminal, firstSeen: base.addingTimeInterval(-ago - 60),
                           lastSeen: base.addingTimeInterval(-ago))
    }

    private func shellRecord(_ terminal: String, command: String = "npm run dev", workspace: String = "app",
                             tab: String = "dev", cwd: String = "/work/app", ago: TimeInterval = 0) -> ShellSessionRecord {
        ShellSessionRecord(terminalId: terminal, workspaceLabel: workspace, tabLabel: tab, cwd: cwd, command: command,
                           firstSeen: base.addingTimeInterval(-ago - 60), lastSeen: base.addingTimeInterval(-ago))
    }

    private func workspace(_ id: String, _ label: String) -> EngineWorkspace {
        EngineWorkspace(workspaceId: id, number: 1, label: label, focused: false, paneCount: 1, tabCount: 1,
                        activeTabId: "\(id):t1", agentStatus: .idle, worktree: nil)
    }

    private func tab(_ id: String, in workspace: String, label: String, panes: Int = 1, number: Int = 1) -> EngineTab {
        EngineTab(tabId: id, workspaceId: workspace, number: number, label: label, focused: false, paneCount: panes, agentStatus: .idle)
    }

    private func pane(_ id: String, tab: String, workspace: String, cwd: String, focused: Bool = false) -> EnginePane {
        EnginePane(paneId: id, tabId: tab, workspaceId: workspace, focused: focused, cwd: cwd, foregroundCwd: nil,
                   agentStatus: .idle, terminalTitle: nil, terminalId: "term-" + id)
    }

    private func snapshot(workspaces: [EngineWorkspace], tabs: [EngineTab] = [], panes: [EnginePane],
                          agents: [EngineAgent] = []) -> EngineSnapshot {
        EngineSnapshot(workspaces: workspaces, tabs: tabs, panes: panes, agents: agents,
                       focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil)
    }

    // MARK: - Lists

    func testGroupsByWorkspaceNewestFirstAndFallsBackToTheFolder() {
        let items = [
            RecoveryItem(agent: agentRecord(terminal: "a", workspace: "api", ago: 300)),
            RecoveryItem(agent: agentRecord(session: "s2", terminal: "b", workspace: "app", ago: 10)),
            RecoveryItem(terminal: shellRecord("c", workspace: "api", ago: 100)),
            RecoveryItem(agent: agentRecord(session: "s3", terminal: "d", workspace: "", cwd: "/tmp/scratch", ago: 50)),
        ]
        let groups = RecoveryList.groups(items)
        XCTAssertEqual(groups.map(\.title), ["app", "scratch", "api"])
        XCTAssertEqual(groups[2].items.map(\.id), ["terminal:c", "agent:a"])
    }

    func testDedupeKeepsTheNewestRecordOfEachSession() {
        let records = [
            agentRecord(session: "s1", terminal: "old", ago: 600),
            agentRecord(session: "s1", terminal: "new", ago: 5),
            agentRecord(session: nil, terminal: "unknown"),
            agentRecord(session: "s2", terminal: "other"),
        ]
        XCTAssertEqual(RecoveryList.dedupe(records).map(\.terminalId), ["new", "unknown", "other"])
    }

    func testMergeSkipsSettledRowsRepeatsAndSecondCopiesOfASession() {
        let existing = [RecoveryItem(agent: agentRecord(session: "s1", terminal: "a"))]
        let incoming = [
            RecoveryItem(agent: agentRecord(session: "s1", terminal: "a")),
            RecoveryItem(agent: agentRecord(session: "s1", terminal: "b")),
            RecoveryItem(terminal: shellRecord("restored")),
            RecoveryItem(terminal: shellRecord("fresh")),
        ]
        let merged = RecoveryList.merge(existing, incoming, settled: ["terminal:restored"])
        XCTAssertEqual(merged.map(\.id), ["agent:a", "terminal:fresh"])
    }

    func testLostSessionsKeepUnresumableOnesAndDedupe() {
        let journal = [
            agentRecord(session: "s1", terminal: "old", ago: 1),
            agentRecord(session: "s1", terminal: "new", ago: 0),
            agentRecord("aider", session: nil, terminal: "x"),
        ]
        let lost = AgentRecovery.lostSessions(journal: journal, lastObserved: base, current: .empty)
        XCTAssertEqual(lost.map(\.terminalId), ["new", "x"])
    }

    func testHistoryLeavesOutSessionsRunningElsewhereOrOutOfSight() {
        let journal = [
            agentRecord(session: "s1", terminal: "now", ago: 0),
            agentRecord(session: "s1", terminal: "before", ago: 60),
            agentRecord(session: "s2", terminal: "closed-tab", ago: 0),
            agentRecord(session: "s3", terminal: "gone", ago: 0),
        ]
        let live = EngineAgent(paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1", agent: "claude", name: nil, displayAgent: nil,
                               agentStatus: .idle, cwd: "/work/app", terminalId: "now", agentSession: nil)
        let current = snapshot(workspaces: [workspace("w1", "app")], panes: [], agents: [live])
        let history = AgentRecovery.history(journal: journal, current: current, liveTerminals: ["closed-tab"])
        XCTAssertEqual(history.map(\.terminalId), ["gone"])
    }

    // MARK: - Availability

    func testUnavailableReasons() {
        XCTAssertNil(RecoveryList.unavailableReason(agentRecord(terminal: "a"), folderExists: true, sessionFileExists: true))
        XCTAssertNil(RecoveryList.unavailableReason(agentRecord("opencode", terminal: "a"), folderExists: true, sessionFileExists: nil))
        XCTAssertEqual(RecoveryList.unavailableReason(agentRecord(session: nil, terminal: "a"), folderExists: true, sessionFileExists: nil),
                       "Octet never learned which session it was")
        XCTAssertEqual(RecoveryList.unavailableReason(agentRecord("aider", terminal: "a"), folderExists: true, sessionFileExists: nil),
                       "aider can't resume a session from the command line")
        XCTAssertEqual(RecoveryList.unavailableReason(agentRecord(terminal: "a"), folderExists: false, sessionFileExists: true),
                       "Its folder no longer exists")
        XCTAssertEqual(RecoveryList.unavailableReason(agentRecord(terminal: "a"), folderExists: true, sessionFileExists: false),
                       "Claude Code no longer has this session")
        XCTAssertNil(RecoveryList.unavailableReason(shellRecord("t"), folderExists: true))
        XCTAssertNotNil(RecoveryList.unavailableReason(shellRecord("t"), folderExists: false))
    }

    func testSessionFilesAreLookedForWhereTheAgentKeepsThem() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let record = agentRecord(session: "abc", terminal: "a", cwd: "/work/app")
        XCTAssertEqual(RecoveryList.sessionFileExists(record, home: home), false)
        let folder = ClaudeTranscriptActivity.projectDirectory(forCwd: "/work/app", home: home)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"All tests pass.\nDetails follow."}]}}"#
        try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: folder + "/abc.jsonl"))
        XCTAssertEqual(RecoveryList.sessionFileExists(record, home: home), true)
        XCTAssertEqual(RecoveryList.transcriptPath(record, home: home), folder + "/abc.jsonl")
        XCTAssertEqual(RecoveryList.sessionFileExists(agentRecord("codex", session: "zzz", terminal: "b"), home: home), false)
        XCTAssertNil(RecoveryList.sessionFileExists(agentRecord("opencode", terminal: "c"), home: home))
    }

    func testLastMessageIsTheAgentsLastTextNotTheUsers() {
        let lines = [
            #"{"type":"user","uuid":"u0","message":{"role":"user","content":"fix the build"}}"#,
            #"{"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"\nFixed the import.\nMore."}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"thanks"}}"#,
        ]
        XCTAssertEqual(RecoveryList.lastMessage(agent: "claude", lines: lines), "Fixed the import.")
        XCTAssertNil(RecoveryList.lastMessage(agent: "claude", lines: [lines[0]]))
    }

    func testLastOutputLineDropsColoursAndRedraws() {
        let text = "\u{1B}[32mready\u{1B}[0m\r\n\u{1B}]0;title\u{07}compiling 10%\rcompiled \u{1B}[1mok\u{1B}[0m\n\n   \n"
        XCTAssertEqual(ShellRecovery.lastOutputLine(text), "compiled ok")
        XCTAssertNil(ShellRecovery.lastOutputLine("\u{1B}[2J\n  \n"))
        XCTAssertEqual(ShellRecovery.lastOutputLine(String(repeating: "x", count: 20), limit: 5), "xxxx…")
    }

    // MARK: - Placement

    func testWorkspaceChoiceFavoursNameAndFolderThenTheClosestFolder() {
        let home = "/Users/me"
        let current = snapshot(
            workspaces: [workspace("w1", "app"), workspace("w2", "app"), workspace("w3", "mono"),
                         workspace("w4", "mono-web"), workspace("w5", "home")],
            panes: [pane("w1:p1", tab: "w1:t1", workspace: "w1", cwd: "/elsewhere"),
                    pane("w2:p1", tab: "w2:t1", workspace: "w2", cwd: "/work/app"),
                    pane("w3:p1", tab: "w3:t1", workspace: "w3", cwd: "/work/mono"),
                    pane("w4:p1", tab: "w4:t1", workspace: "w4", cwd: "/work/mono/web"),
                    pane("w5:p1", tab: "w5:t1", workspace: "w5", cwd: home)]
        )
        // The same name in the same folder beats the first of that name.
        XCTAssertEqual(RecoveryList.workspace(label: "app", cwd: "/work/app", in: current, home: home), "w2")
        // A subfolder goes to the deepest workspace holding it.
        XCTAssertEqual(RecoveryList.workspace(label: "", cwd: "/work/mono/web/src", in: current, home: home), "w4")
        XCTAssertEqual(RecoveryList.workspace(label: "", cwd: "/work/mono/api", in: current, home: home), "w3")
        // A workspace at ~ doesn't swallow everything under it.
        XCTAssertNil(RecoveryList.workspace(label: "", cwd: home + "/notes", in: current, home: home))
        // A name alone, as a last resort.
        XCTAssertEqual(RecoveryList.workspace(label: "mono", cwd: "/other", in: current, home: home), "w3")
        XCTAssertNil(RecoveryList.workspace(label: "new", cwd: "/other", in: current, home: home))
    }

    func testReusableTabsAreTheServersRestoredTabsWithNoAgent() {
        let agent = EngineAgent(paneId: "w1:p3", tabId: "w1:t3", workspaceId: "w1", agent: "claude", name: nil, displayAgent: nil,
                                agentStatus: .idle, cwd: "/work/app", terminalId: "x", agentSession: nil)
        let current = snapshot(
            workspaces: [workspace("w1", "app")],
            tabs: [tab("w1:t1", in: "w1", label: "dev"), tab("w1:t2", in: "w1", label: "dev", panes: 2, number: 2),
                   tab("w1:t3", in: "w1", label: "dev", number: 3), tab("w1:t4", in: "w1", label: "dev", number: 4)],
            panes: [pane("w1:p1", tab: "w1:t1", workspace: "w1", cwd: "/work/app"),
                    pane("w1:p2", tab: "w1:t2", workspace: "w1", cwd: "/work/app"),
                    pane("w1:p3", tab: "w1:t3", workspace: "w1", cwd: "/work/app"),
                    pane("w1:p4", tab: "w1:t4", workspace: "w1", cwd: "/work/other")],
            agents: [agent]
        )
        let found = RecoveryList.reusableTabs(named: "dev", cwd: "/work/app", workspaceId: "w1", in: current,
                                              excluding: [], displayName: false)
        XCTAssertEqual(found.map(\.tab.tabId), ["w1:t1"])
        XCTAssertTrue(RecoveryList.reusableTabs(named: "dev", cwd: "/work/app", workspaceId: "w1", in: current,
                                                excluding: ["w1:t1"], displayName: false).isEmpty)
        XCTAssertTrue(RecoveryList.reusableTabs(named: "", cwd: "/work/app", workspaceId: "w1", in: current,
                                                excluding: [], displayName: false).isEmpty)
    }

    // MARK: - Words

    func testButtonProgressAndFinishedStates() {
        XCTAssertEqual(RecoveryList.restoreTitle(selected: 0, restorable: 3), "Restore")
        XCTAssertEqual(RecoveryList.restoreTitle(selected: 2, restorable: 3), "Restore 2")
        XCTAssertEqual(RecoveryList.restoreTitle(selected: 3, restorable: 3), "Restore All")
        XCTAssertEqual(RecoveryList.restoreTitle(selected: 1, restorable: 1), "Restore 1")

        var items = [RecoveryItem(terminal: shellRecord("a")), RecoveryItem(terminal: shellRecord("b")),
                     RecoveryItem(agent: agentRecord(terminal: "c"), status: .unavailable("gone"))]
        items[0].status = .restored
        items[1].status = .restoring
        let progress = RecoveryList.progress(items, batch: ["terminal:a", "terminal:b"])
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 2)
        XCTAssertNil(RecoveryList.progress(items, batch: []))
        XCTAssertFalse(RecoveryList.isFinished(items))
        items[1].status = .failed("no")
        XCTAssertFalse(RecoveryList.isFinished(items))
        items[1].status = .restored
        XCTAssertTrue(RecoveryList.isFinished(items))
        XCTAssertFalse(RecoveryList.isFinished([]))
        XCTAssertEqual(RecoveryList.countPhrase(items), "1 agent session and 2 terminals")
    }

    func testRowTitlesNameTheTabWhenItSaysMore() {
        XCTAssertEqual(RecoveryItem(agent: agentRecord(terminal: "a", tab: "claude")).title, "Claude Code")
        XCTAssertNil(RecoveryItem(agent: agentRecord(terminal: "a", tab: "")).detail)
        let named = RecoveryItem(agent: agentRecord(terminal: "a", tab: "Migrate schema"))
        XCTAssertEqual(named.title, "Migrate schema")
        XCTAssertEqual(named.detail, "Claude Code")
        let terminal = RecoveryItem(terminal: shellRecord("t", command: "/usr/local/bin/node server.js", tab: "api"))
        XCTAssertEqual(terminal.title, "node server.js")
        XCTAssertEqual(terminal.detail, "api")
        XCTAssertTrue(RecoveryStatus.failed("x").canRestore)
        XCTAssertFalse(RecoveryStatus.unavailable("x").canRestore)
        XCTAssertFalse(RecoveryStatus.restored.canRestore)
    }
}
