import XCTest

final class EngineModelTests: XCTestCase {
    func testDecodesLiveSnapshotShape() throws {
        // Captured from the session server's `api snapshot` (0.9.1).
        let json = """
        {"id":"x","result":{"snapshot":{"agents":[{"agent":"claude","agent_status":"working","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","focused":false,"revision":3}],
        "focused_pane_id":"w1:p1","focused_tab_id":"w1:t1","focused_workspace_id":"w1",
        "panes":[{"agent_status":"unknown","cwd":"/tmp/app","focused":true,"foreground_cwd":"/tmp/app/src","pane_id":"w1:p1","revision":0,"tab_id":"w1:t1","workspace_id":"w1"}],
        "protocol":22,"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},
        {"agent_status":"working","focused":false,"label":"Explore: tests","number":2,"pane_count":1,"tab_id":"w1:t2","workspace_id":"w1"}],
        "version":"0.9.1","workspaces":[{"active_tab_id":"w1:t1","agent_status":"working","focused":true,"label":"app","number":1,"pane_count":2,"tab_count":2,"workspace_id":"w1","future_field":1}]},"type":"session_snapshot"}}
        """
        let result = try EngineClient.parseResponse(Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: data)

        XCTAssertEqual(snapshot.workspaces.first?.label, "app")
        XCTAssertEqual(snapshot.tabs(inWorkspace: "w1").map(\.label), ["1", "Explore: tests"])
        XCTAssertEqual(snapshot.agents(inTab: "w1:t2").first?.agentStatus, .working)
        XCTAssertEqual(snapshot.directory(ofWorkspace: "w1"), "/tmp/app/src")
    }

    func testDecodesCapturedFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot", withExtension: "json"))
        let result = try EngineClient.parseResponse(try Data(contentsOf: url).split(separator: 0x0A).first.map { Data($0) } ?? Data())
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        XCTAssertNoThrow(try JSONDecoder().decode(EngineSnapshot.self, from: data))
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let data = Data(#"["sleeping"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([EngineAgentStatus].self, from: data), [.unknown])
    }

    func testServerErrorsThrow() {
        let line = Data(#"{"id":"1","error":{"code":"not_found","message":"pane not found"}}"#.utf8)
        XCTAssertThrowsError(try EngineClient.parseResponse(line))
    }

    func testSessionSocketPath() {
        XCTAssertEqual(EngineClient.socketPath(session: "octet", home: "/Users/me"), "/Users/me/.config/herdr/sessions/octet/herdr.sock")
        XCTAssertEqual(EngineClient.socketPath(session: nil, home: "/Users/me"), "/Users/me/.config/herdr/herdr.sock")
    }
}

final class ProjectGroupingTests: XCTestCase {
    private func workspace(_ id: String, _ number: Int, _ label: String) -> EngineWorkspace {
        EngineWorkspace(
            workspaceId: id, number: number, label: label, focused: false, paneCount: 1, tabCount: 1,
            activeTabId: "\(id):t1", agentStatus: .idle, worktree: nil
        )
    }

    private func pane(_ workspaceId: String, cwd: String) -> EnginePane {
        EnginePane(
            paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, focused: false,
            cwd: cwd, foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil
        )
    }

    func testGroupsByProjectRootInWorkspaceOrder() {
        let snapshot = EngineSnapshot(
            workspaces: [workspace("w1", 1, "api"), workspace("w2", 2, "notes"), workspace("w3", 3, "api tests")],
            tabs: [], panes: [pane("w1", cwd: "/r/api/src"), pane("w2", cwd: "/tmp"), pane("w3", cwd: "/r/api")],
            agents: [], focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        let groups = ProjectGrouping.groups(snapshot: snapshot) { $0.hasPrefix("/r/api") ? "/r/api" : nil }
        XCTAssertEqual(groups.map(\.name), ["api", "Other"])
        XCTAssertEqual(groups.first?.workspaces.map(\.workspaceId), ["w1", "w3"])
    }

    func testProjectRootResolverParentFallback() {
        let root = ProjectRootResolver.projectRoot(
            forDirectory: "/Users/me/Developer/notes/drafts",
            projectParentDirectories: ["~/Developer"],
            homeDirectory: "/Users/me",
            gitEntryKind: { _ in nil },
            readFile: { _ in nil }
        )
        XCTAssertEqual(root, "/Users/me/Developer/notes")
    }

    func testGitBranchFromHead() {
        XCTAssertEqual(GitBranch.branch(fromHead: "ref: refs/heads/feat/tabs\n"), "feat/tabs")
        XCTAssertEqual(GitBranch.branch(fromHead: "0123456789abcdef"), "0123456")
        XCTAssertNil(GitBranch.branch(fromHead: ""))
    }
}

final class AgentBrandTests: XCTestCase {
    func testKnownVendors() {
        XCTAssertEqual(AgentBrand.forAgent("claude")?.hueHex, "#d97757")
        XCTAssertEqual(AgentBrand.forAgent("claude_code")?.displayName, "Claude Code")
        XCTAssertEqual(AgentBrand.forAgent("codex")?.hueHex, nil, "Codex signs in black")
        XCTAssertEqual(AgentBrand.forAgent("codex")?.logoAssetName, "agent-codex")
        XCTAssertEqual(AgentBrand.forAgent("antigravity")?.id, "agy")
    }

    func testUnknownVendorGetsOtherHue() {
        XCTAssertEqual(AgentBrand.forAgent("my-bot")?.hueHex, "#c78a1f")
        XCTAssertNil(AgentBrand.forAgent(nil))
        XCTAssertNil(AgentBrand.forAgent("  "))
    }
}

final class SubagentTabTests: XCTestCase {
    private let payload: [String: Any] = [
        "tool_name": "Agent",
        "tool_use_id": "toolu_1",
        "transcript_path": "/Users/me/.claude/projects/p/abc.jsonl",
        "cwd": "/Users/me/app",
        "tool_input": ["subagent_type": "Explore", "description": "Map the socket API", "prompt": "…"],
    ]

    func testBuildsNamedTabRunningViewer() throws {
        let request = try XCTUnwrap(SubagentHook.tabRequest(
            payload: payload,
            environment: [EngineProtocol.workspaceIdVariable: "w2"],
            cliPath: "/Apps/Octet.app/Contents/MacOS/octet-cli",
            now: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(request["workspace_id"] as? String, "w2")
        XCTAssertEqual(request["tab_label"] as? String, "Explore: Map the socket API")
        XCTAssertEqual(request["focus"] as? Bool, false)
        let root = try XCTUnwrap(request["root"] as? [String: Any])
        let command = try XCTUnwrap(root["command"] as? [String])
        XCTAssertEqual(Array(command.prefix(2)), ["/Apps/Octet.app/Contents/MacOS/octet-cli", "agent-watch"])
        XCTAssertTrue(command.contains("/Users/me/.claude/projects/p/abc/subagents"))
        XCTAssertTrue(command.contains("toolu_1"))
        XCTAssertEqual(root["cwd"] as? String, "/Users/me/app")
    }

    func testIgnoresOtherToolsAndNonEnginePanes() {
        var bash = payload
        bash["tool_name"] = "Bash"
        XCTAssertNil(SubagentHook.tabRequest(payload: bash, environment: [EngineProtocol.workspaceIdVariable: "w1"], cliPath: "x"))
        XCTAssertNil(SubagentHook.tabRequest(payload: payload, environment: [:], cliPath: "x"))
    }

    func testLongLabelsTruncate() {
        let label = SubagentHook.tabLabel(agentType: "general-purpose", description: String(repeating: "x", count: 80))
        XCTAssertEqual(label.count, SubagentHook.maxLabelLength)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testHookInstallerIsIdempotentAndPreservesOtherHooks() throws {
        let spec = try XCTUnwrap(SubagentHookInstaller.spec("claude"))
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]]],
        ]
        let once = SubagentHookInstaller.installing(into: existing, cliPath: "/A/octet-cli", spec: spec)
        let twice = SubagentHookInstaller.installing(into: once, cliPath: "/B/octet-cli", spec: spec)
        let entries = try XCTUnwrap((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(commands, ["guard.sh", "'/B/octet-cli' hook claude"])
        XCTAssertEqual(twice["model"] as? String, "opus")

        let removed = SubagentHookInstaller.removing(from: twice, spec: spec)
        let remaining = (removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(remaining?.count, 1)
    }

    func testEveryAgentGetsTheHookInItsOwnConfigFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let specs = SubagentHookInstaller.specs(home: home)
        XCTAssertEqual(specs.map(\.hostId), ["claude", "codex"])
        // Each writes into that agent's own file, never a shared one.
        XCTAssertEqual(specs.map(\.file), [home + "/.claude/settings.json", home + "/.codex/hooks.json"])

        let codex = try XCTUnwrap(specs.last)
        XCTAssertTrue(try SubagentHookInstaller.install(cliPath: "/x/octet-cli", spec: codex))
        XCTAssertTrue(SubagentHookInstaller.isInstalled(codex))
        // Installing twice changes nothing; the agent id is in the command.
        XCTAssertFalse(try SubagentHookInstaller.install(cliPath: "/x/octet-cli", spec: codex))
        let written = try String(contentsOfFile: codex.file, encoding: .utf8)
        XCTAssertTrue(written.contains("hook codex"))

        XCTAssertTrue(try SubagentHookInstaller.uninstall(spec: codex))
        XCTAssertFalse(SubagentHookInstaller.isInstalled(codex))
        // Only agents present on the machine are offered: writing the file
        // above created ~/.codex, so now Codex is there and Claude isn't.
        XCTAssertEqual(SubagentHookInstaller.available(home: home).map(\.hostId), ["codex"])
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertTrue(SubagentHookInstaller.available(home: bare).isEmpty)
    }
}

final class SubagentTranscriptTests: XCTestCase {
    func testToolSummaryAndTruncation() {
        XCTAssertEqual(SubagentTranscriptRenderer.toolSummary(["command": "ls -la\nwc"]), "ls -la wc")
        XCTAssertEqual(SubagentTranscriptRenderer.truncate("abcdef", 4), "abc…")
    }

    func testLocatorMatchesToolUseId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octet-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"toolUseId":"toolu_9","description":"d"}"#.utf8).write(to: dir.appendingPathComponent("agent-a1.meta.json"))
        try Data().write(to: dir.appendingPathComponent("agent-a1.jsonl"))

        let found = SubagentTranscriptLocator(directory: dir.path, toolUseId: "toolu_9", description: nil, since: 0).find()
        XCTAssertEqual(found?.lastPathComponent, "agent-a1.jsonl")
        XCTAssertNil(SubagentTranscriptLocator(directory: dir.path, toolUseId: "other", description: nil, since: 0).find())
    }

    func testFinishedCallbackFiresOnceOnTextEndTurn() {
        let renderer = SubagentTranscriptRenderer()
        var finishedCount = 0
        renderer.onFinished = { finishedCount += 1 }
        let thinking = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"…"}]}}"#
        let text = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"4"}]}}"#
        renderer.render(line: Data(thinking.utf8))
        XCTAssertEqual(finishedCount, 0)
        renderer.render(line: Data(text.utf8))
        XCTAssertEqual(finishedCount, 1)
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceRequired() {
        XCTAssertNotNil(FuzzyMatcher.match("ntab", in: "New Tab"))
        XCTAssertNil(FuzzyMatcher.match("tabn", in: "New Tab"))
        XCTAssertEqual(FuzzyMatcher.match("", in: "anything")?.score, 0)
    }

    func testWordStartsAndPrefixesOutrankScatteredMatches() throws {
        let wordStarts = try XCTUnwrap(FuzzyMatcher.match("st", in: "Split Tab"))
        let scattered = try XCTUnwrap(FuzzyMatcher.match("st", in: "Last"))
        XCTAssertGreaterThan(wordStarts.score, scattered.score)
        let prefix = try XCTUnwrap(FuzzyMatcher.match("new", in: "New Workspace"))
        let inner = try XCTUnwrap(FuzzyMatcher.match("new", in: "Rename Workspace"))
        XCTAssertGreaterThan(prefix.score, inner.score)
    }

    func testIndicesPointAtMatchedCharacters() throws {
        let match = try XCTUnwrap(FuzzyMatcher.match("nt", in: "New Tab"))
        XCTAssertEqual(match.indices, [0, 4])
    }
}

