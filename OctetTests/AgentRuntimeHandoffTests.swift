import XCTest

final class AgentRuntimeHandoffTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func use(_ id: String, _ name: String, _ input: [String: Any], at time: String) -> String {
        json(["type": "assistant", "timestamp": time,
              "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    private func result(_ id: String, _ text: String, _ toolUseResult: [String: Any], at time: String) -> String {
        json(["type": "user", "timestamp": time, "toolUseResult": toolUseResult,
              "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": text]]]])
    }

    private func notification(tool: String, task: String, status: String?, at time: String) -> String {
        var body = "<task-notification>\n<task-id>\(task)</task-id>\n<tool-use-id>\(tool)</tool-use-id>\n"
        if let status { body += "<status>\(status)</status>\n" }
        body += "<summary>done</summary>\n</task-notification>"
        return json(["type": "attachment", "timestamp": time,
                     "attachment": ["type": "queued_command", "prompt": body, "commandMode": "task-notification"]])
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-23T12:10:00Z")!

    func testFindsLiveBackgroundCommandsMonitorsAndSubagents() {
        let lines = [
            use("t1", "Bash", ["command": "npm run dev", "description": "Dev server", "run_in_background": true], at: "2026-09-23T12:00:00Z"),
            result("t1", "Command running in background with ID: b1", ["backgroundTaskId": "b1"], at: "2026-09-23T12:00:01Z"),
            use("t2", "Bash", ["command": "make test", "run_in_background": true], at: "2026-09-23T12:00:02Z"),
            result("t2", "Command running in background with ID: b2", ["backgroundTaskId": "b2"], at: "2026-09-23T12:00:03Z"),
            notification(tool: "t2", task: "b2", status: "completed", at: "2026-09-23T12:01:00Z"),
            use("t3", "Monitor", ["command": "tail -f log", "description": "Watch deploy", "timeout_ms": 1_800_000], at: "2026-09-23T12:02:00Z"),
            result("t3", "Monitor started (task m1)", ["taskId": "m1", "timeoutMs": 1_800_000], at: "2026-09-23T12:02:01Z"),
            notification(tool: "t3", task: "m1", status: nil, at: "2026-09-23T12:03:00Z"),
            use("t4", "Agent", ["description": "Audit API", "prompt": "Audit it"], at: "2026-09-23T12:04:00Z"),
            result("t4", "Async agent launched", ["status": "async_launched", "agentId": "a1"], at: "2026-09-23T12:04:01Z"),
            use("t5", "Agent", ["description": "Write docs", "prompt": "Docs"], at: "2026-09-23T12:05:00Z"),
            use("t6", "Bash", ["command": "sleep 99", "run_in_background": true], at: "2026-09-23T12:06:00Z"),
            result("t6", "Command running in background with ID: b6", ["backgroundTaskId": "b6"], at: "2026-09-23T12:06:01Z"),
            use("t7", "TaskStop", ["task_id": "b6"], at: "2026-09-23T12:07:00Z"),
        ]
        let live = AgentRuntimeHandoff.liveRuntimes(lines: lines, processStart: nil, now: now)
        XCTAssertEqual(live.map(\.id), ["t1", "t3", "t4", "t5"])
        XCTAssertEqual(live.map(\.kind), [.task, .monitor, .agent, .agent])
        XCTAssertEqual(live[0].command, "npm run dev")
        XCTAssertEqual(live[0].title, "Dev server")
        XCTAssertEqual(live[3].title, "Write docs")
        XCTAssertEqual(AgentRuntimeHandoff.summary(live), "a background command, a monitor and 2 subagents")
    }

    func testSkipsWorkFromEarlierProcessesAndExpiredMonitors() {
        let lines = [
            use("old", "Bash", ["command": "old server", "run_in_background": true], at: "2026-09-23T09:00:00Z"),
            result("old", "running", ["backgroundTaskId": "b0"], at: "2026-09-23T09:00:01Z"),
            use("m", "Monitor", ["command": "watch", "timeout_ms": 60_000], at: "2026-09-23T12:05:00Z"),
            result("m", "Monitor started", ["taskId": "m2", "timeoutMs": 60_000], at: "2026-09-23T12:05:01Z"),
            use("new", "Bash", ["command": "new server", "run_in_background": true], at: "2026-09-23T12:06:00Z"),
            result("new", "running", ["backgroundTaskId": "b3"], at: "2026-09-23T12:06:01Z"),
        ]
        let processStart = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")
        let live = AgentRuntimeHandoff.liveRuntimes(lines: lines, processStart: processStart, now: now)
        XCTAssertEqual(live.map(\.id), ["new"])
    }

    func testContinuationPromptOnlyWhenSomethingWasCutOff() {
        XCTAssertNil(AgentRuntimeHandoff.continuationPrompt([], turnInterrupted: false))
        XCTAssertNotNil(AgentRuntimeHandoff.continuationPrompt([], turnInterrupted: true))
        let runtime = HandoffRuntime(id: "t1", kind: .task, title: "Dev server", command: "npm run dev",
                                     prompt: nil, startedAt: nil, expiresAt: nil)
        let prompt = AgentRuntimeHandoff.continuationPrompt([runtime], turnInterrupted: false) ?? ""
        XCTAssertTrue(prompt.contains("Background command \"Dev server\": `npm run dev`"))
        XCTAssertTrue(prompt.contains("run_in_background"))
    }

    func testLedgerReadsIncrementallyAndTreatsErroredLaunchesAsDone() {
        var ledger = RuntimeLedger()
        ledger.consume(use("a", "Agent", ["description": "Review", "prompt": "Look"], at: "2026-09-23T12:00:00Z"))
        XCTAssertEqual(ledger.live(processStart: nil, now: now).map(\.id), ["a"])
        XCTAssertEqual(ledger.live(processStart: nil, now: now).first?.prompt, "Look")
        ledger.consume(json(["type": "user", "timestamp": "2026-09-23T12:00:05Z",
                             "message": ["content": [["type": "tool_result", "tool_use_id": "a",
                                                      "content": "Interrupted", "is_error": true]]]]))
        XCTAssertTrue(ledger.live(processStart: nil, now: now).isEmpty)
        ledger.consume(use("r", "Read", ["file_path": "/tmp/x"], at: "2026-09-23T12:01:00Z"))
        XCTAssertTrue(ledger.live(processStart: nil, now: now).isEmpty)
    }

    func testProcessStartOfThisProcess() {
        let start = AgentRuntimeHandoff.processStart(pid: Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNotNil(start)
        XCTAssertLessThan(start ?? .distantFuture, Date())
    }
}
