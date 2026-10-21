import XCTest

final class ComposerMentionTests: XCTestCase {
    func testMentionIsReadAtTheCaretNotTheEnd() {
        let text = "Look at @Sour and then @Tests"
        let caret = ("Look at @Sour" as NSString).length
        let mention = AgentComposerSyntax.mention(in: text, caret: caret)
        XCTAssertEqual(mention?.query, "Sour")
        // The whole token is replaced, up to the next space.
        XCTAssertEqual(mention.map { String(text[$0.range]) }, "@Sour")
        XCTAssertEqual(AgentComposerSyntax.mention(in: text)?.query, "Tests")
    }

    func testCaretInsideATokenReplacesAllOfIt() {
        let text = "@Sources/App please"
        let mention = AgentComposerSyntax.mention(in: text, caret: 4)
        XCTAssertEqual(mention?.query, "Sou")
        XCTAssertEqual(mention.map { String(text[$0.range]) }, "@Sources/App")
    }

    func testNoMentionAfterASpaceOrInAnEmail() {
        XCTAssertNil(AgentComposerSyntax.mention(in: "@done now", caret: 9))
        XCTAssertNil(AgentComposerSyntax.mention(in: "mail me@example.com", caret: 19))
        XCTAssertEqual(AgentComposerSyntax.mention(in: "(@src", caret: 5)?.query, "src")
    }

    func testRankingPrefersPrefixesAndFileNames() {
        let paths = ["Docs/readme.md", "Sources/App/AppView.swift", "Tests/AppTests.swift", "Sources/Other.swift"]
        let ranked = AgentComposerSyntax.rank(paths, matching: "App").map(\.path)
        XCTAssertEqual(ranked.first, "Tests/AppTests.swift")
        XCTAssertTrue(ranked.contains("Sources/App/AppView.swift"))
        XCTAssertFalse(ranked.contains("Docs/readme.md"))
    }

    func testFilesBecomeMentionPaths() {
        XCTAssertEqual(AgentComposerSyntax.mentionPath("/repo/src/a.txt", cwd: "/repo"), "src/a.txt")
        XCTAssertEqual(AgentComposerSyntax.mentionPath("/elsewhere/b.pdf", cwd: "/repo"), "/elsewhere/b.pdf")
        XCTAssertEqual(AgentComposerSyntax.mentionPath("/repo/My File.md", cwd: "/repo/"), "\"My File.md\"")
    }

    func testReferenceIndexUsesGitAndRespectsIgnore() throws {
        let folder = NSTemporaryDirectory() + "octet-refs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/build", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", folder, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        try "kept".write(toFile: folder + "/kept.swift", atomically: true, encoding: .utf8)
        try "ignored".write(toFile: folder + "/secret.log", atomically: true, encoding: .utf8)
        try "*.log\n".write(toFile: folder + "/.gitignore", atomically: true, encoding: .utf8)
        let files = ReferenceIndex.gitFiles(in: folder) ?? []
        XCTAssertTrue(files.contains("kept.swift"))
        XCTAssertFalse(files.contains("secret.log"))
    }
}

final class TranscriptTimelineTests: XCTestCase {
    private func tool(_ id: String, _ name: String, path: String? = nil, result: String? = "ok",
                      error: Bool = false, parent: String? = nil) -> AgentItem {
        var call = AgentToolCall(name: name, summary: "", input: "")
        if let path { call.inputData = try? JSONSerialization.data(withJSONObject: ["file_path": path]) }
        call.result = result
        call.isError = error
        return AgentItem(id: id, kind: .tool(call), parent: parent)
    }

    func testConsecutiveToolCallsFoldIntoOneRun() {
        let items = [
            AgentItem(id: "u", kind: .user("go")),
            tool("a", "Read", path: "/x"), tool("b", "Bash"), tool("c", "Edit", path: "/y"),
            AgentItem(id: "t", kind: .text("done")),
            tool("d", "Read", path: "/z"),
        ]
        XCTAssertEqual(TranscriptTimeline.rows(items), [.item("u"), .toolRun(["a", "b", "c"]), .item("t"), .item("d")])
    }

