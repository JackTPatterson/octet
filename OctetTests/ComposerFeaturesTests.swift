import XCTest
@testable import Octet

/// The composer's T3 Code features: prompt history, slash-command ranking,
/// the per-project stash, the plan follow-up and the length guard.
final class ComposerFeaturesTests: XCTestCase {
    // MARK: Prompt history

    func testHistoryKeepsOneCopyOfEachPromptAtItsLatestPlace() {
        var history = ComposerPromptHistory()
        history.record("  fix the login  ")
        history.record("add a test")
        history.record("fix the login")
        history.record("   ")
        history.record(ComposerPlanFollowUp.implementationPrefix + "# Plan")
        XCTAssertEqual(history.entries, ["add a test", "fix the login"])
        for n in 0..<150 { history.record("p\(n)") }
        XCTAssertEqual(history.entries.count, ComposerPromptHistory.limit)
        XCTAssertEqual(history.entries.last, "p149")
        XCTAssertEqual(history.entries.first, "p50")
    }

    func testUpWalksBackFromAnEmptyComposerAndDownReturnsToTheDraft() {
        let entries = ["first", "second", "third"]
        var cursor = ComposerHistoryCursor()
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "", caret: .start), "third")
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "third", caret: .start), "second")
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "second", caret: .start), "first")
        // Nothing older: the arrow is left alone.
        XCTAssertNil(cursor.step(.back, entries: entries, text: "first", caret: .start))
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "first", caret: .init(location: 5)), "second")
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "second", caret: .init(location: 6)), "third")
        // Past the newest: the (empty) draft comes back and the walk ends.
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "third", caret: .init(location: 5)), "")
        XCTAssertFalse(cursor.isActive)
        XCTAssertNil(cursor.step(.forward, entries: entries, text: "", caret: .start))
    }

    func testHistoryLeavesTheArrowsToADraftUnlessTheCaretIsAtItsStart() {
        let entries = ["older"]
        var cursor = ComposerHistoryCursor()
        XCTAssertNil(cursor.step(.back, entries: entries, text: "half a thought", caret: .init(location: 6)))
        XCTAssertNil(cursor.step(.back, entries: entries, text: "half a thought", caret: .init(location: 0, length: 4)))
        XCTAssertNil(cursor.step(.back, entries: [], text: "", caret: .start))
        // At the very start ↑ can't move the caret, so it recalls, and ↓
        // past the newest brings the draft back.
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "half a thought", caret: .start), "older")
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "older", caret: .init(location: 5)), "half a thought")
    }

    func testMultiLinePromptsOnlyStepFromTheirFirstAndLastLines() {
        let entries = ["one", "line a\nline b"]
        var cursor = ComposerHistoryCursor()
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "", caret: .start), "line a\nline b")
        // On the second line ↑ moves the caret, not the history.
        XCTAssertNil(cursor.step(.back, entries: entries, text: "line a\nline b", caret: .init(location: 9)))
        // On the first line it steps back.
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "line a\nline b", caret: .init(location: 3)), "one")
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "one", caret: .init(location: 3)), "line a\nline b")
        // ↓ from the first line moves the caret down instead.
        XCTAssertNil(cursor.step(.forward, entries: entries, text: "line a\nline b", caret: .init(location: 2)))
        XCTAssertTrue(ComposerHistoryCursor.onFirstLine("a\nb", .init(location: 1)))
        XCTAssertFalse(ComposerHistoryCursor.onFirstLine("a\nb", .init(location: 2)))
        XCTAssertTrue(ComposerHistoryCursor.onLastLine("a\nb", .init(location: 2)))
        XCTAssertFalse(ComposerHistoryCursor.onLastLine("a\nb", .init(location: 0, length: 1)))
    }

    func testEditingARecalledPromptMakesItADraft() {
        let entries = ["first", "second"]
        var cursor = ComposerHistoryCursor()
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "", caret: .start), "second")
        // Typed into: ↓ no longer walks, and ↑ only from the very start.
        XCTAssertNil(cursor.step(.forward, entries: entries, text: "second!", caret: .init(location: 7)))
        XCTAssertFalse(cursor.isActive)
        XCTAssertNil(cursor.step(.back, entries: entries, text: "second!", caret: .init(location: 7)))
        XCTAssertEqual(cursor.step(.back, entries: entries, text: "second!", caret: .start), "second")
        XCTAssertEqual(cursor.step(.forward, entries: entries, text: "second", caret: .init(location: 6)), "second!")
    }

    @MainActor
    func testHistoryStoreKeepsEachProjectApartAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PromptHistoryStore(url: url)
        store.record("in app", project: "/tmp/app")
        store.record("in lib", project: "/tmp/lib")
        store.record("again in app", project: "/tmp/app/")
        store.record("", project: "/tmp/app")
        let reopened = PromptHistoryStore(url: url)
        XCTAssertEqual(reopened.entries(for: "/tmp/app"), ["in app", "again in app"])
        XCTAssertEqual(reopened.entries(for: "/tmp/lib"), ["in lib"])
        XCTAssertEqual(reopened.entries(for: "/tmp/other"), [])
    }

    // MARK: Slash commands

    private let commands: [SlashCommand] = [
        SlashCommand(name: "review", summary: "Review a pull request"),
        SlashCommand(name: "pr-comments", summary: "Get comments from a GitHub pull request"),
        SlashCommand(name: "security-review", summary: "Complete a security review"),
        SlashCommand(name: "resume", summary: "Resume a conversation"),
        SlashCommand(name: "release-notes", summary: "View release notes"),
        SlashCommand(name: "compact", summary: "Summarize the conversation to free context"),
        SlashCommand(name: "permissions", summary: "Change what may run", aliases: ["approvals"]),
        SlashCommand(name: "git", children: [SlashCommand(name: "amend", insertion: "/git:amend", summary: "Amend the last commit")]),
    ]

    private func names(_ query: String) -> [String] {
        SlashCommandSearch.search(query, in: commands).map(\.command.insertion)
    }

    func testExactThenPrefixThenWordStartThenAnywhereThenLoose() {
        // `review` exactly, then the one with a word starting with it.
        XCTAssertEqual(names("review").prefix(2), ["/review", "/security-review"])
        // Prefixes: the shorter name first.
        XCTAssertEqual(names("re").prefix(3), ["/resume", "/review", "/release-notes"])
        // A word start beats the text in the middle of a word.
        XCTAssertEqual(names("com").first, "/compact")
        XCTAssertEqual(names("comments").first, "/pr-comments")
        // Loose letters come last but still match.
        XCTAssertEqual(names("rvw").first, "/review")
        XCTAssertTrue(names("zzz").isEmpty)
        // The leading slash and case don't matter.
        XCTAssertEqual(names("/REVIEW").first, "/review")
    }

    func testDescriptionsAliasesAndSubmenusMatchToo() {
        XCTAssertEqual(names("approv").first, "/permissions")
        XCTAssertEqual(names("amend").first, "/git:amend")
        // Found by what it does; a description match beats loose letters.
        XCTAssertEqual(names("summarize").first, "/compact")
        let result = SlashCommandSearch.search("summarize", in: commands).first
        XCTAssertEqual(result?.summaryIndices, Array(0..<9))
        XCTAssertEqual(result?.nameIndices, [])
        // An empty query keeps the top level as it is.
        XCTAssertEqual(SlashCommandSearch.search("", in: commands).count, commands.count)
    }

    func testMatchedLettersAreReportedForHighlighting() throws {
        let prefix = try XCTUnwrap(SlashCommandSearch.search("rev", in: commands).first)
        XCTAssertEqual(prefix.command.insertion, "/review")
        // Offsets into the insertion, so after its slash.
        XCTAssertEqual(prefix.nameIndices, [1, 2, 3])
        let boundary = try XCTUnwrap(SlashCommandSearch.search("notes", in: commands).first)
        XCTAssertEqual(boundary.command.insertion, "/release-notes")
        XCTAssertEqual(boundary.nameIndices, [9, 10, 11, 12, 13])
        let loose = try XCTUnwrap(SlashCommandSearch.search("rvw", in: commands).first)
        XCTAssertEqual(loose.nameIndices, [1, 3, 6])
        let child = try XCTUnwrap(SlashCommandSearch.search("am", in: commands).first { $0.command.name == "amend" })
        XCTAssertEqual(child.nameIndices, [5, 6])
    }

    func testRankScoresFollowT3Code() {
        XCTAssertEqual(SlashCommandSearch.rank("review", "review", fuzzy: true)?.score, 0)
        XCTAssertEqual(SlashCommandSearch.rank("review", "rev", fuzzy: true)?.score, 2 + 3)
        XCTAssertEqual(SlashCommandSearch.rank("security-review", "review", fuzzy: true)?.score, 4 + 9 * 2 + 9)
        XCTAssertEqual(SlashCommandSearch.rank("compact", "pac", fuzzy: true)?.score, 6 + 3 * 2 + 4)
        XCTAssertNil(SlashCommandSearch.rank("compact", "cmt", fuzzy: false))
        XCTAssertNotNil(SlashCommandSearch.rank("compact", "cmt", fuzzy: true))
    }

    // MARK: Stash

    func testStashIsPerProjectAndKeepsImages() throws {
        var stash = PromptStash()
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        XCTAssertNil(stash.stash("  ", project: "/a"))
        XCTAssertNotNil(stash.stash("", images: [image], project: "/a"))
        stash.stash("for a", project: "/a")
        stash.stash("for b", project: "/b")
        stash.stash("for a", project: "/a")
        XCTAssertEqual(stash.entries(in: "/a").map(\.text), ["for a", ""])
        XCTAssertEqual(stash.entries(in: "/a").last?.images, [image])
        XCTAssertEqual(stash.entries(in: "/a").last?.snippet, "(1 image)")
        XCTAssertEqual(stash.entries(in: "/b").map(\.text), ["for b"])
        for n in 0..<30 { stash.stash("a\(n)", project: "/a") }
        XCTAssertEqual(stash.entries(in: "/a").count, PromptStash.limit)
        // Another project's limit doesn't push out this one's.
        XCTAssertEqual(stash.entries(in: "/b").map(\.text), ["for b"])
    }

    func testRestoringSwapsWithTheDraftAndImages() throws {
        var stash = PromptStash()
        let saved = try XCTUnwrap(stash.stash("fix the login", images: [Data([1])], project: "/a"))
        let taken = stash.take(saved.id, replacing: "half-written", images: [Data([2])], project: "/a")
        XCTAssertEqual(taken?.text, "fix the login")
        XCTAssertEqual(taken?.images, [Data([1])])
        XCTAssertEqual(stash.entries(in: "/a").map(\.text), ["half-written"])
        XCTAssertEqual(stash.entries(in: "/a").first?.images, [Data([2])])
        stash.clear(project: "/a")
        XCTAssertTrue(stash.entries.isEmpty)
    }

    func testOlderSharedEntriesDecodeAndShowEverywhere() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","text":"old idea","createdAt":700000000}]"#
        let entries = try JSONDecoder().decode([PromptStash.Entry].self, from: Data(json.utf8))
        var stash = PromptStash(entries: entries)
        XCTAssertNil(stash.entries.first?.project)
        XCTAssertEqual(stash.entries(in: "/a").map(\.text), ["old idea"])
        XCTAssertEqual(stash.entries(in: "/b").map(\.text), ["old idea"])
        stash.stash("new", project: "/a")
        XCTAssertEqual(stash.entries(in: "/b").map(\.text), ["old idea"])
        XCTAssertEqual(PromptStash.Entry(text: "  a\n\n  b ").snippet, "a b")
        XCTAssertEqual(PromptStash.Entry(text: String(repeating: "x", count: 100)).snippet.count, 91)
    }

    @MainActor
    func testStashStorePersistsAndTakesInTheOldSharedStash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stash-\(UUID().uuidString).json")
        let suite = "octet-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suite)
        }
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","text":"old idea","createdAt":700000000}]"#
        defaults.set(Data(legacy.utf8), forKey: PromptStashStore.legacyKey)
        let store = PromptStashStore(url: url, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: PromptStashStore.legacyKey))
        XCTAssertTrue(store.stash("draft", images: [Data([7])], project: "/p"))
        XCTAssertFalse(store.stash(" ", images: [], project: "/p"))
        let reopened = PromptStashStore(url: url, defaults: defaults)
        XCTAssertEqual(reopened.entries(in: "/p").map(\.text), ["draft", "old idea"])
        XCTAssertEqual(reopened.entries(in: "/p").first?.images, [Data([7])])
        XCTAssertEqual(reopened.entries(in: "/q").map(\.text), ["old idea"])
    }

    // MARK: Plan follow-up

    private func tool(_ id: String, _ name: String, plan: String? = nil) -> AgentItem {
        let data = plan.flatMap { try? JSONSerialization.data(withJSONObject: ["plan": $0]) }
        return AgentItem(id: id, kind: .tool(AgentToolCall(name: name, summary: "", input: "", inputData: data, result: "ok")))
    }

    func testAPlanThatEndedTheTurnInPlanModeIsOffered() throws {
        let items = [
            AgentItem(id: "u", kind: .user("Plan the fix")),
            tool("r", "Read"),
            tool("p", "ExitPlanMode", plan: "# Fix retries\n\n1. Count attempts\n2. Cap them"),
            AgentItem(id: "t", kind: .text("Approve it or tell me what to change.")),
        ]
        let plan = try XCTUnwrap(ComposerPlanFollowUp.latestPlan(in: items, planMode: true, running: false))
        XCTAssertEqual(plan.id, "p")
        XCTAssertEqual(plan.title, "Fix retries")
        XCTAssertEqual(ComposerPlanFollowUp.implementationPrompt(plan),
                       "PLEASE IMPLEMENT THIS PLAN:\n# Fix retries\n\n1. Count attempts\n2. Cap them")
        // Not while running, nor once out of plan mode.
        XCTAssertNil(ComposerPlanFollowUp.latestPlan(in: items, planMode: true, running: true))
        XCTAssertNil(ComposerPlanFollowUp.latestPlan(in: items, planMode: false, running: false))
        // Nor once a newer message has been sent.
        XCTAssertNil(ComposerPlanFollowUp.latestPlan(in: items + [AgentItem(id: "u2", kind: .user("thanks"))],
                                                     planMode: true, running: false))
    }

    func testEveryAgentsPlanCallIsOffered() throws {
        // Qwen's plan tool, by its own name.
        let qwen = [AgentItem(id: "u", kind: .user("Plan it")),
                    tool("p", "exit_plan_mode", plan: "# Qwen plan\n\n1. a\n2. b")]
        XCTAssertEqual(try XCTUnwrap(ComposerPlanFollowUp.latestPlan(in: qwen, planMode: true, running: false)).title,
                       "Qwen plan")
        // Codex's plan item comes through its stream as the same call.
        var conversation = AgentConversation()
        conversation.appendUser("Plan it")
        conversation.applyCodex(["method": "item/completed", "params": ["item": [
            "id": "plan-1", "type": "plan", "text": "# Codex plan\n\n1. Read\n2. Change",
        ]]])
        let plan = try XCTUnwrap(ComposerPlanFollowUp.latestPlan(in: conversation.items, planMode: true, running: false))
        XCTAssertEqual(plan.id, "plan-1")
        XCTAssertEqual(plan.markdown, "# Codex plan\n\n1. Read\n2. Change")
    }

    func testThePlanInstructionsStayOutOfTheTranscript() {
        let sent = ComposerPlanFollowUp.withDirective("Plan the fix")
        XCTAssertTrue(sent.hasPrefix(ComposerPlanFollowUp.directive))
        XCTAssertEqual(ComposerPlanFollowUp.strippingDirective(sent), "Plan the fix")
        XCTAssertEqual(ComposerPlanFollowUp.strippingDirective("Plan the fix"), "Plan the fix")
        var conversation = AgentConversation()
        conversation.restorePi([["role": "user", "content": sent]])
        guard case .user(let shown) = conversation.items.first?.kind else { return XCTFail("no user row") }
        XCTAssertEqual(shown, "Plan the fix")
    }

    func testWorkAfterThePlanOrAPlainAnswerOffersNothing() {
        let worked = [
            AgentItem(id: "u", kind: .user("Plan the fix")),
            tool("p", "ExitPlanMode", plan: "1. a\n2. b"),
            tool("e", "Edit"),
            AgentItem(id: "t", kind: .text("Done.")),
        ]
        XCTAssertNil(ComposerPlanFollowUp.latestPlan(in: worked, planMode: true, running: false))
        let answer = [AgentItem(id: "u", kind: .user("What does this do?")),
                      AgentItem(id: "t", kind: .text("It retries uploads."))]
        XCTAssertNil(ComposerPlanFollowUp.latestPlan(in: answer, planMode: true, running: false))
    }

    func testAPlanWrittenAsTheFinalReplyCounts() throws {
        let items = [
            AgentItem(id: "u", kind: .user("Plan the fix")),
            tool("g", "Grep"),
            AgentItem(id: "t", kind: .text("Here's how:\n\n- Count attempts\n- Cap retries at **five**")),
        ]
        let plan = try XCTUnwrap(ComposerPlanFollowUp.latestPlan(in: items, planMode: true, running: false))
        XCTAssertEqual(plan.id, "t")
        XCTAssertEqual(plan.title, "Here's how:")
        XCTAssertEqual(ComposerPlanFollowUp.title(of: "## **Retry** `fix`\nmore"), "Retry fix")
        XCTAssertNil(ComposerPlanFollowUp.title(of: "  \n "))
        // History never offers the follow-up's own message.
        XCTAssertNil(ComposerPromptHistory.recallable(ComposerPlanFollowUp.implementationPrompt(plan)))
    }

    // MARK: Prompt length

    func testLongPromptsAreNotedAndVeryLongOnesAsk() {
        XCTAssertEqual(ComposerPromptLength.check("short"), .fine)
        XCTAssertEqual(ComposerPromptLength.estimatedTokens(String(repeating: "a", count: 40_000)), 10_000)
        XCTAssertEqual(ComposerPromptLength.check(String(repeating: "a", count: 40_000)), .long(tokens: 10_000))
        XCTAssertEqual(ComposerPromptLength.notice(.long(tokens: 10_000)), "Long prompt: about 10k tokens")
        guard case .tooLong(let tokens, let message) = ComposerPromptLength.check(String(repeating: "a", count: 128_000)) else {
            return XCTFail("a 32k-token prompt should ask first")
        }
        XCTAssertEqual(tokens, 32_000)
        XCTAssertTrue(message.hasPrefix("About 32k tokens."))
    }

    func testAlmostFullContextLowersTheBar() {
        let prompt = String(repeating: "a", count: 24_000) // ~6k tokens
        XCTAssertEqual(ComposerPromptLength.check(prompt, contextLeft: 100_000), .fine)
        guard case .tooLong(_, let message) = ComposerPromptLength.check(prompt, contextLeft: 4_000) else {
            return XCTFail("more than the context left should ask first")
        }
        XCTAssertTrue(message.contains("more than the 4k left"))
        // A tiny remainder never makes a short prompt ask.
        XCTAssertEqual(ComposerPromptLength.check("hello there", contextLeft: 10), .fine)
    }
}
