import XCTest

final class TabStripOrderTests: XCTestCase {
    func testAnEngineMoveShowsOnTheStrip() {
        // The strip showed a, conversation, b; the engine moved b before a.
        let previous = ["terminal:a", "conversation:c", "terminal:b"]
        let current = ["terminal:b", "terminal:a", "conversation:c"]
        XCTAssertEqual(TabStripOrder.reconcile(previous: previous, current: current),
                       ["terminal:b", "conversation:c", "terminal:a"])
    }

    func testNewTabsGoLastAndClosedOnesLeave() {
        let previous = ["terminal:a", "editor:w", "terminal:b"]
        let current = ["terminal:b", "terminal:new", "editor:w"]
        // a's place goes with it; b keeps the one it had after the editor.
        XCTAssertEqual(TabStripOrder.reconcile(previous: previous, current: current),
                       ["editor:w", "terminal:b", "terminal:new"])
    }

    func testMovingIntoAGap() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(TabStripOrder.moving("a", toGap: 3, in: order), ["b", "c", "a", "d"])
        XCTAssertEqual(TabStripOrder.moving("d", toGap: 0, in: order), ["d", "a", "b", "c"])
        XCTAssertEqual(TabStripOrder.moving("b", toGap: 4, in: order), ["a", "c", "d", "b"])
        // Either gap next to it leaves it where it is.
        XCTAssertEqual(TabStripOrder.moving("b", toGap: 1, in: order), order)
        XCTAssertEqual(TabStripOrder.moving("b", toGap: 2, in: order), order)
    }

    func testTheEngineGapCountsTabsTheStripHides() {
        // The engine has a hidden backing tab h between a and b.
        let engine = ["a", "h", "b", "c"]
        // c dropped before b on the strip: before b in the engine, past h.
        let strip = ["terminal:a", "terminal:c", "conversation:x", "terminal:b"]
        XCTAssertEqual(TabStripOrder.engineGap(for: "c", in: strip, engine: engine), 2)
        // Dropped after every terminal tab, it goes to the end.
        let last = ["terminal:a", "terminal:b", "conversation:x", "terminal:c"]
        XCTAssertEqual(TabStripOrder.engineGap(for: "c", in: last, engine: engine), 4)
    }

    func testAConversationBetweenTabsDoesntShiftTheDrop() {
        // Dropping a before b's place, past a conversation, lands it just before b.
        let order = TabStripOrder.moving("terminal:a", toGap: 3, in: ["terminal:a", "conversation:x", "terminal:b", "terminal:c"])
        XCTAssertEqual(order, ["conversation:x", "terminal:b", "terminal:a", "terminal:c"])
        XCTAssertEqual(TabStripOrder.engineGap(for: "a", in: order, engine: ["a", "b", "c"]), 2)
    }
}
