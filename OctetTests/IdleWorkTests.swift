import XCTest

final class IdleWorkTests: XCTestCase {
    func testStatusGivesTheBranchAndTheChangedFiles() {
        let status = """
        # branch.oid 1111
        # branch.head feat/login
        # branch.upstream origin/feat/login
        # branch.ab +2 -0
        1 .M N... 100644 100644 100644 aaa bbb Sources/a.swift
        ? notes.txt
        """
        let parsed = IdleWork.parseStatus(status)
        XCTAssertEqual(parsed.branch, "feat/login")
        XCTAssertEqual(parsed.uncommitted, 2)
        XCTAssertNil(IdleWork.parseStatus("# branch.head (detached)\n").branch)
        XCTAssertEqual(IdleWork.parseStatus("# branch.head main\n").uncommitted, 0)
    }

    func testSaysWhatClosingWouldLose() {
        XCTAssertTrue(IdleWork().isClean)
        XCTAssertNil(IdleWork().summary)
        XCTAssertNil(IdleWork().risks)
        let work = IdleWork(branch: "main", uncommitted: 3, unpushed: 1, ports: [3000])
        XCTAssertFalse(work.isClean)
        XCTAssertEqual(work.summary, "3 uncommitted · 1 unpushed · :3000")
        XCTAssertEqual(work.risks, "3 uncommitted files, 1 unpushed commit and a server on :3000")
        XCTAssertEqual(IdleWork(ports: [3000, 5173]).risks, "servers on :3000, :5173")
        XCTAssertEqual(IdleWork(ports: [1, 2, 3]).summary, ":1 · :2 · +1 ports")
        XCTAssertFalse(IdleWork(ports: [8080]).isClean)
    }

    func testReadsARealRepository() throws {
        let git = Git()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-idle-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let id = ["-c", "user.email=t@t", "-c", "user.name=t"]
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: repo)
        try git.run(id + ["commit", "-qm", "base"], in: repo)

        // No remote: nothing counts as unpushed.
        var work = IdleWork.read(directory: repo, ports: [], isWorktree: false, git: git)
        XCTAssertEqual(work.branch, "main")
        XCTAssertEqual(work.uncommitted, 0)
        XCTAssertEqual(work.unpushed, 0)

        // A remote that has the first commit, then one it doesn't, and an edit.
        try git.run(["init", "-q", "--bare", base + "/remote.git"], in: base)
        try git.run(["remote", "add", "origin", base + "/remote.git"], in: repo)
        try git.run(["push", "-q", "origin", "main"], in: repo)
        try "b\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: repo)
        try git.run(id + ["commit", "-qm", "local"], in: repo)
        try "edited\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        work = IdleWork.read(directory: repo, ports: [3000], isWorktree: false, git: git)
        XCTAssertEqual(work.uncommitted, 1)
        XCTAssertEqual(work.unpushed, 1)
        XCTAssertEqual(work.ports, [3000])

        // A worktree whose branch is merged.
        try git.run(["checkout", "-q", "--", "a.txt"], in: repo)
        try git.run(["worktree", "add", "-q", "-b", "done", base + "/done"], in: repo)
        XCTAssertTrue(IdleWork.read(directory: base + "/done", ports: [], isWorktree: true, git: git).mergedWorktree)
        try "c\n".write(toFile: base + "/done/c.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: base + "/done")
        try git.run(id + ["commit", "-qm", "more"], in: base + "/done")
        XCTAssertFalse(IdleWork.read(directory: base + "/done", ports: [], isWorktree: true, git: git).mergedWorktree)

        // Outside a repository: nothing to lose but the ports.
        XCTAssertEqual(IdleWork.read(directory: base, ports: [], isWorktree: false, git: git), IdleWork())
    }
}

final class WorkspaceSleepTests: XCTestCase {
    private let workspace = EngineWorkspace(workspaceId: "w1", number: 1, label: "api", focused: false, paneCount: 2, tabCount: 2,
                                            activeTabId: "w1:t1", agentStatus: .done, worktree: nil)