final class PaletteRankingTests: XCTestCase {
    private let entries = [
        PaletteSearchable(id: "action.newTab", kind: .action, title: "New Tab", subtitle: "", keywords: ["create"]),
        PaletteSearchable(id: "action.closeTab", kind: .action, title: "Close Tab", subtitle: "", keywords: []),
        PaletteSearchable(id: "workspace.w1", kind: .workspace, title: "atlas", subtitle: "feat/tabs", keywords: []),
        PaletteSearchable(id: "tab.w1:t2", kind: .tab, title: "Explore: map api", subtitle: "atlas", keywords: []),
        PaletteSearchable(id: "agent.w1:p2", kind: .agent, title: "Claude Code", subtitle: "working", keywords: ["claude"]),
    ]

    func testPrefixFilters() {
        XCTAssertEqual(PaletteKind.parse(">new").filter, .action)
        XCTAssertEqual(PaletteKind.parse(">new").query, "new")
        let tabs = PaletteRanking.rank(entries, query: "#", filter: nil, recentIds: [])
        XCTAssertEqual(tabs.map(\.id), ["tab.w1:t2"])
    }

    func testQueryRanksBestMatchFirstAndMatchesSubtitles() {
        XCTAssertEqual(PaletteRanking.rank(entries, query: "new tab", filter: nil, recentIds: []).first?.id, "action.newTab")
        XCTAssertTrue(PaletteRanking.rank(entries, query: "feat", filter: nil, recentIds: []).map(\.id).contains("workspace.w1"))
    }

    func testZeroStateShowsRecentsFirstThenKindOrder() {
        let ranked = PaletteRanking.rank(entries, query: "", filter: nil, recentIds: ["action.closeTab"]).map(\.id)
        XCTAssertEqual(ranked.first, "action.closeTab")
        XCTAssertEqual(ranked[1], "workspace.w1")
        XCTAssertEqual(ranked.last, "action.newTab")
    }

    func testChipFilterAndRecencyRecording() {
        XCTAssertEqual(PaletteRanking.rank(entries, query: "", filter: .agent, recentIds: []).map(\.id), ["agent.w1:p2"])
        XCTAssertEqual(PaletteRanking.recording("b", in: ["a", "b", "c"]), ["b", "a", "c"])
    }
}

final class EnginePluginTests: XCTestCase {
    func testDecodesPluginListAndLogs() throws {
        // Shape captured from the session server (0.9.1) `plugin.list` / `plugin.log.list`.
        let plugins = """
        [{"plugin_id":"octet.sample","name":"Octet Sample","version":"0.1.0","enabled":true,"platforms":["macos"],
          "actions":[{"id":"stamp","title":"Write a timestamp file","contexts":["global"],"command":["/bin/sh"]}],
          "panes":[{"id":"clock","title":"Clock","placement":"overlay","command":["/bin/sh"]}],
          "source":{"kind":"local"}}]
        """
        let decoded = try JSONDecoder().decode([EnginePlugin].self, from: Data(plugins.utf8))
        XCTAssertEqual(decoded.first?.actions.first?.id, "stamp")
        XCTAssertEqual(decoded.first?.panes.first?.placement, "overlay")
        XCTAssertEqual(decoded.first?.isGitHubInstall, false)

        let logs = """
        [{"log_id":"plugin-log-1","plugin_id":"octet.sample","action_id":"stamp","status":"succeeded",
          "started_unix_ms":1789663888058,"exit_code":0,"stdout":"","stderr":"","command":["/bin/sh"]}]
        """
        XCTAssertEqual(try JSONDecoder().decode([EnginePluginLog].self, from: Data(logs.utf8)).first?.exitCode, 0)
    }

    func testPluginPrefix() {
        XCTAssertEqual(PaletteKind.parse("!stamp").filter, .plugin)
    }
}

final class WorkspaceActivityTests: XCTestCase {
    private func workspace(_ id: String, status: EngineAgentStatus = .idle) -> EngineWorkspace {
        EngineWorkspace(workspaceId: id, number: 1, label: id, focused: false, paneCount: 1, tabCount: 1,
                       activeTabId: "\(id):t1", agentStatus: status, worktree: nil)
    }

    private func snapshot(_ workspaces: [EngineWorkspace], agents: [EngineAgent] = [], focused: String? = nil) -> EngineSnapshot {
        EngineSnapshot(workspaces: workspaces, tabs: [], panes: [], agents: agents,
                      focusedWorkspaceId: focused, focusedTabId: nil, focusedPaneId: nil)
    }

    private func agent(_ workspaceId: String, _ status: EngineAgentStatus, seq: Int) -> EngineAgent {
        EngineAgent(paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, agent: "claude",
                   name: nil, displayAgent: nil, agentStatus: status, stateChangeSeq: seq)
    }

    func testIdleAfterThresholdAndRecoveryStamp() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var activity = WorkspaceActivity()
        let snap = snapshot([workspace("w1"), workspace("w2")], focused: "w1")
        activity.observe(snap, viewedWorkspaceId: "w1", now: t0) { $0.workspaceId == "w2" ? t0.addingTimeInterval(-10_000) : nil }

