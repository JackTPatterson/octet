import XCTest

final class PromptQueueTests: XCTestCase {
    func testOnePromptPerFinishedAgentInOrder() {
        var queue = PromptQueue()
        queue.add(.init(paneId: "a", text: "then run the tests"))
        queue.add(.init(paneId: "a", text: "then commit"))
        queue.add(.init(paneId: "b", text: "review a's work"))

        // a is still working, b waiting on a question: nothing goes.
        var due = queue.due(statuses: ["a": .working, "b": .blocked])
        XCTAssertEqual(due.send, [])
        XCTAssertEqual(queue.items.count, 3)

        due = queue.due(statuses: ["a": .done, "b": .working])
        XCTAssertEqual(due.send.map(\.text), ["then run the tests"])
        XCTAssertEqual(queue.items(for: "a").map(\.text), ["then commit"])

        // The next turn has to finish before the next prompt.
        XCTAssertEqual(queue.due(statuses: ["a": .working, "b": .idle]).send.map(\.text), ["review a's work"])
        XCTAssertEqual(queue.due(statuses: ["a": .idle]).send.map(\.text), ["then commit"])
        XCTAssertEqual(queue.items, [])
    }

    func testAPromptForAClosedAgentIsDroppedAndReported() {
        var queue = PromptQueue()
        queue.add(.init(paneId: "gone", text: "x"))
        let due = queue.due(statuses: [:])
        XCTAssertEqual(due.dropped.map(\.text), ["x"])
        XCTAssertEqual(queue.items, [])
    }
}