    private func snapshot(agentStatus: EngineAgentStatus = .done, focused: String? = "w2") -> EngineSnapshot {
        EngineSnapshot(
            workspaces: [workspace],
            tabs: [EngineTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: "Claude", focused: true, paneCount: 1, agentStatus: agentStatus),
                   EngineTab(tabId: "w1:t2", workspaceId: "w1", number: 2, label: "shell", focused: false, paneCount: 1, agentStatus: .idle)],
            panes: [EnginePane(paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1", focused: true, cwd: "/repo", foregroundCwd: nil,
                               agentStatus: agentStatus, terminalTitle: nil, terminalId: "term1"),
                    EnginePane(paneId: "w1:p2", tabId: "w1:t2", workspaceId: "w1", focused: false, cwd: "/repo", foregroundCwd: "/repo/web",
                               agentStatus: .idle, terminalTitle: nil, terminalId: "term2")],
            agents: [EngineAgent(paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1", agent: "claude", name: nil, displayAgent: nil,
                                 agentStatus: agentStatus, cwd: "/repo", terminalId: "term1")],
            focusedWorkspaceId: focused, focusedTabId: nil, focusedPaneId: nil)
    }

    private let record = AgentSessionRecord(agent: "claude", sessionId: "s1", cwd: "/repo", workspaceLabel: "api", tabLabel: "Claude",
                                            terminalId: "term1", firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0))

    func testCaptureWritesDownEachTabAndItsAgent() {
        let slept = WorkspaceSleep.capture(workspace, snapshot: snapshot(), records: ["term1": record],
                                           conversations: [.init(engine: "codex", sessionId: "t9", title: "Refactor", cwd: "/repo")],
                                           branch: "main", project: "api", lastActive: nil, work: IdleWork(uncommitted: 2),
                                           now: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(slept.label, "api")
        XCTAssertEqual(slept.tabs.map(\.label), ["Claude", "shell"])
        XCTAssertEqual(slept.tabs[0].agent?.sessionId, "s1")
        XCTAssertNil(slept.tabs[1].agent)
        XCTAssertEqual(slept.tabs[1].cwd, "/repo/web")
        XCTAssertEqual(slept.summary, "2 tabs · Claude, Codex · 2 uncommitted")

        // An agent with no known session is a plain tab.
        let unknown = WorkspaceSleep.capture(workspace, snapshot: snapshot(), records: [:], conversations: [],
                                             branch: nil, project: nil, lastActive: nil, work: nil)
        XCTAssertNil(unknown.tabs[0].agent)
    }

    func testOnlyWhatWouldLoseNothingSleepsByItself() {
        let quiet = snapshot()
        XCTAssertNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: [], ports: [], pinned: false, shown: false))
        // The agent's own pane counts as busy (the agent runs there) but is resumed on waking.
        XCTAssertNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: ["w1:p1"], ports: [], pinned: false, shown: false))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: ["w1:p2"], ports: [], pinned: false, shown: false))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: [], ports: [3000], pinned: false, shown: false))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: [], ports: [], pinned: true, shown: false))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: quiet, busyPanes: [], ports: [], pinned: false, shown: true))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: snapshot(focused: "w1"), busyPanes: [], ports: [], pinned: false, shown: false))
        XCTAssertNotNil(WorkspaceSleep.reasonToStayAwake(workspace, snapshot: snapshot(agentStatus: .blocked), busyPanes: [], ports: [],
                                                          pinned: false, shown: false))

        let now = Date(timeIntervalSince1970: 100 * 86_400)
        XCTAssertTrue(WorkspaceSleep.isDue(lastActive: now.addingTimeInterval(-15 * 86_400), afterDays: 14, now: now))
        XCTAssertFalse(WorkspaceSleep.isDue(lastActive: now.addingTimeInterval(-13 * 86_400), afterDays: 14, now: now))
        XCTAssertFalse(WorkspaceSleep.isDue(lastActive: .distantPast, afterDays: 0, now: now))
    }

    func testTheListSurvivesARoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/sleeping.json")
        let slept = WorkspaceSleep.capture(workspace, snapshot: snapshot(), records: ["term1": record], conversations: [],
                                           branch: "main", project: nil, lastActive: Date(timeIntervalSince1970: 7), work: nil,
                                           now: Date(timeIntervalSince1970: 9))
        SleepingWorkspacesFile(workspaces: [slept]).save(to: url)
        XCTAssertEqual(SleepingWorkspacesFile.load(from: url).workspaces, [slept])
    }
}