        let later = t0.addingTimeInterval(3 * 3600)
        let split = activity.partition(snap.workspaces, snapshot: snap, pinned: [], idleAfter: 2 * 3600, now: later)
        XCTAssertEqual(split.active.map(\.workspaceId), ["w1"], "focused stays active")
        XCTAssertEqual(split.idle.map(\.workspaceId), ["w2"])
    }

    func testAgentChangesRefreshAndBusyAgentsNeverIdle() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var activity = WorkspaceActivity()
        let ws = [workspace("w1")]
        activity.observe(snapshot(ws, agents: [agent("w1", .idle, seq: 1)]), viewedWorkspaceId: nil, now: t0)
        let t1 = t0.addingTimeInterval(5 * 3600)
        let changed = snapshot(ws, agents: [agent("w1", .done, seq: 2)])
        activity.observe(changed, viewedWorkspaceId: nil, now: t1)
        XCTAssertEqual(activity.lastActive("w1"), t1)

        let working = snapshot(ws, agents: [agent("w1", .working, seq: 3)])
        XCTAssertFalse(activity.isIdle(ws[0], snapshot: working, pinned: [], idleAfter: 60, now: t1.addingTimeInterval(9999)))
        XCTAssertFalse(activity.isIdle(ws[0], snapshot: changed, pinned: ["w1"], idleAfter: 60, now: t1.addingTimeInterval(9999)))
        XCTAssertTrue(activity.isIdle(ws[0], snapshot: changed, pinned: [], idleAfter: 60, now: t1.addingTimeInterval(9999)))
    }

    func testClosedWorkspacesArePrunedAndAgeLabels() {
        var activity = WorkspaceActivity(stamps: ["gone": Date()])
        activity.observe(snapshot([workspace("w1")]), viewedWorkspaceId: nil)
        XCTAssertNil(activity.lastActive("gone"))
        let now = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertEqual(WorkspaceActivity.ageLabel(since: now.addingTimeInterval(-90 * 60), now: now), "1h")
        XCTAssertEqual(WorkspaceActivity.ageLabel(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testClaudeTranscriptRecovery() {
        XCTAssertEqual(ClaudeTranscriptActivity.projectDirectory(forCwd: "/Users/me/Developer/lab-vault", home: "/Users/me"),
                       "/Users/me/.claude/projects/-Users-me-Developer-lab-vault")
        let lines = """
        {"type":"user","timestamp":"2026-09-17T14:57:01.566Z"}
        {"type":"last-prompt"}
        """
        let date = ClaudeTranscriptActivity.lastTimestamp(inJSONLines: lines)
        XCTAssertEqual(date.map { Int($0.timeIntervalSince1970) }, 1789657021)
    }
}

final class AgentRecoveryTests: XCTestCase {
    private func snapshot(agents: [EngineAgent], terminals: [String]) -> EngineSnapshot {
        let panes = terminals.enumerated().map { index, terminal in
            EnginePane(paneId: "w1:p\(index)", tabId: "w1:t1", workspaceId: "w1", focused: false, cwd: "/repo",
                      foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil, terminalId: terminal)
        }
        return EngineSnapshot(
            workspaces: [EngineWorkspace(workspaceId: "w1", number: 1, label: "repo", focused: true, paneCount: 1,
                                        tabCount: 1, activeTabId: "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: [EngineTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: "claude", focused: true, paneCount: 1, agentStatus: .idle)],
            panes: panes, agents: agents, focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: nil
        )
    }

    private func agent(_ kind: String, terminal: String, session: String? = nil) -> EngineAgent {
        EngineAgent(paneId: "w1:p0", tabId: "w1:t1", workspaceId: "w1", agent: kind, name: nil, displayAgent: nil,
                   agentStatus: .idle, cwd: "/repo", terminalId: terminal,
                   agentSession: session.map { EngineAgent.SessionReference(source: nil, agent: kind, kind: "id", value: $0) })
    }

    func testSessionsRunningAtLastObservationAreLostAfterRestart() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        let before = snapshot(agents: [agent("claude", terminal: "term_a"), agent("codex", terminal: "term_b")],
                              terminals: ["term_a", "term_b"])
        var journal = AgentRecovery.record(before, into: [], now: seenAt) { agent, _ in agent.agent == "claude" ? "sess-1" : "cdx-2" }
        XCTAssertEqual(journal.first { $0.agent == "codex" }?.resumeCommand, "codex resume cdx-2")
        XCTAssertEqual(journal.first { $0.agent == "claude" }?.workspaceLabel, "repo")

        // Codex exited earlier while Octet watched: not offered.
        journal = AgentRecovery.record(snapshot(agents: [agent("claude", terminal: "term_a")], terminals: ["term_a", "term_b"]),
                                       into: journal, now: seenAt.addingTimeInterval(60)) { _, _ in nil }
        let after = snapshot(agents: [], terminals: ["term_new"])
        let lost = AgentRecovery.lostSessions(journal: journal, lastObserved: seenAt.addingTimeInterval(60), current: after)
        XCTAssertEqual(lost.map(\.agent), ["claude"])
        XCTAssertEqual(lost.first?.resumeCommand, "claude --resume sess-1")
        XCTAssertEqual(Set(AgentRecovery.history(journal: journal, current: after).map(\.agent)), ["claude", "codex"])
    }

    func testNativelyResumedAndHandledSessionsAreNotLost() {
        let now = Date()
        var journal = AgentRecovery.record(snapshot(agents: [agent("claude", terminal: "term_a")], terminals: ["term_a"]),
                                           into: [], now: now) { _, _ in "sess-1" }
        let resumed = snapshot(agents: [agent("claude", terminal: "term_z", session: "sess-1")], terminals: ["term_z"])
        XCTAssertTrue(AgentRecovery.lostSessions(journal: journal, lastObserved: now, current: resumed).isEmpty)

        journal[0].handled = true
        XCTAssertTrue(AgentRecovery.lostSessions(journal: journal, lastObserved: now,
                                                 current: snapshot(agents: [], terminals: ["x"])).isEmpty)
    }

    func testCodexSessionMetaParsingAndJournalRoundTrip() throws {
        let line = #"{"type":"session_meta","payload":{"id":"019e3e63-ed09","cwd":"/Users/me/app","timestamp":"x"}}"#
        XCTAssertEqual(AgentSessionFiles.parseCodexSessionMeta(firstLine: line)?.id, "019e3e63-ed09")
        XCTAssertNil(AgentSessionFiles.parseCodexSessionMeta(firstLine: #"{"type":"message"}"#))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/journal.json")
        let record = AgentSessionRecord(agent: "claude", sessionId: "it's", cwd: "/r", workspaceLabel: "r", tabLabel: "t",
                                        terminalId: "term", firstSeen: Date(timeIntervalSince1970: 5), lastSeen: Date(timeIntervalSince1970: 9))
        AgentSessionJournal(lastObserved: Date(timeIntervalSince1970: 9), records: [record]).save(to: url)
        XCTAssertEqual(AgentSessionJournal.load(from: url).records, [record])
        XCTAssertEqual(record.resumeCommand, "claude --resume 'it'\"'\"'s'")
    }

    func testResumeRequestRunsTheCommandInALoginShell() {
        let record = AgentSessionRecord(agent: "codex", sessionId: "abc", cwd: "/work/app", workspaceLabel: "app",
                                        tabLabel: "review", terminalId: "t", firstSeen: Date(), lastSeen: Date())
        let request = AgentRecovery.resumeRequest(record, shell: "/bin/zsh", workspaceId: "w2", tabId: nil)
        XCTAssertEqual(request["workspace_id"] as? String, "w2")
        XCTAssertEqual(request["tab_label"] as? String, "review")
        XCTAssertEqual(request["focus"] as? Bool, false)
        let pane = request["root"] as? [String: Any]
        XCTAssertEqual(pane?["cwd"] as? String, "/work/app")
        XCTAssertEqual(pane?["command"] as? [String], ["/bin/zsh", "-lic", "codex resume abc; exec /bin/zsh -l"])

        // A new workspace's empty first tab is filled instead of adding one.
        let intoTab = AgentRecovery.resumeRequest(record, shell: "/bin/zsh", workspaceId: "w3", tabId: "w3:t1")
        XCTAssertEqual(intoTab["tab_id"] as? String, "w3:t1")
        XCTAssertNil(intoTab["tab_label"])
    }

    func testClaudeSessionInferenceSkipsClaimedAndStaleTranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let dir = ClaudeTranscriptActivity.projectDirectory(forCwd: "/work/app", home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let started = Date()
        for (name, age) in [("old", -3600.0), ("a", -5.0), ("b", -1.0)] {
            FileManager.default.createFile(atPath: "\(dir)/\(name).jsonl", contents: Data("{}\n".utf8),
                                           attributes: [.modificationDate: started.addingTimeInterval(age)])
        }
        XCTAssertEqual(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, home: home), "b")
        XCTAssertEqual(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, excluding: ["b"], home: home), "a")
        XCTAssertNil(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, excluding: ["a", "b"], home: home))
    }
}

final class MarketplaceCatalogTests: XCTestCase {
    func testPluginListMergesInstalledAndAvailableAcrossHosts() throws {
        let claude = Data("""
        {"installed":[{"id":"apple-mail@apple-mail-mcp","version":"3.1.2","enabled":true,
          "installPath":"/x","installedAt":"2026-09-15T22:39:34.898Z"},
         {"id":"old@mp","version":"1.0","enabled":false,"installPath":"/y","installedAt":"2026-01-01T00:00:00Z"}],
         "available":[{"pluginId":"apple-mail@apple-mail-mcp","name":"apple-mail","description":"Mail",
           "marketplaceName":"apple-mail-mcp","version":"3.1.2","installCount":10},
          {"pluginId":"fresh@mp","name":"fresh","description":"New","marketplaceName":"mp","installCount":99}]}
        """.utf8)
        let codex = Data("""
        {"installed":[{"pluginId":"fresh@mp","name":"fresh","marketplaceName":"mp","version":"2.0","installed":true,"enabled":true}]}
        """.utf8)
        let merged = MarketplaceCatalog.merge([
            MarketplaceCatalog.plugins(json: claude, hostId: "claude"),
            MarketplaceCatalog.plugins(json: codex, hostId: "codex"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.identifier, $0) })
        XCTAssertEqual(byId["apple-mail@apple-mail-mcp"]?.installedIn, ["claude"])
        XCTAssertEqual(byId["apple-mail@apple-mail-mcp"]?.summary, "Mail")
        XCTAssertEqual(byId["fresh@mp"]?.installedIn, ["codex"])
        XCTAssertEqual(byId["fresh@mp"]?.installCount, 99)
        XCTAssertEqual(byId["old@mp"]?.enabledIn, [])
        // Installed first, then most installed.
        let order = MarketplaceCatalog.sorted(merged).map(\.identifier)
        XCTAssertEqual(order.last, "old@mp")
        XCTAssertTrue(order.firstIndex(of: "fresh@mp")! < order.firstIndex(of: "old@mp")!)
    }

    func testMCPParsersReadBothCLIs() {
        let claude = MarketplaceCatalog.claudeMCP("""
        Checking MCP server health…

        pencil: /Applications/Pencil.app/mcp-server --app desktop - ✔ Connected
        design-compare: node /x/index.mjs - ✘ Failed to connect — CONNECTION_CLOSED: Connection closed
        mobbin: https://api.mobbin.com/mcp (HTTP) - ✔ Connected
        """)
        XCTAssertEqual(claude.map(\.name), ["pencil", "design-compare", "mobbin"])
        XCTAssertEqual(claude[0].detail, "/Applications/Pencil.app/mcp-server --app desktop")
        XCTAssertEqual(claude[2].status["claude"], "✔ Connected")

        let codex = MarketplaceCatalog.codexMCP("""
        Name     Command  Args           Env  Cwd  Status    Auth
        blender  uvx      blender-mcp    -    -    enabled   Unsupported
        paused   uvx      other-mcp      -    -    disabled  Unsupported

        Name       Url                               Bearer Token Env Var  Status   Auth
        firecrawl  https://mcp.firecrawl.dev/v2/mcp  -                     enabled  Unsupported
        """)
        XCTAssertEqual(codex.map(\.name), ["blender", "paused", "firecrawl"])
        XCTAssertEqual(codex[0].detail, "uvx blender-mcp")
        XCTAssertEqual(codex[1].enabledIn, [])
        XCTAssertEqual(codex[2].detail, "https://mcp.firecrawl.dev/v2/mcp")
    }

    func testMarketplaceListParsing() {
        let list = MarketplaceCatalog.marketplaces("""
        Configured marketplaces:

          ❯ claude-plugins-official
            Source: GitHub (anthropics/claude-plugins-official)

          ❯ apple-mail-mcp
            Source: GitHub (patrickfreyer/apple-mail-mcp)
        """)
        XCTAssertEqual(list.map(\.name), ["claude-plugins-official", "apple-mail-mcp"])
        XCTAssertEqual(list[0].source, "GitHub (anthropics/claude-plugins-official)")
    }
}

final class AgentHostsTests: XCTestCase {
    func testHostsAreDiscoveredByConventionNotHardcoded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        // An agent Octet ships no special knowledge of still counts.
        try FileManager.default.createDirectory(atPath: home + "/.qwen/skills", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/plugins", withIntermediateDirectories: true)

        let installed = AgentHosts.installed(home: home)
        XCTAssertEqual(installed.map(\.id), ["claude", "qwen"])
        let qwen = try XCTUnwrap(installed.last)
        XCTAssertEqual(qwen.skillsDirectory, home + "/.qwen/skills")
        // Agents other than Claude name the folder "prompts".
        XCTAssertEqual(qwen.promptPath("review"), home + "/.qwen/prompts/review.md")
        XCTAssertFalse(qwen.supportsPlugins)
        XCTAssertFalse(qwen.supportsMCP)

        let claude = try XCTUnwrap(installed.first)
        XCTAssertEqual(claude.promptPath("review"), home + "/.claude/commands/review.md")
        XCTAssertTrue(claude.supportsPlugins)
        XCTAssertTrue(claude.supportsMCP)

        // An existing folder wins over the default name.
        try FileManager.default.createDirectory(atPath: home + "/.codex/commands", withIntermediateDirectories: true)
        XCTAssertEqual(AgentHosts.host("codex", home: home)?.promptsDirectory, home + "/.codex/commands")
    }
}

final class AgentLibraryTests: XCTestCase {
    private var home = ""
    private var hosts: [AgentHost] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        hosts = ["claude", "codex"].compactMap { AgentHosts.host($0, home: home) }
        for host in hosts {
            try FileManager.default.createDirectory(atPath: host.skillsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: host.promptsDirectory, withIntermediateDirectories: true)
        }
        setenv("OCTET_LIBRARY_DIR", home + "/.agents", 1)
    }

    override func tearDown() {
        unsetenv("OCTET_LIBRARY_DIR")
        try? FileManager.default.removeItem(atPath: home)
    }

    func testSavedItemInstallsIntoEveryHostAndReadsItsFrontmatter() throws {
        let text = "---\nname: review-diff\ndescription: \"Review the working diff\"\n---\n\nReview it.\n"
        let prompt = try AgentLibrary.save(kind: .prompt, slug: "review-diff", text: text, hosts: hosts, home: home)
        XCTAssertEqual(prompt.name, "review-diff")
        XCTAssertEqual(prompt.summary, "Review the working diff")
        XCTAssertTrue(prompt.installedIn.isEmpty)

        for host in hosts { try AgentLibrary.install(prompt, into: host) }
        let listed = AgentLibrary.items(.prompt, hosts: hosts, home: home)
        XCTAssertEqual(listed.map(\.slug), ["review-diff"])
        XCTAssertEqual(listed[0].installedIn, ["claude", "codex"])
        // The link resolves to the one library copy, so an edit reaches both.
        let viaClaude = try String(contentsOfFile: hosts[0].promptPath("review-diff"), encoding: .utf8)
        XCTAssertEqual(viaClaude, text)

        try AgentLibrary.uninstall(prompt, from: hosts[1])
        XCTAssertEqual(AgentLibrary.items(.prompt, hosts: hosts, home: home)[0].installedIn, ["claude"])
    }

    func testFrontmatterBlockScalarsAndHeadingFallback() {
        let block = AgentLibrary.describe("""
        ---
        name: firecrawl
        description: |
          Scrape and crawl the web.
          Use when a page must be read.
        ---

        # Firecrawl
        """)
        XCTAssertEqual(block.name, "firecrawl")
        XCTAssertEqual(block.summary, "Scrape and crawl the web. Use when a page must be read.")

        // No frontmatter: the heading names it and the first line describes it.
        let plain = AgentLibrary.describe("# Review Diff\n\nReview the working tree diff.\n")
        XCTAssertEqual(plain.name, "Review Diff")
        XCTAssertEqual(plain.summary, "Review the working tree diff.")

        // A `description:` later in the body never overrides the frontmatter.
        let body = AgentLibrary.describe("---\ndescription: The real summary\n---\n\nenv description: something else\n")
        XCTAssertEqual(body.summary, "The real summary")
    }

    func testPromptBodyDropsFrontmatter() {
        let text = "---\ndescription: Review the diff\n---\n\nReview the current diff.\n"
        XCTAssertEqual(AgentLibrary.promptBody(text), "Review the current diff.")
        XCTAssertEqual(AgentLibrary.promptBody("Just the prompt.\n"), "Just the prompt.")
        XCTAssertEqual(AgentLibrary.promptBody("---\nname: x\n---\n"), "")
    }

    func testAdoptMovesAHostsOwnSkillIntoTheLibraryAndLinksItBack() throws {
        let host = hosts[0]
        let skill = host.skillPath("graphify")
        try FileManager.default.createDirectory(atPath: skill, withIntermediateDirectories: true)
        try "---\nname: graphify\ndescription: Knowledge graphs\n---\n".write(toFile: skill + "/SKILL.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentLibrary.unmanaged(.skill, in: host), ["graphify"])

        let adopted = try AgentLibrary.adopt(kind: .skill, slug: "graphify", from: host, hosts: hosts, home: home)
        XCTAssertEqual(adopted.summary, "Knowledge graphs")
        XCTAssertEqual(adopted.installedIn, ["claude"])
        XCTAssertTrue(AgentLibrary.unmanaged(.skill, in: host).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skill), adopted.path)

        // A real file in the way is never clobbered.
        let other = hosts[1]
        try FileManager.default.createDirectory(atPath: other.skillPath("graphify"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AgentLibrary.install(adopted, into: other))
    }
}

final class SlashCommandTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let host = AgentHosts.host("claude", home: home)!
        try FileManager.default.createDirectory(atPath: host.promptsDirectory + "/git", withIntermediateDirectories: true)
        try "---\ndescription: Review the diff\nargument-hint: <base>\n---\nReview it."
            .write(toFile: host.promptPath("review-diff"), atomically: true, encoding: .utf8)
        try "# Amend\n\nAmend the last commit.".write(toFile: host.promptsDirectory + "/git/amend.md", atomically: true, encoding: .utf8)
        try "# Rebase\n\nRebase onto main.".write(toFile: host.promptsDirectory + "/git/rebase.md", atomically: true, encoding: .utf8)
        // A plugin's commands live under its cached version folder.
        let pluginCommands = "\(host.home)/plugins/cache/official/formatter/1.2.0/commands"
        try FileManager.default.createDirectory(atPath: pluginCommands, withIntermediateDirectories: true)
        try "---\ndescription: Format the repo\n---\n".write(toFile: pluginCommands + "/format.md", atomically: true, encoding: .utf8)
        try "---\ndescription: Check formatting\n---\n".write(toFile: pluginCommands + "/check.md", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testCommandsCombineBuiltInsUserFilesAndPlugins() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: project + "/.claude/commands", withIntermediateDirectories: true)
        try "---\ndescription: Ship it\n---\n".write(toFile: project + "/.claude/commands/ship.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: project) }

        let commands = SlashCommands.all(agent: "claude", cwd: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        XCTAssertEqual(byName["compact"]?.origin, .builtIn)
        XCTAssertEqual(byName["review-diff"]?.origin, .user)
        XCTAssertEqual(byName["review-diff"]?.summary, "Review the diff")
        XCTAssertEqual(byName["review-diff"]?.argumentHint, "<base>")
        XCTAssertEqual(byName["ship"]?.origin, .project)
        XCTAssertEqual(byName["review-diff"]?.insertion, "/review-diff")

        // Codex gets its own built-ins, not Claude's.
        let codex = SlashCommands.all(agent: "codex", cwd: nil, home: home).map(\.name)
        XCTAssertTrue(codex.contains("approvals"))
        XCTAssertFalse(codex.contains("vim"))
    }

    func testNamespacedPromptsAndMultiCommandPluginsBecomeSubmenus() {
        let commands = SlashCommands.all(agent: "claude", cwd: nil, home: home)
        let git = commands.first { $0.name == "git" }
        XCTAssertEqual(git?.children.map(\.name), ["amend", "rebase"])
        // A child keeps the full text the agent expects.
        XCTAssertEqual(git?.children.first?.insertion, "/git:amend")
        XCTAssertEqual(git?.summary, "2 commands")

        let formatter = commands.first { $0.name == "formatter" }
        XCTAssertEqual(formatter?.children.map(\.name).sorted(), ["check", "format"])
        XCTAssertEqual(formatter?.origin, .plugin("formatter"))
        XCTAssertFalse(commands.contains { $0.name == "format" })
    }

    func testBuiltInsCarryTheMachinesRealArguments() {
        var context = SlashContext()
        context.mcpServers = ["pencil", "firecrawl"]
        context.models = [("gpt-6-astra", "Most capable", ["low", "high"])]
        context.sessions = [(id: "abc-123", label: "refactor")]

        let codex = SlashCommands.all(agent: "codex", cwd: nil, context: context, home: home)
        let mcp = codex.first { $0.name == "mcp" }
        XCTAssertEqual(mcp?.children.map(\.insertion), ["/mcp pencil", "/mcp firecrawl"])
        // Models nest one level further, into their reasoning levels.
        let model = codex.first { $0.name == "model" }?.children.first
        XCTAssertEqual(model?.insertion, "/model gpt-6-astra")
        XCTAssertEqual(model?.children.map(\.insertion), ["/model gpt-6-astra low", "/model gpt-6-astra high"])

        let claude = SlashCommands.all(agent: "claude", cwd: nil, context: context, home: home)
        XCTAssertEqual(claude.first { $0.name == "resume" }?.children.first?.insertion, "/resume abc-123")
    }

    func testConfigParsersReadCodexServersAndModels() {
        let servers = SlashContext.parseCodexServers("""
        model = "gpt-6"

        [mcp_servers.pencil]
        command = "pencil"

        [mcp_servers.firecrawl]
        url = "https://example.com"

        [features]
        codex_hooks = true
        """)
        XCTAssertEqual(servers, ["pencil", "firecrawl"])

        let models = SlashContext.parseCodexModels(Data("""
        {"models":[{"slug":"gpt-6-astra","description":"Most capable",
          "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}
        """.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(models.first?.efforts, ["low", "high"])
    }

    func testMatchingSearchesTheWholeTreeAndPrefersPrefixes() {
        let commands = SlashCommands.all(agent: "claude", cwd: nil, home: home)
        XCTAssertEqual(SlashCommands.matching("comp", in: commands).first?.name, "compact")
        // A namespaced command is findable from the top level by its own name.
        XCTAssertTrue(SlashCommands.matching("amend", in: commands).contains { $0.insertion == "/git:amend" })
        XCTAssertTrue(SlashCommands.matching("toggle", in: commands).contains { $0.name == "vim" })
        XCTAssertTrue(SlashCommands.matching("zzz", in: commands).isEmpty)
        XCTAssertEqual(SlashCommands.matching("", in: commands).count, commands.count)
    }
}

final class TabAutoNameTests: XCTestCase {
    private func snapshot(title: String?, label: String, panes: Int = 1, cwd: String = "/work/app") -> EngineSnapshot {
        let panes = (0..<panes).map { index in
            EnginePane(paneId: "w1:p\(index)", tabId: "w1:t1", workspaceId: "w1", focused: index == 0, cwd: cwd,
                      foregroundCwd: nil, agentStatus: .idle, terminalTitle: title, terminalId: "term\(index)")
        }
        return EngineSnapshot(
            workspaces: [EngineWorkspace(workspaceId: "w1", number: 1, label: "app", focused: true, paneCount: panes.count,
                                        tabCount: 1, activeTabId: "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: [EngineTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: label, focused: true,
                            paneCount: panes.count, agentStatus: .idle)],
            panes: panes, agents: [], focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: nil
        )
    }

    func testTitlesBecomeLabelsAndUninformativeOnesDont() {
        XCTAssertEqual(TabAutoName.label(from: "✳ Fix the tab bar lag"), "Fix the tab bar lag")
        XCTAssertEqual(TabAutoName.label(from: "  Rewrite   the parser  "), "Rewrite the parser")
        XCTAssertEqual(TabAutoName.label(from: "jack@mac: ~/Developer/octet"), nil)
        XCTAssertNil(TabAutoName.label(from: "zsh"))
        // An agent naming itself is not a description of the work.
        XCTAssertNil(TabAutoName.label(from: "Claude Code"))
        XCTAssertNil(TabAutoName.label(from: "codex"))
        XCTAssertNil(TabAutoName.label(from: "Claude Code — ~/Developer/octet"))
        XCTAssertNil(TabAutoName.label(from: "/Users/jack/app"))
        XCTAssertNil(TabAutoName.label(from: "app", cwd: "/work/app"))
        XCTAssertNil(TabAutoName.label(from: nil))
        // Long titles cut at a word boundary.
        XCTAssertEqual(TabAutoName.label(from: "Investigate the flaky integration test suite"),
                       "Investigate the flaky…")
    }

    func testRenamesWaitForTheTitleToSettleAndRespectManualNames() {
        var pending: [String: TabAutoName.Candidate] = [:]
        let start = Date()
        let working = snapshot(title: "Fix the lag", label: "1")

        // First sighting proposes nothing yet.
        XCTAssertTrue(TabAutoName.renames(snapshot: working, manual: [], pending: &pending, now: start).isEmpty)
        // A different title restarts the clock.
        let switched = snapshot(title: "Write the docs", label: "1")
        XCTAssertTrue(TabAutoName.renames(snapshot: switched, manual: [], pending: &pending,
                                          now: start + 2).isEmpty)
        let settled = TabAutoName.renames(snapshot: switched, manual: [], pending: &pending, now: start + 5)
        XCTAssertEqual(settled.map(\.label), ["Write the docs"])
        // Renaming once is enough; it isn't proposed again.
        XCTAssertTrue(TabAutoName.renames(snapshot: snapshot(title: "Write the docs", label: "Write the docs"),
                                          manual: [], pending: &pending, now: start + 8).isEmpty)

        // A tab the user named is left alone, and split tabs have no subject.
        pending = [:]
        _ = TabAutoName.renames(snapshot: working, manual: ["w1:t1"], pending: &pending, now: start)
        XCTAssertTrue(TabAutoName.renames(snapshot: working, manual: ["w1:t1"], pending: &pending, now: start + 5).isEmpty)
        pending = [:]
        let split = snapshot(title: "Fix the lag", label: "1", panes: 2)
        _ = TabAutoName.renames(snapshot: split, manual: [], pending: &pending, now: start)
        XCTAssertTrue(TabAutoName.renames(snapshot: split, manual: [], pending: &pending, now: start + 5).isEmpty)
    }
}

final class ClipboardPreviewTests: XCTestCase {
    func testPreviewShowsOneLineAndHowMuchMore() {
        XCTAssertEqual(ClipboardPreview.summary("make run --watch"), "make run --watch")
        XCTAssertEqual(ClipboardPreview.summary("  trimmed  "), "trimmed")
        XCTAssertEqual(ClipboardPreview.summary("first\nsecond\nthird"), "first · +2 lines")
        XCTAssertEqual(ClipboardPreview.summary("only\nmore"), "only · +1 line")
        // A leading blank line still says how much was copied.
        XCTAssertEqual(ClipboardPreview.summary("\nbody"), "2 lines")
        XCTAssertEqual(ClipboardPreview.summary(String(repeating: "x", count: 80), limit: 10), "xxxxxxxxx…")
    }
}

final class TipTests: XCTestCase {
    private let deck = [
        Tip(id: "always", title: "A", body: "a"),
        Tip(id: "agents", title: "B", body: "b", applies: { $0.agentCount > 0 }),
        Tip(id: "idle", title: "C", body: "c", applies: { $0.idleCount > 0 }),
    ]

    func testOnlyTipsThatFitTheSessionAreOffered() {
        let quiet = TipContext()
        XCTAssertEqual(Tips.next(seen: [], context: quiet, deck: deck)?.id, "always")
        // With nothing new to say, it repeats rather than showing nothing.
        XCTAssertEqual(Tips.next(seen: ["always"], context: quiet, deck: deck)?.id, "always")

        var busy = TipContext()
        busy.agentCount = 2
        XCTAssertEqual(Tips.next(seen: ["always"], context: busy, deck: deck)?.id, "agents")
        XCTAssertNil(Tips.next(seen: [], context: quiet, deck: [deck[1]]))
    }

    func testSteppingThroughMovesOnAndWrapsAround() {
        var context = TipContext()
        context.agentCount = 1
        context.idleCount = 1
        let first = Tips.next(seen: [], context: context, deck: deck)
        XCTAssertEqual(first?.id, "always")
        let second = Tips.following(first, seen: ["always"], context: context, deck: deck)
        XCTAssertEqual(second?.id, "agents")
        let third = Tips.following(second, seen: ["always", "agents"], context: context, deck: deck)
        XCTAssertEqual(third?.id, "idle")
        // All seen: it wraps instead of going blank.
        XCTAssertEqual(Tips.following(third, seen: ["always", "agents", "idle"], context: context, deck: deck)?.id, "always")
    }

    func testEveryShippedTipIsDistinctAndReadable() {
        XCTAssertEqual(Set(Tips.all.map(\.id)).count, Tips.all.count)
        for tip in Tips.all {
            XCTAssertFalse(tip.title.isEmpty)
            XCTAssertLessThan(tip.title.count, 48, tip.id)
            XCTAssertLessThan(tip.body.count, 160, tip.id)
        }
    }

    func testUnnamedTabsReadAsWords() {
        XCTAssertEqual(TabAutoName.display(label: "3", number: 3), "New tab")
        XCTAssertEqual(TabAutoName.display(label: "", number: 1), "New tab")
        XCTAssertEqual(TabAutoName.display(label: "Fix the lag", number: 2), "Fix the lag")
        XCTAssertTrue(TabAutoName.isUnnamed("12"))
        XCTAssertFalse(TabAutoName.isUnnamed("v2 rollout"))
    }
}

final class AgentEnvironmentTests: XCTestCase {
    func testAgentSessionMarkersAreDroppedAndOtherVariablesKept() {
        let environment = [
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "abc",
            "CLAUDE_CODE_SESSION_ID": "def",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CODEX_SESSION_ID": "ghi",
            "CURSOR_AGENT": "1",
            "PATH": "/usr/bin",
            "CLAUDE_CONFIG_DIR": "~/.claude",
            "SESSION_MANAGER": "local/x",
            "HOME": "/Users/dev",
        ]
        let dropped = AgentEnvironment.markers(in: environment)
        XCTAssertEqual(dropped, ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
                                 "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CURSOR_AGENT"])
        let clean = AgentEnvironment.sanitized(environment)
        // Config and unrelated variables survive.
        XCTAssertEqual(clean["CLAUDE_CONFIG_DIR"], "~/.claude")
        XCTAssertEqual(clean["PATH"], "/usr/bin")
        XCTAssertEqual(clean["SESSION_MANAGER"], "local/x")
        XCTAssertNil(clean["CLAUDECODE"])
        XCTAssertTrue(AgentEnvironment.markers(in: ["PATH": "/bin"]).isEmpty)
    }
}

final class AgentActivityTests: XCTestCase {
    private func snapshot(_ statuses: [(pane: String, status: EngineAgentStatus)], tabLabel: String = "refactor") -> EngineSnapshot {
        let agents = statuses.enumerated().map { index, entry in
            EngineAgent(paneId: entry.pane, tabId: "w1:t\(index + 1)", workspaceId: "w1", agent: "claude", name: nil,
                       displayAgent: nil, agentStatus: entry.status, stateChangeSeq: index, cwd: "/repo",
                       terminalId: "term-\(entry.pane)")
        }
        let tabs = agents.enumerated().map { index, agent in
            EngineTab(tabId: agent.tabId!, workspaceId: "w1", number: index + 1, label: tabLabel, focused: index == 0,
                     paneCount: 1, agentStatus: agent.agentStatus)
        }
        return EngineSnapshot(
            workspaces: [EngineWorkspace(workspaceId: "w1", number: 1, label: "repo", focused: true, paneCount: agents.count,
                                        tabCount: tabs.count, activeTabId: tabs.first?.tabId ?? "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: tabs, panes: [], agents: agents,
            focusedWorkspaceId: "w1", focusedTabId: tabs.first?.tabId, focusedPaneId: nil
        )
    }

    func testFinishingAndBlockingRaiseNoticesButRoutineChangesDont() {
        var watcher = AgentActivityWatcher()
        let start = Date()
        // The first snapshot only records state: no notice for what was
        // already running when Octet opened.
        XCTAssertTrue(watcher.events(in: snapshot([("p1", .idle)]), now: start).isEmpty)
        XCTAssertTrue(watcher.events(in: snapshot([("p1", .working)]), now: start + 1).isEmpty)

        let finished = watcher.events(in: snapshot([("p1", .done)]), now: start + 61)
        XCTAssertEqual(finished.map(\.kind), [.finished])
        XCTAssertEqual(finished.first?.label, "refactor")
        XCTAssertEqual(AgentActivityWatcher.durationLabel(finished.first?.workedFor), "1m")

        // done → idle is the agent settling, not a second finish.
        XCTAssertTrue(watcher.events(in: snapshot([("p1", .idle)]), now: start + 62).isEmpty)
        let blocked = watcher.events(in: snapshot([("p1", .blocked)]), now: start + 63)
        XCTAssertEqual(blocked.map(\.kind), [.needsInput])
    }

    func testWorkYouAreWatchingDoesNotInterrupt() {
        var watcher = AgentActivityWatcher()
        let start = Date()
        _ = watcher.events(in: snapshot([("p1", .working)]), now: start)
        let hidden = watcher.events(in: snapshot([("p1", .done)]), now: start + 5) { _ in true }
        XCTAssertTrue(hidden.isEmpty)
    }

    func testUnnamedTabsFallBackToTheAgentName() {
        var watcher = AgentActivityWatcher()
        let start = Date()
        _ = watcher.events(in: snapshot([("p1", .working)], tabLabel: "3"), now: start)
        let events = watcher.events(in: snapshot([("p1", .done)], tabLabel: "3"), now: start + 2)
        XCTAssertEqual(events.first?.label, "Claude Code")
        XCTAssertNil(AgentActivityWatcher.durationLabel(0.4))
        XCTAssertEqual(AgentActivityWatcher.durationLabel(3_600), "1h")
        XCTAssertEqual(AgentActivityWatcher.durationLabel(3_725), "1h 2m")
    }
}

final class BranchRunTests: XCTestCase {
    private func workspace(_ id: String, worktree: EngineWorktree? = nil) -> EngineWorkspace {
        EngineWorkspace(workspaceId: id, number: 1, label: id, focused: false, paneCount: 1, tabCount: 1,
                       activeTabId: "\(id):t1", agentStatus: .idle, worktree: worktree)
    }

    func testWorkspacesOnOneBranchShareARun() {
        let branches = ["w1": "main", "w2": "main", "w3": "feature/auth"]
        let runs = BranchRuns.make([workspace("w1"), workspace("w2"), workspace("w3")],
                                   branch: { branches[$0.workspaceId] }, worktree: { $0.worktree })
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].workspaces.map(\.workspaceId), ["w1", "w2"])
        XCTAssertEqual(runs[0].branch, "main")
        XCTAssertEqual(runs[1].branch, "feature/auth")
        XCTAssertFalse(runs[0].isBare)
    }

    func testWorktreesSplitARunAndNameThemselves() {
        let tree = EngineWorktree(repoRoot: "/repo", branch: "release/2.0", path: "/repo/.worktrees/release-2")
        let runs = BranchRuns.make([workspace("w1"), workspace("w2", worktree: tree), workspace("w3")],
                                   branch: { $0.workspaceId == "w2" ? "release/2.0" : "main" },
                                   worktree: { $0.worktree })
        XCTAssertEqual(runs.map { $0.workspaces.map(\.workspaceId) }, [["w1"], ["w2"], ["w3"]])
        XCTAssertEqual(runs[1].worktreeName, "release-2")
        // Same branch either side of the worktree stays in separate runs.
        XCTAssertEqual(runs[0].key, runs[2].key)
        XCTAssertNotEqual(runs[0].id, runs[2].id)
    }

    func testAWorkspaceWithNoBranchGetsNoChip() {
        let runs = BranchRuns.make([workspace("w1")], branch: { _ in nil }, worktree: { _ in nil })
        XCTAssertTrue(runs[0].isBare)
        // A worktree alone is still worth labelling.
        let tree = EngineWorktree(repoRoot: nil, branch: nil, path: "/repo/.worktrees/spike")
        let worktreeRuns = BranchRuns.make([workspace("w2", worktree: tree)], branch: { _ in nil }, worktree: { $0.worktree })
        XCTAssertFalse(worktreeRuns[0].isBare)
        XCTAssertEqual(worktreeRuns[0].worktreeName, "spike")
    }
}

final class ShellSyntaxTests: XCTestCase {
    private func roles(_ line: String) -> [(String, ShellSyntax.Role)] {
        ShellSyntax.spans(in: line).map { (String(line[$0.range]), $0.role) }
    }

    func testCommandsFlagsPathsAndStringsAreDistinguished() {
        let parsed = roles("git commit -m \"first pass\" ./src")
        XCTAssertEqual(parsed.map(\.0), ["git", "commit", "-m", "\"first pass\"", "./src"])
        XCTAssertEqual(parsed.map(\.1), [.command, .argument, .flag, .string, .path])

        // A builtin reads differently from a program.
        XCTAssertEqual(roles("cd ~/Developer").map(\.1), [.builtin, .path])
        XCTAssertEqual(roles("$EDITOR notes.md").map(\.1), [.variable, .argument])
    }

    func testPipesStartANewCommandAndCommentsRunToTheEnd() {
        let parsed = roles("cat log | grep -i error # find failures")
        XCTAssertEqual(parsed.map(\.0), ["cat", "log", "|", "grep", "-i", "error", "# find failures"])
        XCTAssertEqual(parsed.map(\.1), [.command, .argument, .separator, .command, .flag, .argument, .comment])
        // A # inside a quoted string is not a comment.
        XCTAssertEqual(roles("echo \"# not a comment\"").map(\.1), [.builtin, .string])
    }

    func testUnterminatedQuotesAndEmptyLinesDontTrip() {
        XCTAssertEqual(roles("echo \"open").map(\.0), ["echo", "\"open"])
        XCTAssertTrue(ShellSyntax.spans(in: "   ").isEmpty)
        XCTAssertTrue(ShellSyntax.looksLikePath("~/x"))
        XCTAssertFalse(ShellSyntax.looksLikePath("https://example.com"))
    }
}

final class CommandHistoryTests: XCTestCase {
    func testZshFishAndPlainFormatsAllParse() {
        let zsh = CommandHistory.parse(": 1700000000:0;git status\n: 1700000100:0;npm run build\n")
        XCTAssertEqual(zsh.map(\.command), ["git status", "npm run build"])
        XCTAssertEqual(zsh.first?.at, Date(timeIntervalSince1970: 1_700_000_000))

        let plain = CommandHistory.parse("ls -la\ncd /tmp\n")
        XCTAssertEqual(plain.map(\.command), ["ls -la", "cd /tmp"])
        XCTAssertNil(plain.first?.at)

        let fish = CommandHistory.parse("- cmd: git push\n  when: 1700000200\n- cmd: cargo test\n  when: 1700000300\n", fish: true)
        XCTAssertEqual(fish.map(\.command), ["git push", "cargo test"])
        XCTAssertEqual(fish.last?.at, Date(timeIntervalSince1970: 1_700_000_300))
    }

    func testSuggestionsPreferRecentAndRepeatedCommands() {
        let now = Date()
        var history = CommandHistory()
        history.add(.init(command: "git status", at: now.addingTimeInterval(-40 * 86_400)))
        history.add(.init(command: "git stash pop", at: now.addingTimeInterval(-60)))
        history.add(.init(command: "git status", at: now.addingTimeInterval(-30 * 86_400)))
        XCTAssertEqual(history.suggestion(for: "git st"), "git stash pop")

        // Repetition wins once recency is comparable.
        var repeated = CommandHistory()
        for _ in 0..<5 { repeated.add(.init(command: "npm run build", at: now.addingTimeInterval(-3_600))) }
        repeated.add(.init(command: "npm run bench", at: now.addingTimeInterval(-3_500)))
        XCTAssertEqual(repeated.suggestion(for: "npm run b"), "npm run build")
    }

    func testShortPrefixesAndExactMatchesSuggestNothing() {
        var history = CommandHistory()
        history.add(.init(command: "cargo test", at: Date()))
        XCTAssertNil(history.suggestion(for: "c"))
        XCTAssertNil(history.suggestion(for: "cargo test"))
        XCTAssertNil(history.suggestion(for: "zzz"))
        XCTAssertEqual(history.suggestion(for: " ca"), "cargo test")
        XCTAssertEqual(history.ranked(matching: "cargo"), ["cargo test"])
    }
}

final class ShellPromptTests: XCTestCase {
    func testOnlyTheBareShellCountsAsAPrompt() {
        let shell = ShellPrompt.ProcessInfo(shellPid: 100, foreground: [("-zsh", 100)])
        XCTAssertTrue(ShellPrompt.isAtPrompt(shell))
        XCTAssertEqual(ShellPrompt.shellName(shell), "zsh")

        // A program in the foreground means hands off the keyboard.
        let agent = ShellPrompt.ProcessInfo(shellPid: 100, foreground: [("claude", 240)])
        XCTAssertFalse(ShellPrompt.isAtPrompt(agent))
        let editor = ShellPrompt.ProcessInfo(shellPid: 100, foreground: [("zsh", 100), ("nvim", 250)])
        XCTAssertFalse(ShellPrompt.isAtPrompt(editor))
        // A shell that isn't the pane's own shell is a nested one, not a prompt.
        XCTAssertFalse(ShellPrompt.isAtPrompt(.init(shellPid: 100, foreground: [("zsh", 300)])))
        XCTAssertFalse(ShellPrompt.isAtPrompt(.init(shellPid: 100, foreground: [])))
        XCTAssertFalse(ShellPrompt.isAtPrompt(nil))
    }

    func testProcessInfoParsesWhatEngineReports() throws {
        let payload: [String: Any] = [
            "process_info": [
                "pane_id": "w1:p1",
                "shell_pid": 35357,
                "foreground_processes": [["pid": 35357, "name": "zsh", "cwd": "/repo"]],
            ],
        ]
        let info = try XCTUnwrap(ShellPrompt.parse(payload))
        XCTAssertEqual(info.shellPid, 35357)
        XCTAssertEqual(info.foreground.first?.name, "zsh")
        XCTAssertTrue(ShellPrompt.isAtPrompt(info))
        XCTAssertNil(ShellPrompt.parse(["type": "ok"]))
    }
}

final class PromptLineTests: XCTestCase {
    func testTypingAndDeletingBehaveLikeALineEditor() {
        var line = PromptLine()
        line.insert("git status")
        XCTAssertEqual(line.text, "git status")
        XCTAssertTrue(line.caretAtEnd)

        line.deleteWordBackward()
        XCTAssertEqual(line.text, "git ")
        line.insert("commit -m x")
        line.moveToStart()
        line.deleteForward()
        XCTAssertEqual(line.text, "it commit -m x")
        line.moveToEnd()
        line.deleteToStart()
        XCTAssertTrue(line.isEmpty)
        // Deleting an empty line is harmless.
        line.deleteBackward()
        line.deleteForward()
        XCTAssertTrue(line.isEmpty)
    }

    func testCaretMovesByCharacterAndWord() {
        var line = PromptLine(text: "npm run build", caret: 13)
        line.moveWordLeft()
        XCTAssertEqual(line.caret, 8)
        line.moveWordLeft()
        XCTAssertEqual(line.caret, 4)
        line.moveLeft()
        XCTAssertEqual(line.caret, 3)
        line.moveWordRight()
        XCTAssertEqual(line.caret, 7)
        line.moveToEnd()
        line.deleteToEnd()
        XCTAssertEqual(line.text, "npm run build")
        line.moveToStart()
        line.deleteToEnd()
        XCTAssertTrue(line.isEmpty)
    }

    func testAcceptingASuggestionWholeOrOneWordAtATime() {
        var line = PromptLine(text: "git ")
        XCTAssertTrue(line.acceptWord(of: "git commit --amend"))
        XCTAssertEqual(line.text, "git commit ")
        XCTAssertTrue(line.accept(suggestion: "git commit --amend"))
        XCTAssertEqual(line.text, "git commit --amend")
        // Nothing to accept when it no longer matches or the caret moved.
        XCTAssertFalse(line.accept(suggestion: "git commit --amend"))
        XCTAssertFalse(line.accept(suggestion: "cargo test"))
        var mid = PromptLine(text: "git", caret: 1)
        XCTAssertFalse(mid.accept(suggestion: "git status"))
    }

    func testHistoryStepsForwardAndComesBackToTheDraft() {
        var line = PromptLine()
        line.insert("np")
        let matches = ["npm run build", "npm test", "npm ci"]
        line.stepHistory(1, matches: matches)
        XCTAssertEqual(line.text, "npm run build")
        XCTAssertTrue(line.isBrowsingHistory)
        line.stepHistory(1, matches: matches)
        XCTAssertEqual(line.text, "npm test")
        line.stepHistory(-1, matches: matches)
        XCTAssertEqual(line.text, "npm run build")
        line.stepHistory(-1, matches: matches)
        // Back past the newest: what was being typed returns.
        XCTAssertEqual(line.text, "np")
        XCTAssertFalse(line.isBrowsingHistory)
        // Down before any history does nothing.
        line.stepHistory(-1, matches: matches)
        XCTAssertEqual(line.text, "np")
        // Typing leaves history browsing.
        line.stepHistory(1, matches: matches)
        line.insert("!")
        XCTAssertFalse(line.isBrowsingHistory)
    }
}

final class CompletionTests: XCTestCase {
    func testTheWordUnderTheCaretIsFoundWithItsCommand() {
        let start = CompletionContext.at(caret: 2, in: "gi")
        XCTAssertEqual(start.token, "gi")
        XCTAssertTrue(start.isCommandPosition)
        XCTAssertNil(start.command)

        let argument = CompletionContext.at(caret: 8, in: "git comm")
        XCTAssertEqual(argument.token, "comm")
        XCTAssertEqual(argument.command, "git")
        XCTAssertEqual(argument.range, 4..<8)

        // Mid-word edits complete the whole word, not just what precedes.
        let middle = CompletionContext.at(caret: 6, in: "git status")
        XCTAssertEqual(middle.token, "status")
        XCTAssertEqual(middle.range, 4..<10)
        // A trailing space starts a fresh word.
        let fresh = CompletionContext.at(caret: 4, in: "git ")
        XCTAssertEqual(fresh.token, "")
        XCTAssertEqual(fresh.command, "git")
    }

    func testCommandPositionOffersCommandsBuiltinsAndHistory() {
        let context = CompletionContext.at(caret: 2, in: "ca")
        let results = Completions.suggestions(
            for: context,
            commands: ["cargo", "cat", "curl"],
            history: ["cargo test --all", "cat notes.md"]
        )
        XCTAssertEqual(results.first?.value, "cat")
        XCTAssertTrue(results.contains { $0.value == "cargo" && $0.kind == .command })
        XCTAssertTrue(results.contains { $0.value == "cargo test --all" && $0.kind == .history })
        XCTAssertFalse(results.contains { $0.value == "curl" })
    }

    func testArgumentPositionOffersSubcommandsFilesFlagsAndBranches() {
        let subcommand = Completions.suggestions(for: CompletionContext.at(caret: 6, in: "git co"))
        XCTAssertEqual(subcommand.first?.value, "commit")
        // Branches belong after the commands that take one, not everywhere.
        XCTAssertFalse(subcommand.contains { $0.kind == .branch })
        let branch = Completions.suggestions(
            for: CompletionContext.at(caret: 13, in: "git switch fe"),
            branches: ["main", "feature/auth"]
        )
        XCTAssertEqual(branch.first?.value, "feature/auth")
        XCTAssertEqual(branch.first?.kind, .branch)

        let files = Completions.suggestions(
            for: CompletionContext.at(caret: 5, in: "cat RE"),
            entries: [("README.md", false), ("Resources", true)]
        )
        XCTAssertEqual(Set(files.map(\.value)), ["README.md", "Resources/"])
        XCTAssertEqual(files.first { $0.value == "Resources/" }?.kind, .directory)

        let flags = Completions.suggestions(
            for: CompletionContext.at(caret: 6, in: "git --"),
            history: ["git --no-pager log", "git commit --amend"]
        )
        XCTAssertTrue(flags.contains { $0.value == "--no-pager" && $0.kind == .flag })
    }

    func testHarvestingFlagsAndFollowingWordsFromHistory() {
        let history = ["git commit --amend -m x", "npm run build", "git push --force-with-lease", "npm test"]
        XCTAssertEqual(Completions.flags(in: history, command: "git"), ["--amend", "--force-with-lease", "-m"])
        XCTAssertEqual(Completions.secondWord(of: history, command: "npm"), ["run", "test"])
        XCTAssertTrue(Completions.flags(in: history, command: "cargo").isEmpty)
    }
}

final class PromptLineSelectionTests: XCTestCase {
    func testSelectingReplacingAndDeleting() {
        var line = PromptLine(text: "git status")
        line.extendingSelection { $0.moveWordLeft() }
        XCTAssertEqual(line.selectedText, "status")
        line.insert("commit")
        XCTAssertEqual(line.text, "git commit")
        XCTAssertNil(line.selection)

        line.selectAll()
        XCTAssertEqual(line.selectedText, "git commit")
        line.deleteBackward()
        XCTAssertTrue(line.isEmpty)
    }

    func testUndoAndRedoWalkBackThroughEdits() {
        var line = PromptLine()
        line.insert("git")
        line.insert(" status")
        line.deleteWordBackward()
        XCTAssertEqual(line.text, "git ")
        line.undo()
        XCTAssertEqual(line.text, "git status")
        line.undo()
        XCTAssertEqual(line.text, "git")
        line.redo()
        XCTAssertEqual(line.text, "git status")
        // A fresh edit clears the redo trail.
        line.insert("!")
        line.redo()
        XCTAssertEqual(line.text, "git status!")
        // Undo on an untouched line is harmless.
        var empty = PromptLine()
        empty.undo()
        empty.redo()
        XCTAssertTrue(empty.isEmpty)
    }

    func testReplacingTheWordUnderTheCaretForCompletions() {
        var line = PromptLine(text: "git comm", caret: 8)
        line.replace(range: 4..<8, with: "commit")
        XCTAssertEqual(line.text, "git commit")
        XCTAssertEqual(line.caret, 10)
        line.undo()
        XCTAssertEqual(line.text, "git comm")
    }
}

final class SpecCompletionTests: XCTestCase {
    func testASpecOffersSubcommandsThenItsOwnOptions() {
        let spec = CompletionSpecs.git
        let top = spec.candidates(after: [])
        XCTAssertTrue(top.names.contains { $0.value == "commit" && $0.summary == "Record staged changes" })

        // Inside `git commit`, its flags are what fit.
        let commit = spec.candidates(after: ["commit"])
        XCTAssertTrue(commit.names.contains { $0.value == "--amend" })
        XCTAssertFalse(commit.names.contains { $0.value == "stash" })

        // Nested subcommands resolve too.
        let worktree = spec.candidates(after: ["worktree"])
        XCTAssertTrue(worktree.names.contains { $0.value == "add" })
    }

    func testArgumentsSayWhereTheirValuesComeFrom() {
        let branch = Completions.generator(for: CompletionSpecs.git, words: ["switch"])
        XCTAssertEqual(branch?.id, "git.branches")
        XCTAssertNil(Completions.generator(for: CompletionSpecs.git, words: ["status"]))

        let fromSpec = Completions.fromSpec(
            CompletionSpecs.git, words: ["switch"], token: "fe", generatorValues: ["feature/auth", "main"]
        )
        XCTAssertTrue(fromSpec.contains { $0.value == "feature/auth" && $0.kind == .branch })

        // A file argument pulls this folder's entries instead.
        let files = Completions.fromSpec(
            CompletionSpecs.git, words: ["add"], token: "", entries: [("README.md", false), ("src", true)]
        )
        XCTAssertTrue(files.contains { $0.value == "src/" && $0.kind == .directory })
    }

    func testIngestedJSONBecomesASpec() throws {
        let json = """
        {"name":"kubectl","description":"Kubernetes","subcommands":[
          {"name":"get","description":"Display resources","args":{"suggestions":["pods","services"]}},
          {"name":"apply","options":[{"names":["-f","--filename"],"description":"File","args":{"template":"filepaths"}}]}
        ]}
        """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let spec = try XCTUnwrap(SpecCorpus.parse(object))
        XCTAssertEqual(spec.name, "kubectl")
        XCTAssertEqual(spec.subcommands.count, 2)
        let get = spec.candidates(after: ["get"])
        XCTAssertEqual(get.argument, .values(["pods", "services"]))
        let apply = spec.candidates(after: ["apply"])
        XCTAssertTrue(apply.names.contains { $0.value == "--filename" })
    }
}

final class ProjectCommandTests: XCTestCase {
    func testScriptsTargetsRecipesAndServicesAreRead() {
        let npm = ProjectCommands.parseNpmScripts(Data(#"{"scripts":{"build":"tsc","test":"vitest"}}"#.utf8))
        XCTAssertEqual(npm.map(\.command), ["npm run build", "npm run test"])

        let make = ProjectCommands.parseMakeTargets("""
        CC = clang
        .PHONY: all
        all: build test
        \trun-something
        build:
        %.o: %.c
        """)
        XCTAssertEqual(make.map(\.command), ["make all", "make build"])

        let just = ProjectCommands.parseJustRecipes("""
        set shell := ["bash"]
        deploy env:
        \techo deploying
        test:
        """)
        XCTAssertEqual(just.map(\.command), ["just deploy", "just test"])

        let compose = ProjectCommands.parseComposeServices("""
        version: "3"
        services:
          web:
            image: nginx
          db:
            image: postgres
        volumes:
          data:
        """)
        XCTAssertEqual(compose.map(\.command), ["docker compose up web", "docker compose up db"])
    }

    func testAliasesComeFromShellAndGitConfigs() {
        XCTAssertEqual(
            ProjectCommands.parseShellAliases("alias gs='git status'\n# alias nope='x'\nalias ll=\"ls -la\"\nexport A=1"),
            ["gs", "ll"]
        )
        XCTAssertEqual(
            ProjectCommands.parseGitAliases("[user]\n\tname = X\n[alias]\n\tco = checkout\n\tlg = log --oneline\n[core]\n\teditor = vim"),
            ["co", "lg"]
        )
    }
}

final class CommandSequenceTests: XCTestCase {
    func testWhatUsuallyFollowsIsLearnedFromHistory() {
        let history = [
            "git add .", "git commit -m wip", "git push",
            "git add .", "git commit -m fix", "git push",
            "cargo test",
        ]
        let sequences = CommandSequences(history: history)
        // Both commits followed `git add .` once, so the more recent wins.
        XCTAssertEqual(sequences.next(after: "git add .").first, "git commit -m fix")
        XCTAssertEqual(sequences.next(after: "git commit -m anything").first, "git push")
        XCTAssertTrue(sequences.next(after: "nothing-like-this").isEmpty)
    }

    func testPredictionsRespectWhatIsAlreadyTyped() {
        let sequences = CommandSequences(history: [
            "make build", "make test", "make build", "make test", "make build", "just deploy",
        ])
        // Twice as many `make test` follow-ups as the one-off `just deploy`.
        XCTAssertEqual(sequences.prediction(after: "make build", matching: ""), "make test")
        XCTAssertNil(sequences.prediction(after: "make build", matching: "cargo"))
        XCTAssertEqual(sequences.prediction(after: "make build", matching: "make t"), "make test")
    }

    func testAFoldersOwnHabitsFillAnEmptyPrompt() {
        var sequences = CommandSequences()
        sequences.add(command: "npm run dev", in: "/work/site")
        sequences.add(command: "npm run dev", in: "/work/site")
        sequences.add(command: "npm test", in: "/work/site")
        XCTAssertEqual(sequences.common(in: "/work/site").first, "npm run dev")
        XCTAssertTrue(sequences.common(in: "/elsewhere").isEmpty)
    }
}

final class TwinTranscriptTests: XCTestCase {
    func testAClaudeTranscriptBecomesAConversation() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Refactor auth"}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-17T10:00:00.000Z","cwd":"/repo","message":{"role":"user","content":"fix the login bug"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"model":"claude-opus-5","content":[{"type":"thinking","thinking":"consider the session store"},{"type":"text","text":"I'll look at the session store."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/auth.swift"}}],"usage":{"input_tokens":120,"output_tokens":40,"cache_read_input_tokens":900}}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"func login() {}\nmore"}]}}"#,
        ]
        let conversation = TwinTranscript.parseClaude(lines: lines)
        XCTAssertEqual(conversation.title, "Refactor auth")
        XCTAssertEqual(conversation.model, "claude-opus-5")
        XCTAssertEqual(conversation.cwd, "/repo")
        XCTAssertEqual(conversation.messages.count, 3)
        XCTAssertEqual(conversation.messages[0].role, .user)
        XCTAssertEqual(conversation.messages[1].blocks.count, 3)
        XCTAssertEqual(conversation.messages[1].blocks[0], .thinking("consider the session store"))
        XCTAssertEqual(conversation.messages[1].blocks[2],
                       .toolCall(id: "t1", name: "Read", summary: "/repo/auth.swift"))
        XCTAssertEqual(conversation.messages[2].blocks[0],
                       .toolResult(id: "t1", summary: "func login() {}", isError: false))
        XCTAssertEqual(conversation.usage?.inputTokens, 120)
        XCTAssertEqual(conversation.usage?.cacheReadTokens, 900)
        XCTAssertEqual(conversation.consumedLines, 4)
    }

    func testACodexRolloutBecomesTheSameShape() {
        let lines = [
            #"{"type":"session_meta","timestamp":"2026-09-17T10:00:00Z","payload":{"id":"s1","cwd":"/work"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_started","model_context_window":272000}}"#,
            #"{"type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"run the tests"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","id":"f1","call_id":"c1","name":"shell","arguments":"{\"command\":\"cargo test\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","id":"o1","call_id":"c1","output":"test result: ok"}}"#,
            #"{"type":"token_usage_record","payload":{"usage":{"input_tokens":50,"output_tokens":10,"cached_input_tokens":4}}}"#,
        ]
        let conversation = TwinTranscript.parseCodex(lines: lines)
        XCTAssertEqual(conversation.cwd, "/work")
        XCTAssertEqual(conversation.messages.count, 3)
        XCTAssertEqual(conversation.messages[0].blocks, [.text("run the tests")])
        XCTAssertEqual(conversation.messages[1].blocks,
                       [.toolCall(id: "c1", name: "shell", summary: "cargo test")])
        XCTAssertEqual(conversation.messages[2].blocks,
                       [.toolResult(id: "c1", summary: "test result: ok", isError: false)])
        XCTAssertEqual(conversation.usage?.contextWindow, 272_000)
        XCTAssertEqual(conversation.usage?.total, 60)
    }

    func testTheAgentDecidesWhichReaderRunsAndBadLinesAreSkipped() {
        let codexLine = #"{"type":"response_item","payload":{"type":"message","id":"m","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#
        XCTAssertEqual(TwinTranscript.parse(agent: "codex", lines: [codexLine]).messages.first?.blocks, [.text("done")])
        // Claude's reader ignores a Codex line rather than inventing a turn.
        XCTAssertTrue(TwinTranscript.parse(agent: "claude", lines: [codexLine]).messages.isEmpty)
        // Half-written lines are normal while a file is being appended to.
        let torn = TwinTranscript.parseClaude(lines: ["", "{\"type\":\"assistant\",", "not json"])
        XCTAssertTrue(torn.messages.isEmpty)
        XCTAssertEqual(torn.consumedLines, 3)
    }

    func testSummariesPickTheMeaningfulFieldAndStayShort() {
        XCTAssertEqual(TwinTranscript.toolSummary(name: "Bash", input: ["command": "ls -la"]), "ls -la")
        XCTAssertEqual(TwinTranscript.toolSummary(name: "Edit", input: ["file_path": "/a/b.swift", "old": "x"]), "/a/b.swift")
        XCTAssertEqual(TwinTranscript.toolSummary(name: "shell", input: "{\"command\":\"go build\"}"), "go build")
        XCTAssertEqual(TwinTranscript.condense("\n\n  first real line  \nsecond"), "first real line")
        XCTAssertEqual(TwinTranscript.condense(String(repeating: "x", count: 200)).count, 120)
    }
}

final class ImagePasteTests: XCTestCase {
    func testPastedImagesGetTimedNamesAndQuotedPaths() {
        let name = ImagePaste.filename(at: Date(timeIntervalSince1970: 1_700_000_000), extension: "png")
        XCTAssertTrue(name.hasPrefix("pasted-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        // A path lands on a command line, so spaces have to survive it.
        XCTAssertEqual(ImagePaste.insertion(for: "/tmp/a.png"), "/tmp/a.png")
        XCTAssertEqual(ImagePaste.insertion(for: "/tmp/my shot.png"), "'/tmp/my shot.png'")
        XCTAssertEqual(ImagePaste.insertion(for: "/tmp/it's.png"), #"'/tmp/it'"'"'s.png'"#)
    }

    func testSavingWritesTheFileAndPruningKeepsTheRecentOnes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = try ImagePaste.save(Data("png-bytes".utf8), home: home,
                                       at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "png-bytes")

        for offset in 1...4 {
            _ = try ImagePaste.save(Data("x".utf8), home: home,
                                    at: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
        }
        ImagePaste.prune(keeping: 2, home: home)
        let left = try FileManager.default.contentsOfDirectory(atPath: ImagePaste.directory(home: home))
        XCTAssertEqual(left.count, 2)
    }
}

final class AgentDiscoveryTests: XCTestCase {
    /// A home with an executable `agent` in `bin`, and a plain file next to it.
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home + "/bin/agent", contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: home + "/bin/notes.txt", contents: Data())
        return home
    }

    func testLocateFindsOnlyExecutableFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directories = [home + "/bin"]
        XCTAssertEqual(AgentDiscovery.locate(command: "agent", in: directories), home + "/bin/agent")
        // A readable file that isn't executable, and a name that isn't there.
        XCTAssertNil(AgentDiscovery.locate(command: "notes.txt", in: directories))
        XCTAssertNil(AgentDiscovery.locate(command: "missing", in: directories))
        // A directory of the right name is not a command.
        XCTAssertNil(AgentDiscovery.locate(command: "bin", in: [home]))
    }

    func testLocateTakesTheFirstDirectoryThatHasIt() throws {
        let first = try makeHome(), second = try makeHome()
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        XCTAssertEqual(AgentDiscovery.locate(command: "agent", in: [first + "/bin", second + "/bin"]),
                       first + "/bin/agent")
    }

    func testSearchDirectoriesExpandsHomeAndDropsRepeats() {
        let directories = AgentDiscovery.searchDirectories(shellPath: "/usr/bin:/opt/homebrew/bin::/usr/bin",
                                                           home: "/Users/test")
        XCTAssertEqual(directories.first, "/usr/bin")
        XCTAssertEqual(directories.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(directories.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertFalse(directories.contains(""))
        XCTAssertTrue(directories.contains("/Users/test/.local/bin"))
        // Each agent's own bin folder is searched too, which is where
        // OpenCode installs itself.
        XCTAssertTrue(directories.contains("/Users/test/.opencode/bin"))
    }

    func testVersionIgnoresCommandsThatSayTooMuch() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let chatty = home + "/bin/chatty"
        FileManager.default.createFile(atPath: chatty, contents: Data("#!/bin/sh\necho '\(String(repeating: "x", count: 200))'\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertNil(AgentDiscovery.version(of: chatty))

        let quiet = home + "/bin/quiet"
        FileManager.default.createFile(atPath: quiet, contents: Data("#!/bin/sh\necho\necho 'agent 1.2.3'\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(AgentDiscovery.version(of: quiet), "agent 1.2.3")
    }
}

final class NewTabFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private let settled = NewTabFreshness.settleDelay + 0.1

    // The terminal reports a reading only when the grid changes, so these
    // feed one per change, as it does.

    func testOneReadingOfOutputEndsItForGood() {
        var freshness = NewTabFreshness()
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(0)))
        // `ls` prints, the grid settles, and nothing more is reported.
        XCTAssertFalse(freshness.observe(tab: "t1", cursorRow: 7, rowsInUse: 8, at: at(settled + 2)))
        XCTAssertTrue(freshness.used.contains("t1"))
        // `clear` empties the screen, but the tab has been used.
        XCTAssertFalse(freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(settled + 5)))
    }

    func testANewTabShowsTheSplash() {
        var freshness = NewTabFreshness()
        // Before the shell has drawn anything, and once its prompt is up.
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 0, at: at(0)))
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(0.1)))
    }

    func testACommandWithNoOutputStillCounts() {
        var freshness = NewTabFreshness()
        _ = freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(0))
        // Settled on its first prompt, on row 0.
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(settled)))
        // `cd somewhere`: a second prompt one row down, nothing printed.
        XCTAssertFalse(freshness.observe(tab: "t1", cursorRow: 1, rowsInUse: 2, at: at(settled + 3)))
        XCTAssertTrue(freshness.used.contains("t1"))
    }

    func testATwoLinePromptIsStillFresh() {
        var freshness = NewTabFreshness()
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 2, rowsInUse: 3, at: at(0)))
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 2, rowsInUse: 3, at: at(settled)))
    }

    func testTheLastTabShowingJustAfterASwitchDoesNotCount() {
        var freshness = NewTabFreshness()
        // Just switched to t2; the grid still shows t1's output.
        XCTAssertFalse(freshness.observe(tab: "t2", cursorRow: 20, rowsInUse: 21, at: at(0)))
        XCTAssertFalse(freshness.used.contains("t2"))
        // Then t2's own prompt draws.
        XCTAssertTrue(freshness.observe(tab: "t2", cursorRow: 0, rowsInUse: 1, at: at(0.1)))
        XCTAssertTrue(freshness.observe(tab: "t2", cursorRow: 0, rowsInUse: 1, at: at(settled)))
    }

    func testAnUnsettledPromptRowIsNotTrusted() {
        var freshness = NewTabFreshness()
        // A stale reading of another tab's prompt, on row 2, then t2's own on
        // row 0: row 2 must not become t2's prompt row, or a `cd` in t2 (to
        // row 1) would go unnoticed.
        _ = freshness.observe(tab: "t2", cursorRow: 2, rowsInUse: 1, at: at(0))
        _ = freshness.observe(tab: "t2", cursorRow: 0, rowsInUse: 1, at: at(settled))
        XCTAssertFalse(freshness.observe(tab: "t2", cursorRow: 1, rowsInUse: 2, at: at(settled + 2)))
        XCTAssertTrue(freshness.used.contains("t2"))
    }

    func testItSaysWhenToLookAgain() {
        var freshness = NewTabFreshness()
        _ = freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(0))
        XCTAssertEqual(freshness.settles(tab: "t1", at: at(0.1)), at(NewTabFreshness.settleDelay))
        XCTAssertNil(freshness.settles(tab: "t1", at: at(settled)))
        // Switching tabs starts the wait again.
        _ = freshness.observe(tab: "t2", cursorRow: 0, rowsInUse: 1, at: at(10))
        XCTAssertNotNil(freshness.settles(tab: "t2", at: at(10.1)))
    }

    func testTypingHidesItAndErasingBringsItBack() {
        var freshness = NewTabFreshness()
        // The prompt "~ % " leaves the cursor at column 4 on row 0.
        _ = freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 4, rowsInUse: 1, at: at(0))
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 4, rowsInUse: 1, at: at(settled)))
        // "cla" typed.
        XCTAssertFalse(freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 7, rowsInUse: 1, at: at(settled + 1)))
        // Typing isn't using: the tab is still fresh.
        XCTAssertFalse(freshness.used.contains("t1"))
        // Backspaced away.
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 4, rowsInUse: 1, at: at(settled + 2)))
    }

    func testThePromptColumnIsTheLeftmostSeen() {
        var freshness = NewTabFreshness()
        // Settled while something was already typed, at column 9.
        _ = freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 9, rowsInUse: 1, at: at(0))
        _ = freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 9, rowsInUse: 1, at: at(settled))
        // Erased back to the prompt's own end: that is the real start.
        XCTAssertTrue(freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 4, rowsInUse: 1, at: at(settled + 1)))
        XCTAssertFalse(freshness.observe(tab: "t1", cursorRow: 0, cursorColumn: 5, rowsInUse: 1, at: at(settled + 2)))
    }

    func testTabsAreJudgedApart() {
        var freshness = NewTabFreshness()
        _ = freshness.observe(tab: "t1", cursorRow: 0, rowsInUse: 1, at: at(0))
        _ = freshness.observe(tab: "t1", cursorRow: 9, rowsInUse: 10, at: at(settled))
        XCTAssertTrue(freshness.used.contains("t1"))
        XCTAssertTrue(freshness.observe(tab: "t2", cursorRow: 0, rowsInUse: 1, at: at(settled + 1)))
        freshness.forget("t1")
        XCTAssertFalse(freshness.used.contains("t1"))
    }
}

