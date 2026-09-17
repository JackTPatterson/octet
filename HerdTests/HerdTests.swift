import XCTest

final class HerdrModelTests: XCTestCase {
    func testDecodesLiveSnapshotShape() throws {
        // Captured from `herdr api snapshot` (herdr 0.9.1).
        let json = """
        {"id":"x","result":{"snapshot":{"agents":[{"agent":"claude","agent_status":"working","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","focused":false,"revision":3}],
        "focused_pane_id":"w1:p1","focused_tab_id":"w1:t1","focused_workspace_id":"w1",
        "panes":[{"agent_status":"unknown","cwd":"/tmp/app","focused":true,"foreground_cwd":"/tmp/app/src","pane_id":"w1:p1","revision":0,"tab_id":"w1:t1","workspace_id":"w1"}],
        "protocol":22,"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},
        {"agent_status":"working","focused":false,"label":"Explore: tests","number":2,"pane_count":1,"tab_id":"w1:t2","workspace_id":"w1"}],
        "version":"0.9.1","workspaces":[{"active_tab_id":"w1:t1","agent_status":"working","focused":true,"label":"app","number":1,"pane_count":2,"tab_count":2,"workspace_id":"w1","future_field":1}]},"type":"session_snapshot"}}
        """
        let result = try HerdrClient.parseResponse(Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: data)

        XCTAssertEqual(snapshot.workspaces.first?.label, "app")
        XCTAssertEqual(snapshot.tabs(inWorkspace: "w1").map(\.label), ["1", "Explore: tests"])
        XCTAssertEqual(snapshot.agents(inTab: "w1:t2").first?.agentStatus, .working)
        XCTAssertEqual(snapshot.directory(ofWorkspace: "w1"), "/tmp/app/src")
    }

    func testDecodesCapturedFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot", withExtension: "json"))
        let result = try HerdrClient.parseResponse(try Data(contentsOf: url).split(separator: 0x0A).first.map { Data($0) } ?? Data())
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        XCTAssertNoThrow(try JSONDecoder().decode(HerdrSnapshot.self, from: data))
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let data = Data(#"["sleeping"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([HerdrAgentStatus].self, from: data), [.unknown])
    }

