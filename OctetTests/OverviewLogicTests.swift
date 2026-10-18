import XCTest

final class OverviewLogicTests: XCTestCase {
    // MARK: Runtime state

    func testStateIsReadFromTheDetailWord() {
        XCTAssertEqual(RuntimeState.classify(detail: "Running"), .running)
        XCTAssertEqual(RuntimeState.classify(detail: "94s"), .running)
        XCTAssertEqual(RuntimeState.classify(detail: "2m 10s"), .running)
        XCTAssertEqual(RuntimeState.classify(detail: "Needs input"), .waiting)
        XCTAssertEqual(RuntimeState.classify(detail: "Waiting"), .waiting)
        XCTAssertEqual(RuntimeState.classify(detail: "Failed"), .failed)
        XCTAssertEqual(RuntimeState.classify(detail: "Exited with code 2"), .failed)
        XCTAssertEqual(RuntimeState.classify(detail: "Finished"), .done)
    }

    func testGenericWordsAreLeftToTheIcon() {
        XCTAssertNil(RuntimeState.label(forDetail: "Running"))
        XCTAssertNil(RuntimeState.label(forDetail: "active"))
        XCTAssertEqual(RuntimeState.label(forDetail: "Needs input"), "Needs input")
        XCTAssertEqual(RuntimeState.label(forDetail: "1m 5s"), "1m 5s")
    }

    func testLastLineSkipsBlanks() {
        XCTAssertEqual(RuntimeState.lastLine(of: "one\ntwo\n\n  \n"), "two")
        XCTAssertNil(RuntimeState.lastLine(of: " \n"))
        XCTAssertNil(RuntimeState.lastLine(of: nil))
    }

    // MARK: Tree guides

    func testFlatRowsHaveNoGuides() {
        XCTAssertEqual(TreeGuides.compute(depths: [0, 0]), [TreeGuide(verticals: [], isLast: true),
                                                           TreeGuide(verticals: [], isLast: true)])
    }

    func testChildrenElbowAndTheLastClosesTheLine() {
        // root, child, child, root
        let guides = TreeGuides.compute(depths: [0, 1, 1, 0])
        XCTAssertFalse(guides[1].isLast)
        XCTAssertTrue(guides[2].isLast)
        XCTAssertEqual(guides[1].verticals, [])
    }

    func testGrandchildrenRunALineThroughWhileSiblingsRemain() {
        // root, child A, grandchild, child B
        let guides = TreeGuides.compute(depths: [0, 1, 2, 1])
        XCTAssertFalse(guides[1].isLast)          // B follows A
        XCTAssertEqual(guides[2].verticals, [true]) // the line down from root to B passes the grandchild
        XCTAssertTrue(guides[2].isLast)
        XCTAssertTrue(guides[3].isLast)
    }

    func testNoLineThroughAfterTheLastSibling() {
        // root, only child, grandchild
        let guides = TreeGuides.compute(depths: [0, 1, 2])
        XCTAssertTrue(guides[1].isLast)
        XCTAssertEqual(guides[2].verticals, [false])
    }

    // MARK: Todos

    private func todo(_ id: String, _ status: AgentTodo.Status) -> AgentTodo {
        AgentTodo(id: id, text: id, activeText: nil, status: status, detail: nil)
    }

    func testProgressCountsAndSummary() {
        let progress = TodoProgress([todo("a", .completed), todo("b", .completed), todo("c", .inProgress), todo("d", .pending), todo("e", .pending)])
        XCTAssertEqual(progress.done, 2)
        XCTAssertEqual(progress.total, 5)
        XCTAssertEqual(progress.remaining, 3)
        XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(progress.summary, "2 of 5")
        XCTAssertFalse(progress.isComplete)
    }

    func testCompletedPlanSaysDone() {
        let progress = TodoProgress([todo("a", .completed)])
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.summary, "Done")
        XCTAssertEqual(TodoProgress([]).fraction, 0)
        XCTAssertFalse(TodoProgress([]).isComplete)
    }

    func testStepsSplitKeepingOrder() {
        let split = TodoSteps.split([todo("a", .completed), todo("b", .pending), todo("c", .inProgress), todo("d", .completed)])
        XCTAssertEqual(split.open.map(\.id), ["b", "c"])
        XCTAssertEqual(split.done.map(\.id), ["a", "d"])
    }

    private func item(_ line: Int, _ section: String?, _ status: AgentTodo.Status = .pending) -> ProjectTodoList.Item {
        .init(line: line, text: "item \(line)", status: status, section: section)
    }

    func testGroupingKeepsHeadingOrderAndMergesRepeats() {
        let groups = ProjectTodoGrouping.groups([item(0, nil), item(1, "Release"), item(2, "Later"), item(3, "Release")])
        XCTAssertEqual(groups.map(\.title), [nil, "Release", "Later"])
        XCTAssertEqual(groups[1].items.map(\.line), [1, 3])
        XCTAssertTrue(ProjectTodoGrouping.groups([]).isEmpty)
    }

    // MARK: Agent Setup

    func testSummaryCountsCommandsAndMCPOnce() {
        XCTAssertEqual(AgentSetupSummary.summary(rules: ["Bash(ls:*)", "Bash(ls:*)", "Bash(git status:*)", "mcp__a__b", "mcp__a__c"]),
                       "2 allowed commands · 2 MCP")
        XCTAssertEqual(AgentSetupSummary.summary(rules: ["Edit"]), "1 allowed command")
        XCTAssertEqual(AgentSetupSummary.summary(rules: ["mcp__x__y"]), "1 MCP")
        XCTAssertNil(AgentSetupSummary.summary(rules: []))
    }

    func testRulesReadAsPeopleSayThem() {
        XCTAssertEqual(AgentSetupSummary.display(rule: "Bash(git status:*)"), "git status *")
        XCTAssertEqual(AgentSetupSummary.display(rule: "Bash(xcodegen generate)"), "xcodegen generate")
        XCTAssertEqual(AgentSetupSummary.display(rule: "mcp__linear__create_issue"), "linear · create_issue")
        XCTAssertEqual(AgentSetupSummary.display(rule: "WebFetch(domain:x.com)"), "WebFetch(domain:x.com)")
    }

    // MARK: Folding and quiet sections

    func testMostSectionsOpenUntilFoldedAndSetupStaysFoldedUntilOpened() {
        var state = FoldState()
        XCTAssertTrue(state.isOpen("todos"))
        XCTAssertFalse(state.isOpen("setup", opensByDefault: false))
        state.set("todos", open: false)
        state.set("setup", open: true, opensByDefault: false)
        XCTAssertFalse(state.isOpen("todos"))
        XCTAssertTrue(state.isOpen("setup", opensByDefault: false))
        state.set("todos", open: true)
        state.set("setup", open: false, opensByDefault: false)
        XCTAssertTrue(state.isOpen("todos"))
        XCTAssertFalse(state.isOpen("setup", opensByDefault: false))
    }

    func testOnlyAnEmptyLoadedSectionIsQuiet() {
        XCTAssertTrue(OverviewSections.isQuiet(count: 0, loading: false))
        XCTAssertFalse(OverviewSections.isQuiet(count: 0, loading: true))
        XCTAssertFalse(OverviewSections.isQuiet(count: 2, loading: false))
    }
}