final class SplitDropTests: XCTestCase {
    /// One pane filling a 100×50-cell tab, shown in a 1000×500 view.
    private let single = PaneLayout(area: CGRect(x: 0, y: 0, width: 100, height: 50),
                                    panes: [.init(id: "p1", rect: CGRect(x: 0, y: 0, width: 100, height: 50))])
    private let view = CGSize(width: 1000, height: 500)

    func testTheNearestEdgeWins() {
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 950, y: 250), in: view, layout: single)?.edge, .right)
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 40, y: 250), in: view, layout: single)?.edge, .left)
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 500, y: 20), in: view, layout: single)?.edge, .top)
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 500, y: 480), in: view, layout: single)?.edge, .bottom)
    }

    func testTheHighlightIsTheHalfTheTabWillTake() {
        let target = SplitDrop.target(at: CGPoint(x: 950, y: 250), in: view, layout: single)
        XCTAssertEqual(target?.paneId, "p1")
        XCTAssertEqual(target?.highlight, CGRect(x: 500, y: 0, width: 500, height: 500))
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 500, y: 480), in: view, layout: single)?.highlight,
                       CGRect(x: 0, y: 250, width: 1000, height: 250))
    }

    func testASplitTabPicksThePaneUnderThePoint() {
        // Two panes side by side, split at column 50, with a divider column.
        let split = PaneLayout(area: CGRect(x: 0, y: 0, width: 101, height: 50), panes: [
            .init(id: "left", rect: CGRect(x: 0, y: 0, width: 50, height: 50)),
            .init(id: "right", rect: CGRect(x: 51, y: 0, width: 50, height: 50)),
        ])
        let wide = CGSize(width: 1010, height: 500)
        let onRight = SplitDrop.target(at: CGPoint(x: 990, y: 250), in: wide, layout: split)
        XCTAssertEqual(onRight?.paneId, "right")
        XCTAssertEqual(onRight?.edge, .right)
        // The right pane's left edge: between the two, not the window's edge.
        XCTAssertEqual(SplitDrop.target(at: CGPoint(x: 530, y: 250), in: wide, layout: split)?.edge, .left)
        // On the divider itself, the nearer pane takes it.
        XCTAssertNotNil(SplitDrop.target(at: CGPoint(x: 505, y: 250), in: wide, layout: split))
    }

    func testLeftAndTopAreSplitsThenSwaps() {
        XCTAssertEqual(SplitEdge.left.split, "right")
        XCTAssertTrue(SplitEdge.left.swaps)
        XCTAssertEqual(SplitEdge.top.split, "down")
        XCTAssertTrue(SplitEdge.top.swaps)
        XCTAssertFalse(SplitEdge.right.swaps)
        XCTAssertFalse(SplitEdge.bottom.swaps)
    }

    func testLayoutParsesTheEnginesAnswer() {
        let result: [String: Any] = ["type": "pane_layout", "layout": [
            "area": ["x": 0, "y": 0, "width": 155, "height": 51],
            "panes": [["pane_id": "w4:p3", "focused": true, "rect": ["x": 0, "y": 0, "width": 155, "height": 51]]],
        ]]
        let layout = PaneLayout.parse(result)
        XCTAssertEqual(layout?.area, CGRect(x: 0, y: 0, width: 155, height: 51))
        XCTAssertEqual(layout?.panes.map(\.id), ["w4:p3"])
        XCTAssertNil(PaneLayout.parse(["layout": ["area": ["x": 0, "y": 0, "width": 0, "height": 0], "panes": []]]))
    }
}