final class PaneLayoutTests: XCTestCase {
    private func decode(_ json: String) throws -> PaneLayoutNode {
        try JSONDecoder().decode(PaneLayoutNode.self, from: Data(json.utf8))
    }

    func testLayoutsReadFromAPluginsJSON() throws {
        let node = try decode(#"{"columns": ["pane", {"rows": ["pane", "pane"]}], "weights": [2, 1]}"#)
        XCTAssertEqual(node, .split(axis: .columns, children: [.pane, .split(axis: .rows, children: [.pane, .pane], weights: [1, 1])],
                                    weights: [2, 1]))
        XCTAssertEqual(node.paneCount, 3)
        XCTAssertNil(node.problem)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayoutNode.self, from: JSONEncoder().encode(node)), node)
        XCTAssertThrowsError(try decode(#""window""#))
        XCTAssertThrowsError(try decode(#"{"grid": []}"#))
    }

    func testWhatALayoutCantBe() throws {
        XCTAssertNotNil(try decode(#"{"columns": ["pane"]}"#).problem)
        XCTAssertNotNil(try decode(#"{"columns": ["pane", "pane"], "weights": [1]}"#).problem)
        XCTAssertNotNil(try decode(#"{"columns": ["pane", "pane"], "weights": [1, 0]}"#).problem)
        XCTAssertNotNil(try decode(#"{"columns": ["pane","pane","pane","pane","pane","pane","pane","pane","pane","pane"]}"#).problem)
    }

    func testPanesShareTheRoomByWeight() throws {
        let rects = try decode(#"{"rows": ["pane", {"columns": ["pane", "pane", "pane"]}], "weights": [2, 1]}"#).rects()
        XCTAssertEqual(rects.count, 4)
        XCTAssertEqual(rects[0].height, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(rects[1].y, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(rects[2].x, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(rects[3].width, 1.0 / 3, accuracy: 1e-9)
    }

    func testTheSessionServerGetsBinarySplitsThatKeepEachShare() throws {
        let tree = try decode(#"{"columns": ["pane", "pane", "pane"]}"#).engineTree(cwd: "/r")
        XCTAssertEqual(tree["type"] as? String, "split")
        XCTAssertEqual(tree["direction"] as? String, "right")
        XCTAssertEqual(tree["ratio"] as? Double, 0.333)
        let second = try XCTUnwrap(tree["second"] as? [String: Any])
        XCTAssertEqual(second["ratio"] as? Double, 0.5)
        XCTAssertEqual((second["first"] as? [String: Any])?["cwd"] as? String, "/r")
        let rows = try decode(#"{"rows": ["pane", "pane"]}"#).engineTree(cwd: "/r")
        XCTAssertEqual(rows["direction"] as? String, "down")

        let request = try decode(#"{"rows": ["pane", "pane"]}"#).request(title: "2 stacked", cwd: "/r", workspaceId: "w1")
        XCTAssertEqual(request["tab_label"] as? String, "2 stacked")
        XCTAssertEqual(request["workspace_id"] as? String, "w1")
    }

    func testTheBundledPluginIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins/pane-layouts/plugin.json")
        let manifest = try JSONDecoder().decode(OctetPluginManifest.self, from: Data(contentsOf: url))
        XCTAssertNil(OctetPlugins.validate(manifest))
        let counts = Set(manifest.contributes.layouts.map(\.layout.paneCount))
        XCTAssertEqual(counts, [2, 3, 4])
        // No two draw the same.
        let pictures = manifest.contributes.layouts.map { $0.layout.rects().map { "\($0.x),\($0.y),\($0.width),\($0.height)" } }
        XCTAssertEqual(Set(pictures).count, pictures.count)
    }
}
