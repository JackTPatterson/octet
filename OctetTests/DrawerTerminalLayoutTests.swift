import XCTest

final class DrawerTerminalLayoutTests: XCTestCase {
    func testStartsWithOneTerminalAndNoSidebar() {
        let layout = DrawerTerminalLayout()
        XCTAssertEqual(layout.terminals.count, 1)
        XCTAssertEqual(layout.primary, layout.active)
        XCTAssertFalse(layout.showsSidebar)
        XCTAssertFalse(layout.showsGroupHeaders)
        XCTAssertTrue(layout.canSplit)
        XCTAssertTrue(layout.isValid)
    }

    func testSplitAddsNextToTheOneInFrontAndTurnsTheGroup() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let second = layout.split(.horizontal)!
        XCTAssertEqual(layout.active, second)
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.activeGroup?.axis, .horizontal)
        layout.focus(first)
        let third = layout.split(.vertical)!
        XCTAssertEqual(layout.activeGroup?.terminals, [first, third, second])
        XCTAssertEqual(layout.activeGroup?.axis, .vertical)
        XCTAssertTrue(layout.showsSidebar)
        XCTAssertTrue(layout.showsGroupHeaders)
    }

    func testSplitStopsAtFourPerGroup() {
        var layout = DrawerTerminalLayout()
        for _ in 0..<3 { XCTAssertNotNil(layout.split(.horizontal)) }
        XCTAssertFalse(layout.canSplit)
        XCTAssertNil(layout.split(.vertical))
        XCTAssertEqual(layout.terminals.count, 4)
        // A new group has room again.
        layout.newGroup()
        XCTAssertTrue(layout.canSplit)
    }

    func testNewGroupGoesLastAndInFront() {
        var layout = DrawerTerminalLayout()
        let id = layout.newGroup()
        XCTAssertEqual(layout.groups.count, 2)
        XCTAssertEqual(layout.groups.last?.terminals, [id])
        XCTAssertEqual(layout.active, id)
        XCTAssertTrue(layout.showsSidebar)
        XCTAssertFalse(layout.showsGroupHeaders, "Two single terminals need no group headers")
    }

    func testClosingInFrontHandsToTheNeighbourInTheGroup() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let second = layout.split(.horizontal)!
        let third = layout.split(.horizontal)!
        layout.focus(second)
        XCTAssertTrue(layout.close(second))
        XCTAssertEqual(layout.active, first)
        layout.focus(first)
        XCTAssertTrue(layout.close(first))
        XCTAssertEqual(layout.active, third, "The first of a group hands to the one after it")
    }

    func testClosingTheLastOfAGroupHandsToTheGroupBefore() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let other = layout.newGroup()
        XCTAssertTrue(layout.close(other))
        XCTAssertEqual(layout.active, first)
        XCTAssertEqual(layout.groups.count, 1)
    }

    func testClosingTheFirstGroupHandsToTheNextAndMovesThePrimary() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let other = layout.newGroup()
        layout.focus(first)
        XCTAssertTrue(layout.close(first))
        XCTAssertEqual(layout.active, other)
        XCTAssertEqual(layout.primary, other)
    }

    func testClosingOneNotInFrontKeepsFront() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let second = layout.split(.vertical)!
        XCTAssertTrue(layout.close(first))
        XCTAssertEqual(layout.active, second)
    }

    func testClosingTheLastTerminalEmptiesTheDrawer() {
        var layout = DrawerTerminalLayout()
        XCTAssertFalse(layout.close(layout.active))
        XCTAssertTrue(layout.terminals.isEmpty)
        XCTAssertFalse(layout.isValid)
    }

    func testIdsAreNeverReused() {
        var layout = DrawerTerminalLayout()
        let second = layout.split(.horizontal)!
        layout.close(second)
        XCTAssertNotEqual(layout.split(.horizontal), second)
    }

    func testLabelsByPositionUnlessTheShellNamedItself() {
        var layout = DrawerTerminalLayout()
        let first = layout.active
        let second = layout.newGroup()
        XCTAssertEqual(layout.label(of: first), "Terminal 1")
        XCTAssertEqual(layout.label(of: second, title: "  "), "Terminal 2")
        XCTAssertEqual(layout.label(of: second, title: "~/src"), "~/src")
        XCTAssertEqual(layout.groupLabel(of: layout.groups[1].id), "Group 2")
    }

    func testRoundTripsAndRejectsBrokenSaves() throws {
        var layout = DrawerTerminalLayout()
        layout.split(.vertical)
        layout.newGroup()
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(DrawerTerminalLayout.self, from: data), layout)

        let broken = Data(#"{"groups":[{"id":1,"terminals":[2],"axis":"horizontal"}],"active":9,"nextId":3}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(DrawerTerminalLayout.self, from: broken).isValid)
    }

    func testShortcutsAreOnlyTheDrawersFour() {
        typealias C = DrawerTerminalCommand
        XCTAssertEqual(C.matching(key: "d", command: true, shift: false, option: false, control: false), .splitHorizontally)
        XCTAssertEqual(C.matching(key: "D", command: true, shift: true, option: false, control: false), .splitVertically)
        XCTAssertEqual(C.matching(key: "n", command: true, shift: false, option: false, control: false), .newTerminal)
        XCTAssertEqual(C.matching(key: "w", command: true, shift: false, option: false, control: false), .close)
        XCTAssertNil(C.matching(key: "d", command: false, shift: false, option: false, control: false))
        XCTAssertNil(C.matching(key: "n", command: true, shift: true, option: false, control: false), "⌘⇧N stays New Claude Conversation")
        XCTAssertNil(C.matching(key: "w", command: true, shift: true, option: false, control: false))
        XCTAssertNil(C.matching(key: "n", command: true, shift: false, option: true, control: false), "⌥⌘N stays New Window")
        XCTAssertNil(C.matching(key: "t", command: true, shift: false, option: false, control: false))
    }
}
