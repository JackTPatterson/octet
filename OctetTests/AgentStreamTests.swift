import XCTest

final class AgentStreamTests: XCTestCase {
    private func stream(_ inner: [String: Any]) -> [String: Any] {
        ["type": "stream_event", "event": inner, "parent_tool_use_id": NSNull()]
    }

    func testDeltasBuildTextAndFinalCopyIsNotDrawnTwice() {
        var conversation = AgentConversation()
        conversation.appendUser("hi")
        conversation.apply(["type": "system", "subtype": "init", "session_id": "s1", "model": "claude-haiku",
                            "permissionMode": "default", "slash_commands": ["model", "rename"]])
        conversation.apply(stream(["type": "message_start", "message": ["id": "m1", "usage": ["input_tokens": 10, "cache_read_input_tokens": 90]]]))
        conversation.apply(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
        conversation.apply(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hel"]]))
        conversation.apply(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "lo"]]))
        conversation.apply(["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "Hello"]]]])
        conversation.apply(["type": "result", "subtype": "success", "total_cost_usd": 0.01,
                            "modelUsage": ["claude-haiku": ["contextWindow": 200_000]]])

        XCTAssertEqual(conversation.sessionId, "s1")
        XCTAssertEqual(conversation.slashCommands, ["model", "rename"])
        XCTAssertEqual(conversation.items.map(\.kind), [.user("hi"), .text("Hello")])
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(conversation.costUSD, 0.01)
        XCTAssertEqual(conversation.contextUsed, 100)
        XCTAssertEqual(conversation.contextWindow, 200_000)
    }

    func testToolCallGetsInputThenResult() {
        var conversation = AgentConversation()
        conversation.apply(stream(["type": "message_start", "message": ["id": "m2"]]))
        conversation.apply(stream(["type": "content_block_start", "index": 0,
                                   "content_block": ["type": "tool_use", "id": "t1", "name": "Bash"]]))
        conversation.apply(["type": "assistant", "message": ["id": "m2", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls -la\necho two"]],
        ]]])
        conversation.apply(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "total 0"]], "is_error": false],
        ]]])

        guard case .tool(let call) = conversation.items.first?.kind else { return XCTFail("expected a tool call") }
        XCTAssertEqual(conversation.items.count, 1)
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.summary, "ls -la")
        XCTAssertEqual(call.result, "total 0")
        XCTAssertFalse(call.isError)
    }

    func testSubagentItemsKeepTheirParent() {
        var conversation = AgentConversation()
        conversation.apply(["type": "assistant", "parent_tool_use_id": "agent-1",
                            "message": ["id": "m3", "content": [["type": "text", "text": "from the subagent"]]]])
        XCTAssertEqual(conversation.items.first?.parent, "agent-1")
        XCTAssertEqual(conversation.items.first?.kind, .text("from the subagent"))
    }

    func testInterruptedTurnSaysStopped() {
        var conversation = AgentConversation()
        conversation.appendUser("count")
        conversation.apply(["type": "result", "subtype": "error_during_execution"])
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(conversation.items.last?.kind, .notice("Stopped"))
        XCTAssertNil(conversation.lastError)
    }

    func testPermissionMCPServesTheApproveTool() throws {
        let initialize = PermissionMCP.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#) { _ in [:] }
        XCTAssertTrue(initialize?.contains("\"octet\"") == true)
        XCTAssertNil(PermissionMCP.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) { _ in [:] })

        let list = try XCTUnwrap(PermissionMCP.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) { _ in [:] })
        XCTAssertTrue(list.contains("\"approve\""))

        var asked: [String: Any]?
        let call = try XCTUnwrap(PermissionMCP.respond(
            to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"touch x"}}}}"#
        ) { arguments in
            asked = arguments
            return ["behavior": "deny", "message": "no"]
        })
        XCTAssertEqual(asked?["tool_name"] as? String, "Bash")
        XCTAssertTrue(call.contains("deny"))
        XCTAssertEqual(PermissionMCP.qualifiedToolName, "mcp__octet__approve")
    }

    func testAllowEchoesTheInputUnchanged() throws {
        let request = try XCTUnwrap(AgentPermissionRequest(json: [
            "tool_name": "Edit", "tool_use_id": "t9",
            "input": ["file_path": "/tmp/a", "edits": [["old": "x", "new": "y"]]],
        ]))
        XCTAssertEqual(request.summary, "/tmp/a")
        let decision = AgentPermissionRequest.decision(allow: true, input: request.inputObject, message: nil)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let edits = (decision["updatedInput"] as? [String: Any])?["edits"] as? [[String: String]]
        XCTAssertEqual(edits?.first?["new"], "y")
        let deny = AgentPermissionRequest.decision(allow: false, input: [:], message: "")
        XCTAssertEqual(deny["message"] as? String, "The user declined this in Octet.")
    }

    func testSocketRoundTrip() throws {
        let path = NSTemporaryDirectory() + "octet-perm-test-\(UUID().uuidString.prefix(6)).sock"
        let server = PermissionSocketServer(path: path)
        try server.start { prompt, reply in
            reply(["behavior": prompt["tool_name"] as? String == "Bash" ? "allow" : "deny"])
        }
        defer { server.stop() }

        let answered = expectation(description: "decision")
        var decision: [String: Any] = [:]
        DispatchQueue.global().async {
            decision = PermissionMCP.askApp(socketPath: path, arguments: ["tool_name": "Bash", "input": [:]])
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(decision["behavior"] as? String, "allow")

        // With nobody listening, the prompt is denied rather than allowed.
        let missing = PermissionMCP.askApp(socketPath: path + ".gone", arguments: ["tool_name": "Bash", "input": [:]])
        XCTAssertEqual(missing["behavior"] as? String, "deny")
    }
}