    func testRunsBreakAtSubagentsAndStandaloneCalls() {
        let items = [
            tool("a", "Read"), tool("b", "Read"),
            tool("task", "Task"),
            tool("c", "Grep", parent: "task"), tool("d", "Grep", parent: "task"),
            tool("e", "TodoWrite"),
        ]
        XCTAssertEqual(TranscriptTimeline.rows(items),
                       [.toolRun(["a", "b"]), .item("task"), .toolRun(["c", "d"]), .item("e")])
    }

    func testSummaryCountsFilesOnceAndUsesPastTense() {
        let calls = [
            AgentToolCall(name: "Read", summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: ["file_path": "/a"])),
            AgentToolCall(name: "Read", summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: ["file_path": "/a"])),
            AgentToolCall(name: "Read", summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: ["file_path": "/b"])),
            AgentToolCall(name: "Bash", summary: "", input: ""),
            AgentToolCall(name: "Bash", summary: "", input: ""),
            AgentToolCall(name: "Edit", summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: ["file_path": "/c"])),
        ]
        XCTAssertEqual(ToolRunSummary.text(calls, live: false), "Read 2 files, edited 1 file, and ran 2 commands")
        XCTAssertEqual(ToolRunSummary.text(Array(calls.suffix(2)), live: true), "Editing 1 file and running 1 command…")
    }

    func testElapsedReadsLikeAClock() {
        XCTAssertEqual(AgentElapsed.text(12), "12s")
        XCTAssertEqual(AgentElapsed.text(65), "1m 05s")
        XCTAssertEqual(AgentElapsed.text(3_725), "1h 02m")
    }

    func testThinkingDurationIsUntilTheNextItem() {
        let start = Date(timeIntervalSince1970: 1_000)
        let thinking = AgentItem(id: "t", kind: .thinking("hm"), createdAt: start)
        let reply = AgentItem(id: "r", kind: .text("ok"), createdAt: start.addingTimeInterval(12))
        XCTAssertEqual(AgentElapsed.thinking(thinking, next: reply), 12)
        XCTAssertNil(AgentElapsed.thinking(thinking, next: nil))
    }

    func testOnlyCompleteShellBlocksAreRunnable() {
        XCTAssertEqual(ShellCodeBlock.runnable(language: "bash", text: "npm test\n"), "npm test")
        XCTAssertEqual(ShellCodeBlock.runnable(language: "console", text: "$ ls\nfile.txt\n$ pwd"), "ls\npwd")
        XCTAssertNil(ShellCodeBlock.runnable(language: "swift", text: "print(1)"))
        XCTAssertNil(ShellCodeBlock.runnable(language: "sh", text: "echo \u{1B}[2J"))
        XCTAssertNil(ShellCodeBlock.runnable(language: "sh", text: "  \n"))
    }
}

final class AgentQuestionDraftTests: XCTestCase {
    private let question = OpenCodeQuestion([
        "id": "q", "sessionID": "s",
        "questions": [
            ["header": "Stack", "question": "Which?", "options": [["label": "A", "description": ""], ["label": "B", "description": ""]],
             "multiple": false, "custom": true],
            ["header": "Extras", "question": "Which extras?", "options": [["label": "X", "description": ""], ["label": "Y", "description": ""]],
             "multiple": true, "custom": false],
        ],
    ])!

    func testNumberKeysPickAndSingleChoiceSettles() {
        var draft = AgentQuestionDraft(question)
        XCTAssertEqual(draft.progress, "1/2")
        XCTAssertEqual(draft.pick(number: 2), true)
        XCTAssertNil(draft.pick(number: 3))
        XCTAssertTrue(draft.canAdvance)
        XCTAssertTrue(draft.advance())
        XCTAssertEqual(draft.progress, "2/2")
        XCTAssertEqual(draft.pick(number: 1), false)
        XCTAssertEqual(draft.pick(number: 2), false)
        XCTAssertEqual(draft.answers, [["B"], ["X", "Y"]])
        XCTAssertTrue(draft.isComplete)
    }

