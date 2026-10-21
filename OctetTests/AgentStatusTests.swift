import XCTest

final class AgentStatusTests: XCTestCase {
    func testEngineStatusesMapOntoTheVocabulary() {
        XCTAssertEqual(AgentState(.blocked), .needsInput)
        XCTAssertEqual(AgentState(.working), .working)
        XCTAssertEqual(AgentState(.done), .done)
        XCTAssertEqual(AgentState(.idle), .idle)
        XCTAssertEqual(AgentState(.unknown), .unknown)
        for status in [EngineAgentStatus.idle, .working, .blocked, .done, .unknown] {
            XCTAssertEqual(AgentState(status).engineStatus, status, "round trip for \(status)")
        }
    }

    func testOneWordAndOneToneForNeedsYou() {
        XCTAssertEqual(AgentState.needsInput.title, "Needs input")
        XCTAssertEqual(AgentState.needsInput.label, "needs input")
        XCTAssertEqual(AgentState.needsApproval.tone, .warning)
        XCTAssertEqual(AgentState.needsInput.tone, .warning)
        XCTAssertEqual(AgentState.failed.tone, .danger)
        XCTAssertEqual(AgentState.done.tone, .success)
        XCTAssertEqual(AgentState.idle.tone, .muted)
        XCTAssertTrue(AgentState.needsApproval.needsYou)
        XCTAssertFalse(AgentState.failed.needsYou)
        XCTAssertEqual(AgentState.unknown.title, "")
    }

    func testRollUpFollowsT3Priorities() {
        XCTAssertEqual(AgentState.rollUp([.done, .working, .needsInput]), .needsInput)
        XCTAssertEqual(AgentState.rollUp([.needsInput, .needsApproval]), .needsApproval)
        XCTAssertEqual(AgentState.rollUp([.working, .failed]), .failed)
        XCTAssertEqual(AgentState.rollUp([.planReady, .waiting]), .waiting)
        XCTAssertEqual(AgentState.rollUp([.done, .planReady]), .planReady)
        XCTAssertEqual(AgentState.rollUp([.idle, .unknown]), .idle)
        XCTAssertEqual(AgentState.rollUp([]), .unknown)
    }

    func testConversationStateOrder() {
        XCTAssertEqual(AgentState.conversation(pendingPermission: true, pendingQuestion: true, isRunning: true), .needsApproval)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: true, isRunning: true), .needsInput)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: false, isRunning: true, failed: true), .working)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: false, isRunning: false, failed: true), .failed)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: false, isRunning: false, planReady: true), .planReady)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: false, isRunning: false, unseenFinish: true), .done)
        XCTAssertEqual(AgentState.conversation(pendingPermission: false, pendingQuestion: false, isRunning: false), .idle)
    }

    func testBuckets() {
        XCTAssertEqual(AgentState.needsApproval.bucket, .needsYou)
        XCTAssertEqual(AgentState.failed.bucket, .needsYou)
        XCTAssertEqual(AgentState.waiting.bucket, .working)
        XCTAssertEqual(AgentState.unknown.bucket, .idle)
        XCTAssertEqual(AgentState.done.bucket, .done)
        XCTAssertEqual(AgentState.Bucket.allCases.map(\.title), ["Needs You", "Working", "Idle", "Done"])
    }

    func testContextLevelsShareOneSetOfThresholds() {
        XCTAssertEqual(ContextLevel(fraction: nil), .normal)
        XCTAssertEqual(ContextLevel(fraction: 0.79), .normal)
        XCTAssertEqual(ContextLevel(fraction: 0.8), .warning)
        XCTAssertEqual(ContextLevel(fraction: 0.949), .warning)
        XCTAssertEqual(ContextLevel(fraction: 0.95), .danger)
        XCTAssertEqual(ContextLevel(fraction: 1.2), .danger)
    }
}

final class AttentionRoutingTests: XCTestCase {
    private func context(_ setting: AttentionRouting.Setting = .inOctet, active: Bool = true, onScreen: Bool = false,
                         engine: Bool = true, notch: Bool = false, system: Bool = true) -> AttentionRouting.Context {
        .init(setting: setting, appActive: active, onScreen: onScreen, fromSessionServer: engine,
              notchPeeks: notch, systemAllowed: system)
    }

    func testOneNoticePerEvent() {
        XCTAssertEqual(AttentionRouting.delivery(context(onScreen: true)), .none)
        XCTAssertEqual(AttentionRouting.delivery(context()), .banner)
        XCTAssertEqual(AttentionRouting.delivery(context(active: false)), .systemNotification)
        XCTAssertEqual(AttentionRouting.delivery(context(active: false, notch: true)), .notchPeek)
        XCTAssertEqual(AttentionRouting.delivery(context(active: false, system: false)), .dockBounce)
    }

    func testSettingsAreRespected() {
        XCTAssertEqual(AttentionRouting.delivery(context(.off, active: false)), .none)
        XCTAssertEqual(AttentionRouting.delivery(context(.off)), .none)
        // The session server already posted the system notification.
        XCTAssertEqual(AttentionRouting.delivery(context(.system, active: false)), .none)
        // It can't for Octet's own conversations.
        XCTAssertEqual(AttentionRouting.delivery(context(.system, active: false, engine: false)), .systemNotification)
        XCTAssertEqual(AttentionRouting.delivery(context(.system, engine: false)), .banner)
    }