final class TranscriptParsingTests: XCTestCase {
    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.parse("""
        ## Title

        Some **bold** text
        continued here.

        1. first
        2. second
           - nested

        > quoted
        > more

        ```swift
        let x = 1
        ```
        ---
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Title"),
            .paragraph("Some **bold** text\ncontinued here."),
            .listItem(ordinal: 1, depth: 0, text: "first"),
            .listItem(ordinal: 2, depth: 0, text: "second"),
            .listItem(ordinal: nil, depth: 1, text: "nested"),
            .quote("quoted\nmore"),
            .code(language: "swift", text: "let x = 1"),
            .rule,
        ])
    }

    func testUnclosedFenceStillShowsCode() {
        XCTAssertEqual(MarkdownBlock.parse("Here:\n```\npartial"), [.paragraph("Here:"), .code(language: nil, text: "partial")])
    }

    func testLineDiffTrimsToContext() {
        let lines = LineDiff.lines(old: "a\nb\nc\nd\ne", new: "a\nb\nX\nd\ne", context: 1)
        XCTAssertEqual(lines, [
            .init(kind: .context, text: "b"),
            .init(kind: .removed, text: "c"),
            .init(kind: .added, text: "X"),
            .init(kind: .context, text: "d"),
        ])
    }

    func testToolDiffs() {
        let edit = AgentToolCall.diff(tool: "Edit", input: ["old_string": "one", "new_string": "two"])
        XCTAssertEqual(edit, [.init(kind: .removed, text: "one"), .init(kind: .added, text: "two")])
        let write = AgentToolCall.diff(tool: "Write", input: ["file_path": "/a", "content": "x\ny"])
        XCTAssertEqual(write?.count, 2)
        XCTAssertNil(AgentToolCall.diff(tool: "Bash", input: ["command": "ls"]))
    }
}

final class ConversationReplayTests: XCTestCase {
    func testReplayRebuildsTurnsAndSkipsBookkeeping() {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s9"}"#,
            #"{"type":"user","sessionId":"s9","cwd":"/tmp/p","uuid":"u1","message":{"role":"user","content":"Fix it"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"caveat"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/p/a","old_string":"x","new_string":"y"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        ]
        let conversation = AgentConversation.replay(lines: lines)
        XCTAssertEqual(conversation.sessionId, "s9")
        XCTAssertEqual(conversation.cwd, "/tmp/p")
        XCTAssertEqual(conversation.items.count, 3)
        XCTAssertEqual(conversation.items[0].kind, .user("Fix it"))
        XCTAssertEqual(conversation.items[1].kind, .text("On it."))
        guard case .tool(let call) = conversation.items[2].kind else { return XCTFail("expected the edit") }
        XCTAssertEqual(call.result, "ok")
        XCTAssertEqual(call.diff?.count, 2)
        XCTAssertFalse(conversation.isRunning)
    }

    func testLogPathMatchesClaudeCodesFolderNaming() {
        XCTAssertEqual(AgentConversation.claudeLogPath(sessionId: "abc", cwd: "/Users/me/my.app", home: "/Users/me"),
                       "/Users/me/.claude/projects/-Users-me-my-app/abc.jsonl")
    }
}

final class MarkdownTableTests: XCTestCase {
    func testPipeTable() {
        XCTAssertEqual(MarkdownBlock.parse("| A | B |\n|---|:-:|\n| 1 | 2 |\n\nafter"), [
            .table(header: ["A", "B"], rows: [["1", "2"]]),
            .paragraph("after"),
        ])
    }

    func testPipesWithoutSeparatorStayText() {
        XCTAssertEqual(MarkdownBlock.parse("| not | a table |"), [.paragraph("| not | a table |")])
    }
}

final class AgentAccountTests: XCTestCase {
    func testClaudeSubscriptionAndApiKey() {
        let max = AgentAccounts.claude(authStatus: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#.utf8))
        XCTAssertEqual(max.kind, .subscription)
        XCTAssertEqual(max.plan, "Max")
        let key = AgentAccounts.claude(authStatus: Data(#"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}"#.utf8))
        XCTAssertEqual(key.kind, .apiKey)
        XCTAssertEqual(AgentAccounts.claude(authStatus: Data(#"{"loggedIn":false}"#.utf8)).kind, .signedOut)
    }

    func testCodexLoginStatus() {
        XCTAssertEqual(AgentAccounts.codex(loginStatus: "Logged in using ChatGPT").kind, .subscription)
        XCTAssertEqual(AgentAccounts.codex(loginStatus: "Logged in using an API key - sk-...").kind, .apiKey)
        XCTAssertEqual(AgentAccounts.codex(loginStatus: "Not logged in").kind, .signedOut)
    }

    func testClaudeRateLimitEvent() {
        let windows = AgentAccounts.claudeWindows(rateLimitInfo: [
            "status": "allowed", "rateLimitType": "five_hour",
            "unifiedWindows": ["seven_day": ["utilization": 0.55, "resetsAt": 1_790_082_000.0],
                               "five_hour": ["utilization": 0.06, "resetsAt": 1_789_863_000.0]],
        ])
        XCTAssertEqual(windows.map(\.name), ["5h", "7d"])
        XCTAssertEqual(windows.first?.used, 0.06)
    }

    func testClaudeAccountUsage() {
        let payload: [String: Any] = [
            "five_hour": ["utilization": 15.0, "resets_at": "2026-09-21T17:50:00.291967+00:00"],
            "limits": [
                ["kind": "session", "percent": 15.0, "resets_at": "2026-09-21T17:50:00.291967+00:00"],
                ["kind": "weekly_all", "percent": 66.0, "resets_at": "2026-09-22T13:00:00.291997+00:00"],
                ["kind": "weekly_scoped", "percent": 8.0, "resets_at": "2026-09-22T13:00:00.292380+00:00",
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ]
        let windows = AgentAccounts.claudeWindows(utilization: payload)
        XCTAssertEqual(windows.map(\.name), ["5h", "7d", "7d Fable"])
        XCTAssertEqual(windows[1].used, 0.66)
        XCTAssertNotNil(windows.first?.resetsAt)

        // Percentages arrive as 0...100, and the cache wraps the same shape.
        let cached = AgentAccounts.claudeWindows(cachedUsage: ["fetchedAtMs": 1_789_431_122_383.0, "utilization": payload])
        XCTAssertEqual(cached?.0.count, 3)
        XCTAssertEqual(cached?.1?.timeIntervalSince1970 ?? 0, 1_789_431_122.383, accuracy: 0.01)
        XCTAssertNil(AgentAccounts.claudeWindows(cachedUsage: ["utilization": ["limits": []]]))
    }

    func testWindowsRetireWhenTheyReset() {
        let past = UsageWindow(name: "7d", used: 1, resetsAt: Date().addingTimeInterval(-3600))
        let future = UsageWindow(name: "5h", used: 0.2, resetsAt: Date().addingTimeInterval(3600))
        var account = AgentAccount(agent: "codex", kind: .subscription, windows: [past, future], updatedAt: Date())
        XCTAssertEqual(account.live.map(\.name), ["5h"])
        XCTAssertNil(account.expiredAt)

        account.windows = [past]
        XCTAssertTrue(account.live.isEmpty)
        XCTAssertEqual(account.expiredAt, past.resetsAt)

        // A window with no reset of its own goes stale with its reading.
        let undated = UsageWindow(name: "5h", used: 0, resetsAt: nil)
        account.windows = [undated]
        XCTAssertEqual(account.live.count, 1)
        account.updatedAt = Date().addingTimeInterval(-AgentAccount.readingLifetime - 1)
        XCTAssertTrue(account.live.isEmpty)
    }

    func testCodexConversationStream() {
        var conversation = AgentConversation()
        conversation.applyCodex(["method": "thread/started",
                                 "params": ["thread": ["id": "01a0", "model": "gpt-6-astra", "cwd": "/tmp/work"]]])
        XCTAssertEqual(conversation.sessionId, "01a0")
        XCTAssertEqual(conversation.cwd, "/tmp/work")

        conversation.applyCodex(["method": "turn/started", "params": ["threadId": "01a0"]])
        XCTAssertTrue(conversation.isRunning)

        // The user's own message is already in the transcript.
        conversation.applyCodex(["method": "item/completed", "params": ["item": [
            "type": "userMessage", "id": "u1", "content": [["type": "text", "text": "hi"]],
        ]]])
        XCTAssertTrue(conversation.items.isEmpty)

        // A reply arrives as deltas, then once more in full.
        conversation.applyCodex(["method": "item/agentMessage/delta", "params": ["itemId": "m1", "delta": "ok"]])
        conversation.applyCodex(["method": "item/agentMessage/delta", "params": ["itemId": "m1", "delta": "!"]])
        XCTAssertEqual(conversation.items.map(\.kind), [.text("ok!")])
        conversation.applyCodex(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "m1", "text": "ok!"]]])
        XCTAssertEqual(conversation.items.count, 1)

        // A command runs, then finishes with its output on the same item.
        conversation.applyCodex(["method": "item/started", "params": ["item": [
            "type": "commandExecution", "id": "e1", "command": "/bin/zsh -lc 'echo hi'", "status": "inProgress",
            "commandActions": [["command": "echo hi"]],
        ]]])
        guard case .tool(let running)? = conversation.items.last?.kind else { return XCTFail("no tool item") }
        XCTAssertEqual(running.name, "Bash")
        XCTAssertEqual(running.summary, "echo hi")
        XCTAssertNil(running.result)

        conversation.applyCodex(["method": "item/completed", "params": ["item": [
            "type": "commandExecution", "id": "e1", "command": "/bin/zsh -lc 'echo hi'", "status": "completed",
            "commandActions": [["command": "echo hi"]], "aggregatedOutput": "hi\n", "exitCode": 0,
        ]]])
        XCTAssertEqual(conversation.items.count, 2)
        guard case .tool(let done)? = conversation.items.last?.kind else { return XCTFail("no tool item") }
        XCTAssertEqual(done.result, "hi\n")
        XCTAssertFalse(done.isError)

        conversation.applyCodex(["method": "thread/tokenUsage/updated",
                                 "params": ["tokenUsage": ["total": ["totalTokens": 14299]]]])
        XCTAssertEqual(conversation.contextUsed, 14299)

        conversation.applyCodex(["method": "account/rateLimits/updated", "params": ["rateLimits": [
            "primary": ["usedPercent": 3.0, "windowDurationMins": 10080.0, "resetsAt": 1_790_603_986.0],
        ]]])
        XCTAssertEqual(conversation.usageWindows.map(\.name), ["7d"])

        conversation.applyCodex(["method": "turn/completed", "params": ["threadId": "01a0"]])
        XCTAssertFalse(conversation.isRunning)
    }

    func testCodexFailedTurnIsReported() {
        var conversation = AgentConversation()
        conversation.applyCodex(["method": "turn/started", "params": [:]])
        conversation.applyCodex(["method": "turn/failed", "params": ["error": ["message": "Out of credits"]]])
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(conversation.lastError, "Out of credits")
        XCTAssertEqual(conversation.items.map(\.kind), [.notice("Out of credits")])
    }

    func testCodexAppServerRateLimits() {
        // The app server answers in camel case, with a null second window.
        let limits: [String: Any] = [
            "primary": ["usedPercent": 12.0, "windowDurationMins": 10080.0, "resetsAt": 1_790_603_986.0],
            "secondary": NSNull(),
        ]
        let windows = AgentAccounts.codexWindows(rateLimits: limits)
        XCTAssertEqual(windows.map(\.name), ["7d"])
        XCTAssertEqual(windows.first?.used, 0.12)
        XCTAssertEqual(windows.first?.resetsAt?.timeIntervalSince1970, 1_790_603_986)
        XCTAssertTrue(AgentAccounts.codexWindows(rateLimits: ["primary": NSNull()]).isEmpty)
    }

    func testCodexSessionRateLimits() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":null,"secondary":null}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1789938893},"secondary":{"used_percent":7.5,"window_minutes":300,"resets_at":1789900000}}}}"#,
        ]
        let windows = AgentAccounts.codexWindows(sessionLines: lines)
        XCTAssertEqual(windows?.map(\.name), ["5h", "7d"])
        XCTAssertEqual(windows?.last?.used, 0.42)
    }
}

final class BackgroundAgentTests: XCTestCase {
    func testParsesAgentsList() {
        let json = #"[{"id":"e052046f","cwd":"/Users/me/app","kind":"background","startedAt":"1786568120453","sessionId":"e052046f-ea5e","name":"Investigate data","state":"blocked"},{"pid":"48993","cwd":"/Users/me/other","kind":"interactive","startedAt":"1789507985407","sessionId":"7ac176ba","name":"","status":"idle"}]"#
        let agents = BackgroundAgent.parse(Data(json.utf8))
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents[0].id, "e052046f")
        XCTAssertEqual(agents[0].state, .needsInput)
        XCTAssertEqual(agents[0].kind, .background)
        XCTAssertEqual(agents[0].startedAt?.timeIntervalSince1970 ?? 0, 1_786_568_120.453, accuracy: 0.01)
        XCTAssertEqual(agents[1].kind, .interactive)
        XCTAssertEqual(agents[1].name, "Untitled session")
        XCTAssertEqual(agents[1].pid, 48993)
        XCTAssertEqual(agents[1].id, "7ac176ba")
    }

    func testUnknownStatesReadAsIdle() {
        XCTAssertEqual(BackgroundAgent.state("working"), .working)
        XCTAssertEqual(BackgroundAgent.state("something-new"), .idle)
        XCTAssertTrue(BackgroundAgent.parse(Data("not json".utf8)).isEmpty)
    }
}

final class CodexThreadTests: XCTestCase {
    func testParsesThreadRows() {
        let json = #"[{"id":"t1","rollout_path":"/r/1.jsonl","cwd":"/w","title":"Fix build","name":null,"preview":"done","first_user_message":"fix it","updated_at_ms":1789938893000,"created_at_ms":1789900000000,"model":"gpt-5"}]"#
        let threads = CodexThreads.parse(Data(json.utf8))
        XCTAssertEqual(threads.first?.name, "Fix build")
        XCTAssertEqual(threads.first?.updatedAt?.timeIntervalSince1970 ?? 0, 1_789_938_893, accuracy: 1)
    }

    func testStateFromTail() {
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let done = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        let approval = #"{"type":"event_msg","payload":{"type":"exec_approval_request"}}"#
        let tokens = #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        let now = Date()
        XCTAssertEqual(CodexThreads.state(tail: [started, done, tokens], modified: now, now: now), .done)
        XCTAssertEqual(CodexThreads.state(tail: [started, approval], modified: now, now: now), .needsInput)
        XCTAssertEqual(CodexThreads.state(tail: [started], modified: now, now: now), .working)
        XCTAssertEqual(CodexThreads.state(tail: [started], modified: now.addingTimeInterval(-600), now: now), .done)
    }

    func testTwinToItems() {
        var twin = TwinConversation()
        twin.messages = [
            TwinMessage(id: "m1", role: .user, blocks: [.text("hi")]),
            TwinMessage(id: "m2", role: .assistant, blocks: [.toolCall(id: "c1", name: "shell", summary: "ls")]),
            TwinMessage(id: "m3", role: .user, blocks: [.toolResult(id: "c1", summary: "a.txt", isError: false)]),
            TwinMessage(id: "m4", role: .assistant, blocks: [.text("done")]),
        ]
        let conversation = AgentConversation(twin: twin)
        XCTAssertEqual(conversation.items.count, 3)
        guard case .tool(let call) = conversation.items[1].kind else { return XCTFail("expected tool") }
        XCTAssertEqual(call.result, "a.txt")
    }
}

final class CodexCatalogTests: XCTestCase {
    func testModelsComeFromWhatCodexLists() {
        let payload: [String: Any] = ["data": [
            ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "description": "Our most capable model.",
             "isDefault": true, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [
                ["reasoningEffort": "low", "description": "Fast responses with lighter reasoning"],
                ["reasoningEffort": "ultra", "description": "Maximum reasoning with automatic task delegation"],
             ]],
            ["id": "hidden-one", "displayName": "Hidden", "hidden": true],
            ["displayName": "No id at all"],
        ]]
        let models = CodexCatalog.models(from: payload)
        XCTAssertEqual(models.map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(models.first?.efforts, ["low", "ultra"])
        XCTAssertEqual(models.first?.effortDetail["low"], "Fast responses with lighter reasoning")
        XCTAssertEqual(models.first?.defaultEffort, "medium")
        XCTAssertTrue(models.first?.isDefault == true)
        XCTAssertTrue(CodexCatalog.models(from: nil).isEmpty)
    }

    func testPermissionProfilesReadAsSentences() {
        let payload: [String: Any] = ["data": [
            ["id": ":read-only", "allowed": true],
            ["id": ":danger-full-access", "allowed": true],
        ]]
        let profiles = CodexCatalog.profiles(from: payload)
        XCTAssertEqual(profiles.map(\.title), ["Read only", "Danger full access"])
        XCTAssertFalse(profiles[0].isDangerous)
        XCTAssertTrue(profiles[1].isDangerous)
    }
}

final class CodexApprovalTests: XCTestCase {
    /// As `item/commandExecution/requestApproval` arrives under an
    /// `untrusted` policy, captured from codex-cli 0.153.2.
    private let command: [String: Any] = [
        "kind": "command", "threadId": "t", "turnId": "u", "itemId": "exec-1",
        "command": "/bin/zsh -lc 'touch out.txt'", "cwd": "/tmp/work",
        "commandActions": [["type": "unknown", "command": "touch out.txt"]],
        "availableDecisions": ["accept", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["touch", "out.txt"]]], "cancel"],
    ]

    func testCommandReadsAsBashWithTheAgentsOwnCommand() throws {
        let prompt = CodexApproval.prompt(method: "item/commandExecution/requestApproval", params: command)
        let request = try XCTUnwrap(AgentPermissionRequest(json: prompt))
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.id, "exec-1")
        // The command as written, not the shell line wrapping it.
        XCTAssertEqual(request.inputObject["command"] as? String, "touch out.txt")
        XCTAssertEqual(request.inputObject["cwd"] as? String, "/tmp/work")
    }

    func testFileChangeReadsAsAnEdit() throws {
        let prompt = CodexApproval.prompt(method: "item/fileChange/requestApproval",
                                          params: ["itemId": "f1", "changes": [["path": "/tmp/work/a.swift"]]])
        let request = try XCTUnwrap(AgentPermissionRequest(json: prompt))
        XCTAssertEqual(request.toolName, "Edit")
        XCTAssertEqual(request.inputObject["file_path"] as? String, "/tmp/work/a.swift")
    }

    func testDecisionsComeFromWhatCodexOffered() {
        let offered = command["availableDecisions"] as? [Any] ?? []
        XCTAssertEqual(CodexApproval.decision(allow: true, offered: offered), "accept")
        XCTAssertEqual(CodexApproval.decision(allow: false, offered: offered), "cancel")
        // Declining just the action is preferred when it's on offer.
        XCTAssertEqual(CodexApproval.decision(allow: false, offered: ["accept", "decline", "cancel"]), "decline")
        // Nothing listed: the names Codex uses.
        XCTAssertEqual(CodexApproval.decision(allow: true, offered: []), "accept")
        XCTAssertEqual(CodexApproval.decision(allow: false, offered: []), "cancel")
    }

    func testEveryRequestKindIsCovered() {
        XCTAssertTrue(CodexApproval.approvals.contains("item/commandExecution/requestApproval"))
        XCTAssertTrue(CodexApproval.approvals.contains("item/fileChange/requestApproval"))
        XCTAssertTrue(CodexApproval.approvals.contains("item/permissions/requestApproval"))
        // MCP elicitation still gets words for the transcript.
        XCTAssertTrue(CodexApproval.unsupported("mcpServer/elicitation/request").contains("MCP"))
    }

    func testUserInputMapsQuestionsAndAnswersByCodexId() throws {
        let params: [String: Any] = [
            "itemId": "ask-1", "threadId": "thread-1", "isBlocking": true,
            "questions": [
                ["id": "database", "header": "Database", "question": "Which one?", "isOther": true,
                 "options": [["label": "Postgres", "description": "Shared service"]]],
                ["id": "notes", "header": "Notes", "question": "Anything else?", "isSecret": true],
            ],
        ]
        let question = try XCTUnwrap(CodexUserInput.question(params))
        XCTAssertEqual(question.id, "ask-1")
        XCTAssertEqual(question.items.map(\.question), ["Which one?", "Anything else?"])
        XCTAssertEqual(question.items.map(\.custom), [true, true])
        XCTAssertTrue(question.items[1].secret)

        let ids = CodexUserInput.questionIds(params)
        let result = CodexUserInput.response(questionIds: ids, answers: [["Postgres"], ["No"]])
        let mapped = try XCTUnwrap(result["answers"] as? [String: Any])
        XCTAssertEqual((mapped["database"] as? [String: [String]])?["answers"], ["Postgres"])
        XCTAssertEqual((mapped["notes"] as? [String: [String]])?["answers"], ["No"])
    }

    func testPiExtensionDialogsMapToQuestionsAndResponses() throws {
        let select: [String: Any] = [
            "type": "extension_ui_request", "id": "pi-1", "method": "select",
            "title": "Choose a branch", "options": ["main", "release"],
        ]
        let question = try XCTUnwrap(PiExtensionUI.question(select, sessionId: "session"))
        XCTAssertEqual(question.items[0].options.map(\.label), ["main", "release"])
        XCTAssertFalse(question.items[0].custom)
        XCTAssertEqual(PiExtensionUI.response(select, answers: [["release"]])["value"] as? String, "release")

        let confirm: [String: Any] = [
            "type": "extension_ui_request", "id": "pi-2", "method": "confirm",
            "title": "Clear session?", "message": "All messages will be lost.",
        ]
        XCTAssertEqual(PiExtensionUI.response(confirm, answers: [["Yes"]])["confirmed"] as? Bool, true)
        XCTAssertEqual(PiExtensionUI.cancel(confirm)["cancelled"] as? Bool, true)

        let editor: [String: Any] = [
            "type": "extension_ui_request", "id": "pi-3", "method": "editor",
            "title": "Edit the plan", "prefill": "Ship it\nVerify it",
        ]
        XCTAssertEqual(PiExtensionUI.question(editor, sessionId: "session")?.items[0].initial,
                       "Ship it\nVerify it")
    }

    func testClaudeAskUserQuestionMapsToQuestionAndPermissionAnswer() throws {
        let prompt: [String: Any] = [
            "tool_name": "AskUserQuestion", "tool_use_id": "ask-claude",
            "input": ["questions": [
                ["header": "Database", "question": "Which database?", "multiSelect": false,
                 "options": [["label": "Postgres", "description": "Shared service"]]],
                ["header": "Features", "question": "Which features?", "multiSelect": true,
                 "options": [["label": "Auth", "description": "Sign in"]]],
            ]],
        ]
        let question = try XCTUnwrap(ClaudeUserInput.question(prompt, sessionId: "session"))
        XCTAssertEqual(question.id, "ask-claude")
        XCTAssertEqual(question.items.map(\.question), ["Which database?", "Which features?"])
        XCTAssertEqual(question.items.map(\.multiple), [false, true])

        let decision = ClaudeUserInput.decision(prompt, question: question,
                                                answers: [["Postgres"], ["Auth", "Metrics"]])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updated["answers"] as? [String: String])
        XCTAssertEqual(answers["Which database?"], "Postgres")
        XCTAssertEqual(answers["Which features?"], "Auth, Metrics")
    }

    func testPiModelsKeepProviderAndSlashesInModelId() throws {
        let model = try XCTUnwrap(PiModel([
            "id": "qwen/qwen3.7-max", "name": "Qwen 3.7 Max", "provider": "qwen-token-plan",
            "reasoning": true, "input": ["text", "image"], "contextWindow": 262_144, "maxTokens": 65_536,
        ]))
        XCTAssertEqual(model.id, "qwen-token-plan/qwen/qwen3.7-max")
        XCTAssertEqual(model.detail, "Reasoning · Images · 262K context · 65K max output")
        let selection = try XCTUnwrap(PiModel.selection(model.id))
        XCTAssertEqual(selection.provider, "qwen-token-plan")
        XCTAssertEqual(selection.modelId, "qwen/qwen3.7-max")
    }

    func testRestoresPiMessagesAndToolResults() {
        var conversation = AgentConversation()
        conversation.restorePi([
            ["role": "user", "content": "Inspect the project"],
            ["role": "assistant", "id": "answer-1", "content": [
                ["type": "text", "text": "I will inspect it."],
                ["type": "toolCall", "id": "call-1", "name": "read", "arguments": ["path": "README.md"]],
            ]],
            ["role": "toolResult", "toolCallId": "call-1", "toolName": "read",
             "content": [["type": "text", "text": "# Project"]], "isError": false],
            ["role": "bashExecution", "command": "pwd", "output": "/tmp/project\n", "exitCode": 0],
        ])

        XCTAssertEqual(conversation.items.count, 4)
        guard case .user(let prompt) = conversation.items[0].kind else { return XCTFail("missing user message") }
        XCTAssertEqual(prompt, "Inspect the project")
        guard case .tool(let restored) = conversation.items[2].kind else { return XCTFail("missing restored tool") }
        XCTAssertEqual(restored.result, "# Project")
        guard case .tool(let bash) = conversation.items[3].kind else { return XCTFail("missing bash execution") }
        XCTAssertEqual(bash.input, "pwd")
    }

    func testPiProviderErrorsAppearInTranscript() {
        var conversation = AgentConversation()
        conversation.applyPi(["type": "agent_start"])
        conversation.applyPi(["type": "message_end", "message": [
            "role": "assistant", "content": [], "stopReason": "error",
            "errorMessage": "401 invalid API key",
        ]])
        XCTAssertEqual(conversation.lastError, "401 invalid API key")
        XCTAssertEqual(conversation.items.last?.kind, .notice("401 invalid API key"))
    }

    func testGuardianWarningIsShown() {
        var conversation = AgentConversation()
        let text = "Automatic approval review approved (risk: low, authorization: high): a narrowly scoped write."
        conversation.applyCodex(["method": "guardianWarning", "params": ["threadId": "t", "message": text]])
        XCTAssertEqual(conversation.items.map(\.kind), [.notice(text)])
        // An empty one says nothing.
        conversation.applyCodex(["method": "guardianWarning", "params": ["message": ""]])
        XCTAssertEqual(conversation.items.count, 1)
    }

    func testDeclinedCommandReadsAsDeclined() {
        var conversation = AgentConversation()
        conversation.applyCodex(["method": "item/completed", "params": ["item": [
            "type": "commandExecution", "id": "exec-1", "status": "declined", "exitCode": NSNull(),
            "commandActions": [["command": "touch out.txt"]],
        ]]])
        guard case .tool(let call)? = conversation.items.first?.kind else { return XCTFail("no tool item") }
        XCTAssertTrue(call.isError)
        XCTAssertEqual(call.result, "Declined")
    }
}
