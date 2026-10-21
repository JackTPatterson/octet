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

    // MARK: - Editing, removing, moving

    func testIdsFollowContentNotLines() {
        let before = ProjectTodos.parse(sample, path: "")
        let shifted = ProjectTodos.parse("New line on top\n" + sample, path: "")
        XCTAssertEqual(before.items.map(\.id), shifted.items.map(\.id))
        XCTAssertNotEqual(before.items[0].line, shifted.items[0].line)
        // Ticking keeps the id; the same text twice gets two.
        let ticked = ProjectTodos.parse(ProjectTodos.setting(.completed, line: 7, in: sample)!, path: "")
        XCTAssertEqual(ticked.items[1].id, before.items[1].id)
        let twice = ProjectTodos.parse("- [ ] Same\n- [x] Same\n", path: "")
        XCTAssertEqual(Set(twice.items.map(\.id)).count, 2)
    }

    func testEditingKeepsTheMarkAndBullet() throws {
        let edited = try XCTUnwrap(ProjectTodos.editing("  Half finished  ", line: 9, in: sample))
        XCTAssertTrue(edited.contains("* [~] Half finished\n"))
        XCTAssertEqual(ProjectTodos.parse(edited, path: "").items.count, 4)
        XCTAssertNil(ProjectTodos.editing("x", line: 2, in: sample))
        XCTAssertNil(ProjectTodos.editing("   ", line: 9, in: sample))
    }

    func testRemovingTakesTheWrappedLinesToo() throws {
        let removed = try XCTUnwrap(ProjectTodos.removing(line: 7, in: sample))
        XCTAssertFalse(removed.contains("Scroll jumps"))
        XCTAssertFalse(removed.contains("when output arrives"))
        XCTAssertTrue(removed.contains("- [x] **Fix the paste** (high)\n* [~] Half done"))
        XCTAssertNil(ProjectTodos.removing(line: 8, in: sample))
    }

    func testMovingCarriesTheWrappedLines() throws {
        let up = try XCTUnwrap(ProjectTodos.moving(line: 7, before: 6, in: sample))
        XCTAssertTrue(up.contains("- [ ] Scroll jumps\n  when output arrives\n- [x] **Fix the paste** (high)\n* [~] Half done"))
        let down = try XCTUnwrap(ProjectTodos.moving(line: 6, after: 7, in: sample))
        XCTAssertEqual(down, up)
        let last = try XCTUnwrap(ProjectTodos.moving(line: 7, after: 9, in: sample))
        XCTAssertTrue(last.contains("* [~] Half done\n- [ ] Scroll jumps\n  when output arrives\n\n## Later"))
        XCTAssertNil(ProjectTodos.moving(line: 7, before: 8, in: sample))
        XCTAssertEqual(ProjectTodos.moving(line: 7, before: 7, in: sample), sample)
    }

    func testAPlanBecomesAChecklist() throws {
        let plan = """
        # Fix the upload retry

        Some context first.

        1. Find every **retry** call site
        2. Cap the backoff
           with a note
        - Write tests
        """
        let list = try XCTUnwrap(ProjectTodos.checklist(fromPlan: plan, title: "Fix the upload retry"))
        XCTAssertEqual(list, "## Fix the upload retry\n\n- [ ] Find every retry call site\n- [ ] Cap the backoff\n- [ ] Write tests\n")
        XCTAssertNil(ProjectTodos.checklist(fromPlan: "Just prose.", title: nil))
        let appended = ProjectTodos.appending(list, to: "# TODO\n\n- [ ] One\n\n")
        XCTAssertEqual(appended, "# TODO\n\n- [ ] One\n\n" + list)
        XCTAssertEqual(ProjectTodos.appending(list, to: ""), list)
        let parsed = ProjectTodos.parse(appended, path: "")
        XCTAssertEqual(parsed.items.filter { $0.section == "Fix the upload retry" }.count, 3)
    }

    // MARK: - Personal list and links

    func testThePersonalListLivesInTheGitDirectoryOrFallsBack() {
        let fallback = URL(fileURLWithPath: "/support")
        XCTAssertEqual(PersonalTodos.path(in: "/repo", fallback: fallback, gitPath: { name, _ in "/repo/.git/" + name }),
                       "/repo/.git/octet-todos.md")
        let outside = PersonalTodos.path(in: "/tmp/notes", fallback: fallback, gitPath: { _, _ in nil })
        XCTAssertTrue(outside.hasPrefix("/support/todos/"))
        XCTAssertTrue(outside.hasSuffix(".md"))
        XCTAssertEqual(outside, PersonalTodos.path(in: "/tmp/notes", fallback: fallback, gitPath: { _, _ in nil }))
        XCTAssertEqual(PersonalTodos.linksPath(besideList: "/repo/.git/octet-todos.md"), "/repo/.git/octet-todos.links.json")
    }

    func testLinksFollowRenamesAndArePruned() {
        var links = TodoLinks()
        links["a"] = TodoLink(agent: "claude", agentName: "Claude")
        links["b"] = TodoLink()
        XCTAssertNil(links["b"], "an empty link isn't kept")
        links.rename("a", to: "a2")
        XCTAssertEqual(links["a2"]?.agentName, "Claude")
        XCTAssertNil(links["a"])
        XCTAssertTrue(links.pruned(keeping: ["x"]).links.isEmpty)
    }
}

final class TodoSummaryTests: XCTestCase {
    private func todo(_ status: AgentTodo.Status) -> AgentTodo {
        AgentTodo(id: UUID().uuidString, text: "x", activeText: nil, status: status, detail: nil)
    }

    func testCountsRunningPlansAndBothLists() {
        let summary = TodoSummary(runningPlans: [[todo(.completed), todo(.inProgress)]],
                                  lists: [[.pending, .completed], [.completed]])
        XCTAssertEqual(summary.done, 3)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.text, "3 of 5 tasks")
        XCTAssertEqual(summary.badge, "3/5")
        XCTAssertEqual(summary.statuses, [.completed, .inProgress, .pending, .completed, .completed])
        XCTAssertTrue(summary.segmented)
        XCTAssertFalse(summary.isComplete)
    }

    func testEdgeCases() {
        let none = TodoSummary(runningPlans: [], lists: [])
        XCTAssertEqual(none.text, "")
        XCTAssertFalse(none.isComplete)
        XCTAssertFalse(none.segmented)
        let one = TodoSummary(runningPlans: [], lists: [[.completed]])
        XCTAssertEqual(one.spoken, "1 of 1 task complete")
        XCTAssertTrue(one.isComplete)
        XCTAssertFalse(TodoSummary(runningPlans: [], lists: [Array(repeating: .pending, count: 11)]).segmented)
    }
}