    func testServerErrorsThrow() {
        let line = Data(#"{"id":"1","error":{"code":"not_found","message":"pane not found"}}"#.utf8)
        XCTAssertThrowsError(try HerdrClient.parseResponse(line))
    }

    func testSessionSocketPath() {
        XCTAssertEqual(HerdrClient.socketPath(session: "herd", home: "/Users/me"), "/Users/me/.config/herdr/sessions/herd/herdr.sock")
        XCTAssertEqual(HerdrClient.socketPath(session: nil, home: "/Users/me"), "/Users/me/.config/herdr/herdr.sock")
    }
}

final class ProjectGroupingTests: XCTestCase {
    private func workspace(_ id: String, _ number: Int, _ label: String) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceId: id, number: number, label: label, focused: false, paneCount: 1, tabCount: 1,
            activeTabId: "\(id):t1", agentStatus: .idle, worktree: nil
        )
    }

    private func pane(_ workspaceId: String, cwd: String) -> HerdrPane {
        HerdrPane(
            paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, focused: false,
            cwd: cwd, foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil
        )
    }

    func testGroupsByProjectRootInWorkspaceOrder() {
        let snapshot = HerdrSnapshot(
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
            environment: ["HERDR_WORKSPACE_ID": "w2"],
            cliPath: "/Apps/Herd.app/Contents/MacOS/herd-cli",
            now: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(request["workspace_id"] as? String, "w2")
        XCTAssertEqual(request["tab_label"] as? String, "Explore: Map the socket API")
        XCTAssertEqual(request["focus"] as? Bool, false)
        let root = try XCTUnwrap(request["root"] as? [String: Any])
        let command = try XCTUnwrap(root["command"] as? [String])
        XCTAssertEqual(Array(command.prefix(2)), ["/Apps/Herd.app/Contents/MacOS/herd-cli", "agent-watch"])
        XCTAssertTrue(command.contains("/Users/me/.claude/projects/p/abc/subagents"))
        XCTAssertTrue(command.contains("toolu_1"))
        XCTAssertEqual(root["cwd"] as? String, "/Users/me/app")
    }

    func testIgnoresOtherToolsAndNonHerdrPanes() {
        var bash = payload
        bash["tool_name"] = "Bash"
        XCTAssertNil(SubagentHook.tabRequest(payload: bash, environment: ["HERDR_WORKSPACE_ID": "w1"], cliPath: "x"))
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
        let once = SubagentHookInstaller.installing(into: existing, cliPath: "/A/herd-cli", spec: spec)
        let twice = SubagentHookInstaller.installing(into: once, cliPath: "/B/herd-cli", spec: spec)
        let entries = try XCTUnwrap((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(commands, ["guard.sh", "'/B/herd-cli' hook claude"])
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
        XCTAssertTrue(try SubagentHookInstaller.install(cliPath: "/x/herd-cli", spec: codex))
        XCTAssertTrue(SubagentHookInstaller.isInstalled(codex))
        // Installing twice changes nothing; the agent id is in the command.
        XCTAssertFalse(try SubagentHookInstaller.install(cliPath: "/x/herd-cli", spec: codex))
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herd-subagents-\(UUID().uuidString)")
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
        PaletteSearchable(id: "workspace.w1", kind: .workspace, title: "cmux", subtitle: "feat/tabs", keywords: []),
        PaletteSearchable(id: "tab.w1:t2", kind: .tab, title: "Explore: map api", subtitle: "cmux", keywords: []),
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

final class HerdrPluginTests: XCTestCase {
    func testDecodesPluginListAndLogs() throws {
        // Shape captured from herdr 0.9.1 `plugin.list` / `plugin.log.list`.
        let plugins = """
        [{"plugin_id":"herd.sample","name":"Herd Sample","version":"0.1.0","enabled":true,"platforms":["macos"],
          "actions":[{"id":"stamp","title":"Write a timestamp file","contexts":["global"],"command":["/bin/sh"]}],
          "panes":[{"id":"clock","title":"Clock","placement":"overlay","command":["/bin/sh"]}],
          "source":{"kind":"local"}}]
        """
        let decoded = try JSONDecoder().decode([HerdrPlugin].self, from: Data(plugins.utf8))
        XCTAssertEqual(decoded.first?.actions.first?.id, "stamp")
        XCTAssertEqual(decoded.first?.panes.first?.placement, "overlay")
        XCTAssertEqual(decoded.first?.isGitHubInstall, false)

        let logs = """
        [{"log_id":"plugin-log-1","plugin_id":"herd.sample","action_id":"stamp","status":"succeeded",
          "started_unix_ms":1789663888058,"exit_code":0,"stdout":"","stderr":"","command":["/bin/sh"]}]
        """
        XCTAssertEqual(try JSONDecoder().decode([HerdrPluginLog].self, from: Data(logs.utf8)).first?.exitCode, 0)
    }

    func testPluginPrefix() {
        XCTAssertEqual(PaletteKind.parse("!stamp").filter, .plugin)
    }
}

final class WorkspaceActivityTests: XCTestCase {
    private func workspace(_ id: String, status: HerdrAgentStatus = .idle) -> HerdrWorkspace {
        HerdrWorkspace(workspaceId: id, number: 1, label: id, focused: false, paneCount: 1, tabCount: 1,
                       activeTabId: "\(id):t1", agentStatus: status, worktree: nil)
    }

    private func snapshot(_ workspaces: [HerdrWorkspace], agents: [HerdrAgent] = [], focused: String? = nil) -> HerdrSnapshot {
        HerdrSnapshot(workspaces: workspaces, tabs: [], panes: [], agents: agents,
                      focusedWorkspaceId: focused, focusedTabId: nil, focusedPaneId: nil)
    }

    private func agent(_ workspaceId: String, _ status: HerdrAgentStatus, seq: Int) -> HerdrAgent {
        HerdrAgent(paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, agent: "claude",
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
    private func snapshot(agents: [HerdrAgent], terminals: [String]) -> HerdrSnapshot {
        let panes = terminals.enumerated().map { index, terminal in
            HerdrPane(paneId: "w1:p\(index)", tabId: "w1:t1", workspaceId: "w1", focused: false, cwd: "/repo",
                      foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil, terminalId: terminal)
        }
        return HerdrSnapshot(
            workspaces: [HerdrWorkspace(workspaceId: "w1", number: 1, label: "repo", focused: true, paneCount: 1,
                                        tabCount: 1, activeTabId: "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: [HerdrTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: "claude", focused: true, paneCount: 1, agentStatus: .idle)],
            panes: panes, agents: agents, focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: nil
        )
    }

    private func agent(_ kind: String, terminal: String, session: String? = nil) -> HerdrAgent {
        HerdrAgent(paneId: "w1:p0", tabId: "w1:t1", workspaceId: "w1", agent: kind, name: nil, displayAgent: nil,
                   agentStatus: .idle, cwd: "/repo", terminalId: terminal,
                   agentSession: session.map { HerdrAgent.SessionReference(source: nil, agent: kind, kind: "id", value: $0) })
    }

    func testSessionsRunningAtLastObservationAreLostAfterRestart() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        let before = snapshot(agents: [agent("claude", terminal: "term_a"), agent("codex", terminal: "term_b")],
                              terminals: ["term_a", "term_b"])
        var journal = AgentRecovery.record(before, into: [], now: seenAt) { agent, _ in agent.agent == "claude" ? "sess-1" : "cdx-2" }
        XCTAssertEqual(journal.first { $0.agent == "codex" }?.resumeCommand, "codex resume cdx-2")
        XCTAssertEqual(journal.first { $0.agent == "claude" }?.workspaceLabel, "repo")

        // Codex exited earlier while Herd watched: not offered.
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
        // An agent Herd ships no special knowledge of still counts.
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
        setenv("HERD_LIBRARY_DIR", home + "/.agents", 1)
    }

    override func tearDown() {
        unsetenv("HERD_LIBRARY_DIR")
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
    private func snapshot(title: String?, label: String, panes: Int = 1, cwd: String = "/work/app") -> HerdrSnapshot {
        let panes = (0..<panes).map { index in
            HerdrPane(paneId: "w1:p\(index)", tabId: "w1:t1", workspaceId: "w1", focused: index == 0, cwd: cwd,
                      foregroundCwd: nil, agentStatus: .idle, terminalTitle: title, terminalId: "term\(index)")
        }
        return HerdrSnapshot(
            workspaces: [HerdrWorkspace(workspaceId: "w1", number: 1, label: "app", focused: true, paneCount: panes.count,
                                        tabCount: 1, activeTabId: "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: [HerdrTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: label, focused: true,
                            paneCount: panes.count, agentStatus: .idle)],
            panes: panes, agents: [], focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: nil
        )
    }

    func testTitlesBecomeLabelsAndUninformativeOnesDont() {
        XCTAssertEqual(TabAutoName.label(from: "✳ Fix the tab bar lag"), "Fix the tab bar lag")
        XCTAssertEqual(TabAutoName.label(from: "  Rewrite   the parser  "), "Rewrite the parser")
        XCTAssertEqual(TabAutoName.label(from: "jack@mac: ~/Developer/herd"), nil)
        XCTAssertNil(TabAutoName.label(from: "zsh"))
        // An agent naming itself is not a description of the work.
        XCTAssertNil(TabAutoName.label(from: "Claude Code"))
        XCTAssertNil(TabAutoName.label(from: "codex"))
        XCTAssertNil(TabAutoName.label(from: "Claude Code — ~/Developer/herd"))
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
        XCTAssertEqual(ClipboardPreview.summary("herdr --session herd"), "herdr --session herd")
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
    private func snapshot(_ statuses: [(pane: String, status: HerdrAgentStatus)], tabLabel: String = "refactor") -> HerdrSnapshot {
        let agents = statuses.enumerated().map { index, entry in
            HerdrAgent(paneId: entry.pane, tabId: "w1:t\(index + 1)", workspaceId: "w1", agent: "claude", name: nil,
                       displayAgent: nil, agentStatus: entry.status, stateChangeSeq: index, cwd: "/repo",
                       terminalId: "term-\(entry.pane)")
        }
        let tabs = agents.enumerated().map { index, agent in
            HerdrTab(tabId: agent.tabId!, workspaceId: "w1", number: index + 1, label: tabLabel, focused: index == 0,
                     paneCount: 1, agentStatus: agent.agentStatus)
        }
        return HerdrSnapshot(
            workspaces: [HerdrWorkspace(workspaceId: "w1", number: 1, label: "repo", focused: true, paneCount: agents.count,
                                        tabCount: tabs.count, activeTabId: tabs.first?.tabId ?? "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: tabs, panes: [], agents: agents,
            focusedWorkspaceId: "w1", focusedTabId: tabs.first?.tabId, focusedPaneId: nil
        )
    }

    func testFinishingAndBlockingRaiseNoticesButRoutineChangesDont() {
        var watcher = AgentActivityWatcher()
        let start = Date()
        // The first snapshot only records state: no notice for what was
        // already running when Herd opened.
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
    private func workspace(_ id: String, worktree: HerdrWorktree? = nil) -> HerdrWorkspace {
        HerdrWorkspace(workspaceId: id, number: 1, label: id, focused: false, paneCount: 1, tabCount: 1,
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
        let tree = HerdrWorktree(repoRoot: "/repo", branch: "release/2.0", path: "/repo/.worktrees/release-2")
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
        let tree = HerdrWorktree(repoRoot: nil, branch: nil, path: "/repo/.worktrees/spike")
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

    func testProcessInfoParsesWhatHerdrReports() throws {
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

final class TerminalThemeImportTests: XCTestCase {
    func testAGhosttyStyleConfigBecomesATheme() throws {
        let theme = try XCTUnwrap(TerminalThemeImport.parse("""
        # my terminal
        font-family = "Berkeley Mono"
        background = #1a1b26
        foreground = #c0caf5
        cursor-color = #7aa2f7
        palette = 0=#15161e
        palette = 4=#7aa2f7
        palette = 15=#c0caf5
        """, name: "tokyonight"))
        XCTAssertEqual(theme.name, "tokyonight")
        XCTAssertEqual(theme.background, "1a1b26")
        XCTAssertEqual(theme.foreground, "c0caf5")
        XCTAssertEqual(theme.accent, "7aa2f7")
        XCTAssertEqual(theme.ansi[0], "15161e")
        XCTAssertEqual(theme.ansi[15], "c0caf5")
        XCTAssertEqual(theme.ansi.count, 16)
        // Colours the file didn't set are filled in, never left blank.
        XCTAssertFalse(theme.ansi[7].isEmpty)
        XCTAssertFalse(theme.isLight)
    }

    func testLightBackgroundsAndShorthandColoursAreUnderstood() throws {
        let light = try XCTUnwrap(TerminalThemeImport.parse("background = #fff\nforeground = #333", name: "Paper"))
        XCTAssertEqual(light.background, "ffffff")
        XCTAssertEqual(light.foreground, "333333")
        XCTAssertTrue(light.isLight)
        XCTAssertEqual(TerminalThemeImport.hex("'#AABBCC'"), "aabbcc")
        XCTAssertNil(TerminalThemeImport.hex("not-a-colour"))
        // A file with no colours isn't a theme.
        XCTAssertNil(TerminalThemeImport.parse("font-size = 13", name: "x"))
    }

    func testAConfigThatOnlyNamesAThemeIsFollowed() {
        XCTAssertEqual(TerminalThemeImport.themeName(in: "theme = catppuccin-mocha"), "catppuccin-mocha")
        // The split form picks the dark one, which is what Herd defaults to.
        XCTAssertEqual(TerminalThemeImport.themeName(in: "theme = light:rosepine-dawn,dark:rosepine"), "rosepine")
        XCTAssertNil(TerminalThemeImport.themeName(in: "background = #000"))
    }
}

final class TwinUsageTests: XCTestCase {
    func testContextInPlayComesFromTheNewestTurn() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"model":"claude-opus-5","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":1000,"cache_read_input_tokens":9000,"output_tokens":200}}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"model":"claude-opus-5","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":2000,"cache_read_input_tokens":60000,"output_tokens":300}}}"#,
        ]
        let usage = try? XCTUnwrap(TwinTranscript.parseClaude(lines: lines).usage)
        // Totals accumulate; the context in play is the latest turn's input.
        XCTAssertEqual(usage?.outputTokens, 500)
        XCTAssertEqual(usage?.currentContextTokens, 62_000)
        XCTAssertEqual(usage?.contextWindow, 200_000)
        XCTAssertEqual(usage?.label, "31%")
    }

    func testAKnownWindowGivesAPercentAndAnUnknownOneGivesTokens() {
        var usage = TwinUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 0,
                              contextWindow: nil, currentContextTokens: 52_000)
        XCTAssertEqual(usage.label, "52k")
        XCTAssertNil(usage.contextFraction)
        usage.contextWindow = 272_000
        XCTAssertEqual(usage.label, "19%")
        // Nothing to say yet reads as nothing, not as zero percent.
        XCTAssertEqual(TwinUsage().label, "")
        XCTAssertEqual(TwinUsage.compact(950), "950")
        XCTAssertEqual(TwinUsage.compact(1_500_000), "1.5M")
        XCTAssertEqual(TwinUsage.window(forModel: "claude-opus-5[1m]"), 1_000_000)
        XCTAssertNil(TwinUsage.window(forModel: "gpt-6-astra"))
    }
}