final class EngineNavigationTests: XCTestCase {
    private typealias Stroke = EngineNavigation.Stroke
    private let prefix = EngineNavigation.prefix

    func testTheFirstNineAreOneJump() {
        XCTAssertEqual(EngineNavigation.toTab(from: 0, to: 1), [prefix, Stroke(key: "digit2")])
        XCTAssertEqual(EngineNavigation.toWorkspace(from: nil, to: 0), [prefix, Stroke(key: "digit1", alt: true)])
        XCTAssertEqual(EngineNavigation.toWorkspace(from: 3, to: 8), [prefix, Stroke(key: "digit9", alt: true)])
    }

    func testBeingThereAlreadyIsNoKeys() {
        XCTAssertTrue(EngineNavigation.toTab(from: 4, to: 4).isEmpty)
        XCTAssertTrue(EngineNavigation.toTab(from: nil, to: -1).isEmpty)
    }

    func testPastNineItJumpsToTheNinthAndSteps() {
        let next = [prefix, Stroke(key: "n")]
        XCTAssertEqual(EngineNavigation.toTab(from: nil, to: 10), [prefix, Stroke(key: "digit9")] + next + next)
        // From right next door, stepping is shorter than the jump.
        XCTAssertEqual(EngineNavigation.toTab(from: 11, to: 10), [prefix, Stroke(key: "p")])
        XCTAssertEqual(EngineNavigation.toWorkspace(from: 9, to: 10), [prefix, Stroke(key: "n", alt: true)])
    }

