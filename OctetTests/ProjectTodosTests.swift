import XCTest

final class ProjectTodosTests: XCTestCase {
    private let sample = """
    # TODO

    Some notes about the plan.

    ## Bugs

    - [x] **Fix the paste** (high)
    - [ ] Scroll jumps
      when output arrives
    * [~] Half done

    ## Later
    1. [ ] `npm` logos
    - not an item
    - [ ]
    """ + "\n"

    func testParsesItemsWithTheirSectionsAndStatus() {
        let list = ProjectTodos.parse(sample, path: "/p/TODO.md")
        XCTAssertEqual(list.items.map(\.text), ["Fix the paste (high)", "Scroll jumps", "Half done", "npm logos"])
        XCTAssertEqual(list.items.map(\.status), [.completed, .pending, .inProgress, .pending])
        XCTAssertEqual(list.items.map(\.section), ["Bugs", "Bugs", "Bugs", "Later"])
        XCTAssertEqual(list.items.map(\.line), [6, 7, 9, 12])
        XCTAssertEqual(list.open.count, 3)
        XCTAssertEqual(list.done.count, 1)
    }

    func testTickingChangesOnlyThatLine() throws {
        let ticked = try XCTUnwrap(ProjectTodos.setting(.completed, line: 7, in: sample))
        XCTAssertEqual(ticked, sample.replacingOccurrences(of: "- [ ] Scroll jumps", with: "- [x] Scroll jumps"))
        let reopened = try XCTUnwrap(ProjectTodos.setting(.pending, line: 6, in: sample))
        XCTAssertTrue(reopened.contains("- [ ] **Fix the paste** (high)"))
        XCTAssertTrue(reopened.hasSuffix("\n"))
    }

    func testTickingALineThatIsNoLongerAnItemFails() {
        XCTAssertNil(ProjectTodos.setting(.completed, line: 2, in: sample))
        XCTAssertNil(ProjectTodos.setting(.completed, line: 99, in: sample))
    }

    func testAddingGoesAfterTheLastItem() {
        let added = ProjectTodos.adding("  Ship it  ", to: sample)
        let list = ProjectTodos.parse(added, path: "")
        XCTAssertEqual(list.items.last?.text, "Ship it")
        XCTAssertEqual(list.items.last?.line, 13)
        XCTAssertTrue(added.contains("1. [ ] `npm` logos\n- [ ] Ship it\n- not an item"))
    }

    func testAddingAfterAWrappedItemKeepsItsWrappedLines() {
        let added = ProjectTodos.adding("New", to: "- [ ] One\n  more of one\n")
        XCTAssertEqual(added, "- [ ] One\n  more of one\n- [ ] New\n")
    }

    func testAddingToAnEmptyFileStartsAList() {
        XCTAssertEqual(ProjectTodos.adding("First", to: ""), "# TODO\n\n- [ ] First\n")
        XCTAssertEqual(ProjectTodos.adding("First", to: "Notes\n\n"), "Notes\n\n- [ ] First\n")
        XCTAssertEqual(ProjectTodos.adding("   ", to: "Notes\n"), "Notes\n")
    }

    func testPathPrefersAnExistingFile() {
        XCTAssertEqual(ProjectTodos.path(inRoot: "/p", exists: { $0 == "/p/todo.md" }), "/p/todo.md")
        XCTAssertEqual(ProjectTodos.path(inRoot: "/p", exists: { _ in false }), "/p/TODO.md")
    }
}
