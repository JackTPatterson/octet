import XCTest

final class TranscriptFindTests: XCTestCase {
    private func item(_ id: String, _ kind: AgentItem.Kind) -> AgentItem { AgentItem(id: id, kind: kind) }

    private func tool(_ id: String, input: String = "", result: String? = nil, summary: String = "") -> AgentItem {
        item(id, .tool(AgentToolCall(name: "Bash", summary: summary, input: input, result: result)))
    }

    func testRangesAreCaseInsensitiveByDefaultAndDoNotOverlap() {
        XCTAssertEqual(TranscriptFind.ranges(of: "aa", in: "aaaa Aa", caseSensitive: false).count, 3)
        XCTAssertEqual(TranscriptFind.ranges(of: "Aa", in: "aaaa Aa", caseSensitive: true).count, 1)
        XCTAssertTrue(TranscriptFind.ranges(of: "", in: "text", caseSensitive: false).isEmpty)
    }

    func testMatchesRunInReadingOrderAcrossKinds() {
        let items = [
            item("u", .user("find the bug")),
            item("a", .text("The **bug** is here.\n\n- another bug\n\n```\nbug()\n```")),
            tool("t", input: "grep bug", result: "bug 1\nbug 2", summary: "bug hunt"),
            item("n", .notice("no match")),
        ]
        let matches = TranscriptFind.matches(in: items, query: "BUG", caseSensitive: false)
        XCTAssertEqual(matches.map(\.itemId), ["u", "a", "a", "a", "t", "t", "t", "t"])
        // Markdown markers aren't part of the words: **bug** is found as "bug".
        XCTAssertEqual(matches.filter { $0.itemId == "a" }.map(\.field).count, 3)
        // Two in the tool's output are the same field, counted from zero.
        let output = matches.filter { $0.field == TranscriptFind.toolOutput }
        XCTAssertEqual(output.map(\.ordinal), [0, 1])
    }

    func testMatchingUsesRenderedMarkdownNotItsSource() {
        let items = [item("a", .text("a [link](https://example.com/bug) here"))]
        XCTAssertTrue(TranscriptFind.matches(in: items, query: "example", caseSensitive: false).isEmpty)
        XCTAssertEqual(TranscriptFind.matches(in: items, query: "link", caseSensitive: false).count, 1)
    }

    func testTableCellsAreOwnFields() {
        let items = [item("a", .text("| h | k |\n|---|---|\n| x | x |"))]
        let matches = TranscriptFind.matches(in: items, query: "x", caseSensitive: false)
        XCTAssertEqual(matches.map(\.field), [TranscriptFind.key(block: 0, cell: 2), TranscriptFind.key(block: 0, cell: 3)])
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(TranscriptFind.matches(in: [item("u", .user("x"))], query: "", caseSensitive: false).isEmpty)
    }

    func testStepWrapsBothWays() {
        XCTAssertEqual(TranscriptFind.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(TranscriptFind.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(TranscriptFind.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(TranscriptFind.step(from: nil, by: -1, count: 3), 2)
        XCTAssertNil(TranscriptFind.step(from: 0, by: 1, count: 0))
    }

    func testReselectKeepsTheCurrentMatchAsTextStreamsIn() {
        let a = TranscriptFind.Match(itemId: "a", field: 0, ordinal: 0)
        let b = TranscriptFind.Match(itemId: "b", field: 0, ordinal: 0)
        let c = TranscriptFind.Match(itemId: "c", field: 0, ordinal: 0)
        XCTAssertEqual(TranscriptFind.reselect(b, was: 1, in: [a, b, c]), 1)
        XCTAssertEqual(TranscriptFind.reselect(b, was: 1, in: [c, a, b]), 2)
        XCTAssertEqual(TranscriptFind.reselect(b, was: 1, in: [a]), 0)
        XCTAssertNil(TranscriptFind.reselect(b, was: 1, in: []))
    }
}