    func testStrokesCarryWhatTheTerminalNeeds() {
        XCTAssertNil(prefix.text)
        XCTAssertEqual(prefix.codepoint, UInt32(("b" as Unicode.Scalar).value))
        XCTAssertEqual(Stroke(key: "digit2").text, "2")
        XCTAssertNil(Stroke(key: "digit2", alt: true).text)
        XCTAssertEqual(Stroke(key: "digit2", alt: true).codepoint, UInt32(("2" as Unicode.Scalar).value))
    }

    func testTheConfigBindsWhatThePlannerSends() {
        let config = EngineNavigation.keysConfig
        for binding in ["prefix = \"ctrl+b\"", "switch_tab = \"prefix+1..9\"", "switch_workspace = \"prefix+alt+1..9\"",
                        "next_workspace = \"prefix+alt+n\"", "next_tab = \"prefix+n\""] {
            XCTAssertTrue(config.contains(binding), binding)
        }
    }

    // Each create call's answer, as the engine gives it.
    func testCreatedIdsComeOutOfEveryShape() {
        XCTAssertEqual(EngineCreated(result: ["tab": ["tab_id": "w1:t2", "workspace_id": "w1"],
                                              "root_pane": ["pane_id": "w1:p2"]]),
                       EngineCreated(workspaceId: "w1", tabId: "w1:t2", paneId: "w1:p2"))
        XCTAssertEqual(EngineCreated(result: ["workspace": ["workspace_id": "w2", "active_tab_id": "w2:t1"],
                                              "tab": ["tab_id": "w2:t1", "workspace_id": "w2"]]).tabId, "w2:t1")
        XCTAssertEqual(EngineCreated(result: ["layout": ["workspace_id": "w1", "tab_id": "w1:t3", "focused_pane_id": "w1:p3"]]),
                       EngineCreated(workspaceId: "w1", tabId: "w1:t3", paneId: "w1:p3"))
        XCTAssertEqual(EngineCreated(result: ["move_result": ["pane": ["pane_id": "w3:p1", "workspace_id": "w3", "tab_id": "w3:t1"]]]),
                       EngineCreated(workspaceId: "w3", tabId: "w3:t1", paneId: "w3:p1"))
    }
}