    func testTypedAnswerStandsInForAnOption() {
        var draft = AgentQuestionDraft(question)
        XCTAssertFalse(draft.canAdvance)
        draft.type("Something else")
        XCTAssertEqual(draft.answer(at: 0), ["Something else"])
        XCTAssertFalse(draft.isComplete)
    }
}

final class AgentBlockerTests: XCTestCase {
    func testClaudeRateLimitIsTypedFromTheStream() {
        var conversation = AgentConversation()
        conversation.appendUser("go")
        conversation.apply(["type": "rate_limit_event",
                            "rate_limit_info": ["status": "rejected", "resetsAt": 2_000_000_000.0, "rateLimitType": "five_hour"]])
        conversation.apply(["type": "assistant", "error": "rate_limit",
                            "message": ["id": "m", "content": [["type": "text", "text": "You've hit your limit · resets 3pm"]]]])
        conversation.apply(["type": "result", "subtype": "success", "is_error": true, "result": "You've hit your limit"])
        XCTAssertEqual(conversation.limitHit?.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertFalse(conversation.isRunning)
        // A new message clears it.
        conversation.appendUser("again")
        XCTAssertNil(conversation.limitHit)
    }

    func testAReplyThatTalksAboutLimitsIsNotALimit() {
        var conversation = AgentConversation()
        conversation.appendUser("explain")
        conversation.apply(["type": "assistant",
                            "message": ["id": "m", "content": [["type": "text", "text": "The usage limit resets at 3pm"]]]])
        conversation.apply(["type": "result", "subtype": "success"])
        XCTAssertNil(conversation.limitHit)
    }

    func testCodexUsageLimitIsTypedFromItsErrorInfo() {
        var conversation = AgentConversation()
        conversation.applyCodex(["method": "turn/started", "params": [:]])
        conversation.applyCodex(["method": "error", "params": ["error": ["message": "You've hit your usage limit.",
                                                                         "codexErrorInfo": "usageLimitExceeded"]]])
        XCTAssertEqual(conversation.limitHit?.message, "You've hit your usage limit.")
        XCTAssertEqual(conversation.items.last?.noticeStyle, .error)
        conversation.applyCodex(["method": "error", "params": ["error": ["message": "boom", "codexErrorInfo": ["httpConnectionFailed": [:]]]]])
        XCTAssertTrue(AgentLimitText.isCodexUsageLimit(["codexErrorInfo": ["usageLimitExceeded": [:]]]))
        XCTAssertFalse(AgentLimitText.isCodexUsageLimit(["codexErrorInfo": ["httpConnectionFailed": [:]]]))
    }

    func testCompactionIsALifecycleNotText() {
        var conversation = AgentConversation()
        conversation.appendUser("/compact")
        conversation.beginCompaction()
        conversation.beginCompaction()
        XCTAssertEqual(conversation.items.filter { $0.noticeStyle == .compacting }.count, 1)
        conversation.apply(["type": "system", "subtype": "compact_boundary"])
        XCTAssertEqual(conversation.items.last?.noticeStyle, .compacted)
        // A turn that ends settles a compaction that never said it finished.
        conversation.beginCompaction()
        conversation.apply(["type": "result", "subtype": "success"])
        XCTAssertFalse(conversation.items.contains { $0.noticeStyle == .compacting })
    }

    func testFailedResultsAreErrorNotices() {
        var conversation = AgentConversation()
        conversation.appendUser("go")
        conversation.apply(["type": "result", "subtype": "error_max_turns"])
        XCTAssertEqual(conversation.items.last?.noticeStyle, .error)
    }

    func testLimitWordsSplitIntoSentencesAndLinks() {
        let parts = AgentLimitText.parts("you've hit your limit · resets 3pm (Europe/London) · claude.ai/settings/usage")
        XCTAssertEqual(parts.lines, ["You've hit your limit", "Resets 3pm (Europe/London)"])
        XCTAssertEqual(parts.actions.first?.title, "Manage usage")
        XCTAssertEqual(parts.actions.first?.url.absoluteString, "https://claude.ai/settings/usage")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNotNil(AgentLimitText.resetDate(in: "resets 3pm (Europe/London)", now: now))
        XCTAssertNil(AgentLimitText.resetDate(in: "no time here", now: now))
    }
}