    func testNotificationTitle() {
        XCTAssertEqual(AttentionRouting.title(repo: "api", workspace: "fix-login", agent: "Claude Code", state: "needs input"),
                       "api / fix-login — Claude Code needs input")
        XCTAssertEqual(AttentionRouting.title(repo: "api", workspace: "API", agent: "Codex", state: "finished"),
                       "api — Codex finished")
        XCTAssertEqual(AttentionRouting.title(repo: nil, workspace: nil, agent: "Codex", state: "finished"), "Codex finished")
    }

    func testDockBadge() {
        XCTAssertNil(AttentionRouting.dockBadge(agentsNeedingYou: 0, readyWork: 0))
        XCTAssertEqual(AttentionRouting.dockBadge(agentsNeedingYou: 2, readyWork: 1), "3")
        XCTAssertEqual(AttentionRouting.identifier(agentKey: "chat:1"), "octet.agent.chat:1")
    }

    func testConversationTransitions() {
        var watcher = ConversationActivityWatcher()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(watcher.transitions(["a": .working, "b": .idle], now: start), [], "the first look only records")
        let asked = watcher.transitions(["a": .needsApproval, "b": .idle], now: start.addingTimeInterval(30))
        XCTAssertEqual(asked, [.init(id: "a", kind: .needsInput, state: .needsApproval, workedFor: 30)])
        XCTAssertEqual(watcher.transitions(["a": .working, "b": .idle], now: start.addingTimeInterval(40)), [])
        let finished = watcher.transitions(["a": .done, "b": .idle], now: start.addingTimeInterval(100))
        XCTAssertEqual(finished, [.init(id: "a", kind: .finished, state: .done, workedFor: 60)])
        // A question while it was already waiting on an approval isn't news.
        _ = watcher.transitions(["a": .needsApproval], now: start.addingTimeInterval(110))
        XCTAssertEqual(watcher.transitions(["a": .needsInput], now: start.addingTimeInterval(120)), [])
    }

    func testEventPhrase() {
        var event = AgentEvent(id: "1", kind: .needsInput, agent: "claude", paneId: "p", tabId: nil, workspaceId: nil,
                               label: "x", workedFor: nil, at: Date(), state: .needsApproval)
        XCTAssertEqual(event.phrase, "needs approval")
        XCTAssertEqual(event.agentKey, "pane:p")
        event.sessionId = "s"
        XCTAssertEqual(event.agentKey, "chat:s")
        let finished = AgentEvent(id: "2", kind: .finished, agent: nil, paneId: "p", tabId: nil, workspaceId: nil,
                                  label: "x", workedFor: nil, at: Date())
        XCTAssertEqual(finished.phrase, "finished")
    }
}

final class TranscriptTailTests: XCTestCase {
    func testLinesCarryAnUnfinishedLineOver() {
        var tail = TranscriptLineTail()
        XCTAssertEqual(tail.lines(in: "a\nb"), ["a"])
        XCTAssertEqual(tail.lines(in: "c\n\nd\n"), ["bc", "d"])
        XCTAssertEqual(tail.lines(in: ""), [])
    }

    func testPullReadsOnlyWhatIsNew() throws {
        let path = NSTemporaryDirectory() + "octet-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "one\ntwo\n".write(toFile: path, atomically: false, encoding: .utf8)
        var tail = TranscriptLineTail()
        XCTAssertEqual(tail.pull(path: path), .appended(["one", "two"]))
        XCTAssertEqual(tail.pull(path: path), .unchanged)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data("thr".utf8))
        XCTAssertEqual(tail.pull(path: path), .unchanged, "half a line waits")
        handle.write(Data("ee\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.pull(path: path), .appended(["three"]))
        try "new\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(tail.pull(path: path), .restarted(["new"]))
    }

    func testFirstPullOfALongFileStartsOnALine() throws {
        let path = NSTemporaryDirectory() + "octet-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "aaaaaaaa\nbbbb\ncccc\n".write(toFile: path, atomically: false, encoding: .utf8)
        var tail = TranscriptLineTail()
        XCTAssertEqual(tail.pull(path: path, firstReadBytes: 8), .appended(["cccc"]))
        XCTAssertTrue(tail.startedMidway)
    }

    func testAppendingReplayMatchesAWholeReplay() {
        let lines = [
            #"{"type":"user","sessionId":"s9","cwd":"/tmp/p","uuid":"u1","message":{"role":"user","content":"Fix it"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/p/a","old_string":"x","new_string":"y"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        ]
        var appended = AgentConversation()
        appended.replay(appending: Array(lines.prefix(2)))
        appended.replay(appending: Array(lines.suffix(1)))
        let whole = AgentConversation.replay(lines: lines)
        // Items carry the moment they were made; what they say must match.
        XCTAssertEqual(appended.items.map(\.id), whole.items.map(\.id))
        XCTAssertEqual(appended.items.map(\.kind), whole.items.map(\.kind))
        XCTAssertEqual(appended.sessionId, "s9")
        guard case .tool(let call) = appended.items.last?.kind else { return XCTFail("expected the edit") }
        XCTAssertEqual(call.result, "ok", "a result in a later batch finds its call")
    }
}
