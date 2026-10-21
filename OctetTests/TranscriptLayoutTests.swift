import XCTest

final class TranscriptLayoutTests: XCTestCase {
    private func stream(_ event: [String: Any], parent: String? = nil) -> [String: Any] {
        var line: [String: Any] = ["type": "stream_event", "event": event]
        if let parent { line["parent_tool_use_id"] = parent }
        return line
    }

    private func blockStart(_ index: Int, _ block: [String: Any], parent: String? = nil) -> [String: Any] {
        stream(["type": "content_block_start", "index": index, "content_block": block], parent: parent)
    }

    private func textDelta(_ index: Int, _ text: String) -> [String: Any] {
        stream(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]])
    }

    private func thinkingDelta(_ index: Int, _ text: String) -> [String: Any] {
        stream(["type": "content_block_delta", "index": index, "delta": ["type": "thinking_delta", "thinking": text]])
    }

    private func toolResult(_ id: String, _ content: String) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": content]]]]
    }

    func testStreamedTextLeavesTheRevisionButNewItemsMoveIt() {
        var conversation = AgentConversation()
        var revision = conversation.structureRevision
        conversation.appendUser("Hi")
        XCTAssertNotEqual(conversation.structureRevision, revision)
        conversation.apply(stream(["type": "message_start", "message": ["id": "m1"]]))
        revision = conversation.structureRevision
        conversation.apply(blockStart(0, ["type": "thinking", "thinking": ""]))
        XCTAssertNotEqual(conversation.structureRevision, revision, "a new item")

        revision = conversation.structureRevision
        conversation.apply(thinkingDelta(0, "Let me look"))
        conversation.apply(blockStart(1, ["type": "text", "text": ""]))
        XCTAssertNotEqual(conversation.structureRevision, revision)
        revision = conversation.structureRevision
        for word in ["Sure", ", ", "here", " it is"] { conversation.apply(textDelta(1, word)) }
        XCTAssertEqual(conversation.structureRevision, revision, "text streaming isn't a change of shape")
        XCTAssertEqual(conversation.items.last?.kind, .text("Sure, here it is"))

        conversation.apply(blockStart(2, ["type": "tool_use", "id": "t1", "name": "Bash"]))
        XCTAssertNotEqual(conversation.structureRevision, revision, "a tool call")
        revision = conversation.structureRevision
        conversation.setLiveOutput("partial", at: conversation.items.count - 1)
        XCTAssertEqual(conversation.structureRevision, revision, "streamed tool output")
        conversation.apply(toolResult("t1", "done"))
        XCTAssertNotEqual(conversation.structureRevision, revision, "a tool's result")

        revision = conversation.structureRevision
        conversation.appendUser("Next", queued: true)
        XCTAssertNotEqual(conversation.structureRevision, revision)
        revision = conversation.structureRevision
        conversation.activateNextQueuedMessage()
        XCTAssertNotEqual(conversation.structureRevision, revision, "queued to sent")
        revision = conversation.structureRevision
        conversation.truncate(from: conversation.items[0].id)
        XCTAssertNotEqual(conversation.structureRevision, revision)
    }

    func testRevisionIsntPartOfEquality() {
        var a = AgentConversation()
        a.appendUser("Hi", id: "u1")
        var b = a
        // Written again as it was: the revision moves, the items don't.
        b.items[0].queued = false
        XCTAssertNotEqual(a.structureRevision, b.structureRevision)
        XCTAssertEqual(a, b)
    }

    /// The cache must give exactly what working it all out afresh gives,
    /// at every step of a conversation: streaming, blank thinking getting
    /// words, tool runs folding, subagents, queued follow-ups and rewinds.
    func testCacheMatchesAFreshLayoutThroughAConversation() {
        var conversation = AgentConversation()
        let cache = TranscriptLayoutCache()
        var step = 0
        func check(_ line: UInt = #line) {
            step += 1
            let cached = cache.layout(for: conversation)
            let fresh = TranscriptLayout.make(conversation.items)
            XCTAssertEqual(cached, fresh, "step \(step)", line: line)
        }

        check()
        conversation.appendUser("Fix the build", id: "u1")
        check()
        conversation.apply(stream(["type": "message_start", "message": ["id": "m1"]]))
        conversation.apply(blockStart(0, ["type": "thinking", "thinking": ""]))
        check()
        conversation.apply(thinkingDelta(0, "  "))
        check()
        conversation.apply(thinkingDelta(0, "Looking at the error"))
        check()
        conversation.apply(blockStart(1, ["type": "text", "text": ""]))
        check()
        for word in ["I'll ", "**read** ", "the ", "log."] {
            conversation.apply(textDelta(1, word))
            check()
        }
        for (index, id) in ["t1", "t2", "t3"].enumerated() {
            conversation.apply(blockStart(2 + index, ["type": "tool_use", "id": id, "name": "Read"]))
            check()
            conversation.apply(toolResult(id, "contents"))
            check()
        }
        conversation.apply(blockStart(5, ["type": "tool_use", "id": "task", "name": "Task"]))
        check()
        // A subagent's own stream, under the call that started it.
        conversation.apply(stream(["type": "message_start", "message": ["id": "s1"]], parent: "task"))
        conversation.apply(blockStart(0, ["type": "text", "text": ""], parent: "task"))
        conversation.apply(textDelta(0, "Subagent here"))
        check()
        conversation.appendUser("And the tests", queued: true, id: "u2")
        check()
        conversation.apply(["type": "result", "subtype": "success"])
        check()
        conversation.activateNextQueuedMessage()
        check()
        conversation.apply(stream(["type": "message_start", "message": ["id": "m2"]]))
        conversation.apply(blockStart(0, ["type": "text", "text": ""]))
        check()
        let long = String(repeating: "word ", count: 600)
        conversation.apply(textDelta(0, long))
        check()
        conversation.apply(textDelta(0, "more"))
        check()
        conversation.truncate(from: "u2")
        check()
        conversation.items.removeAll()
        check()
    }

    func testStreamingDoesntRebuildTheLayout() {
        var conversation = AgentConversation()
        conversation.appendUser("Hi", id: "u1")
        conversation.apply(stream(["type": "message_start", "message": ["id": "m1"]]))
        conversation.apply(blockStart(0, ["type": "text", "text": ""]))
        let cache = TranscriptLayoutCache()
        _ = cache.layout(for: conversation)
        let generation = cache.generation
        for word in ["one ", "two ", "three"] {
            conversation.apply(textDelta(0, word))
            let layout = cache.layout(for: conversation)
            // The minimap's reply still follows the words in.
            XCTAssertEqual(layout, TranscriptLayout.make(conversation.items))
        }
        XCTAssertEqual(cache.generation, generation)
        XCTAssertEqual(cache.layout(for: conversation).marks.first?.reply, "one two three")
        conversation.apply(blockStart(1, ["type": "tool_use", "id": "t1", "name": "Bash"]))
        _ = cache.layout(for: conversation)
        XCTAssertEqual(cache.generation, generation + 1)
    }

    func testAReplacedConversationIsLaidOutAgain() {
        var first = AgentConversation()
        first.appendUser("One", id: "same")
        var second = AgentConversation()
        second.appendUser("Two", queued: true, id: "same")
        let cache = TranscriptLayoutCache()
        XCTAssertEqual(cache.layout(for: first).shownCount, 1)
        XCTAssertEqual(cache.layout(for: second).shownCount, 0)
    }
}
