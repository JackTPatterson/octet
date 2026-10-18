import XCTest

final class NotchLogicTests: XCTestCase {
    // A 14-inch MacBook Pro: 1512x982 points, a 38pt notch 200pt wide.
    private let notched = NotchScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 38,
                                      auxLeftWidth: 656, auxRightWidth: 656)
    private let external = NotchScreen(id: 2, frame: CGRect(x: 1512, y: 100, width: 2560, height: 1440), safeAreaTop: 0)

    // MARK: Geometry

    func testNotchSizeComesFromTheSideAreas() {
        XCTAssertEqual(NotchGeometry.notchSize(notched), CGSize(width: 200, height: 38))
    }

    func testNotchWithoutReportedSidesFallsBackToTheUsualWidth() {
        var screen = notched
        screen.auxLeftWidth = 0
        screen.auxRightWidth = 0
        XCTAssertEqual(NotchGeometry.notchSize(screen).width, NotchGeometry.fallbackNotchWidth)
        // Sides wider than the screen are nonsense, not a negative notch.
        screen.auxLeftWidth = 1000
        screen.auxRightWidth = 1000
        XCTAssertEqual(NotchGeometry.notchSize(screen).width, NotchGeometry.fallbackNotchWidth)
    }

    func testDisplayWithoutANotchGetsAPill() {
        XCTAssertFalse(external.hasNotch)
        XCTAssertEqual(NotchGeometry.notchSize(external), NotchGeometry.pillSize)
        XCTAssertEqual(NotchGeometry.bandHeight(external), NotchGeometry.flatBandHeight)
        XCTAssertEqual(NotchGeometry.cameraGap(external), 0)
        XCTAssertEqual(NotchGeometry.bandHeight(notched), 38)
        XCTAssertEqual(NotchGeometry.cameraGap(notched), 200)
    }

    func testIdleCollapsedIslandIsExactlyTheNotch() {
        XCTAssertEqual(NotchGeometry.collapsedSize(notched, glyphs: NotchGlyphs()), CGSize(width: 200, height: 38))
    }

    func testGlyphsWidenTheIslandEvenlyOnBothSides() {
        let glyphs = NotchGlyphs.make(NotchActivity(working: 2, needsYou: 0, ready: 0, usage: nil))
        let size = NotchGeometry.collapsedSize(notched, glyphs: glyphs)
        // Only the left has glyphs, but the island stays centred on the notch.
        XCTAssertEqual(size.width, 200 + 2 * glyphs.leftWidth + 2 * NotchGeometry.collapsedEar)
        XCTAssertEqual(size.height, 38)
        let rect = NotchGeometry.islandRect(notched, size: size)
        XCTAssertEqual(rect.midX, notched.frame.midX, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, notched.frame.maxY)
    }

    func testIslandHangsFromTheTopCentreOfAnyDisplay() {
        let rect = NotchGeometry.islandRect(external, size: CGSize(width: 400, height: 100))
        XCTAssertEqual(rect.midX, external.frame.midX)
        XCTAssertEqual(rect.maxY, external.frame.maxY)
        XCTAssertEqual(rect.size, CGSize(width: 400, height: 100))
    }

    func testExpandedSizeGrowsWithContentButStopsAtTheMaximum() {
        let small = NotchGeometry.expandedSize(notched, size: .regular, contentHeight: 20)
        XCTAssertEqual(small.height, 38 + NotchGeometry.minContentHeight)
        let big = NotchGeometry.expandedSize(notched, size: .regular, contentHeight: 900)
        XCTAssertEqual(big.height, NotchGeometry.regularMaxHeight)
        XCTAssertEqual(big.width, NotchGeometry.regularWidth)
        let compact = NotchGeometry.expandedSize(notched, size: .compact, contentHeight: 900)
        XCTAssertEqual(compact.height, NotchGeometry.compactMaxHeight)
        XCTAssertEqual(compact.width, NotchGeometry.compactWidth)
    }

    func testExpandedIslandNeverOutgrowsANarrowScreen() {
        var narrow = notched
        narrow.frame = CGRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertLessThanOrEqual(NotchGeometry.expandedSize(narrow, size: .regular, contentHeight: 200).width, 500)
    }

    func testPanelHoldsTheLargestIslandAndItsShadow() {
        let panel = NotchGeometry.panelRect(notched, size: .regular)
        let island = NotchGeometry.maxIslandSize(notched, size: .regular)
        XCTAssertEqual(panel.midX, notched.frame.midX)
        XCTAssertEqual(panel.maxY, notched.frame.maxY)
        XCTAssertGreaterThan(panel.width, island.width)
        XCTAssertGreaterThan(panel.height, island.height)
    }

    func testHotZoneRunsToTheTopEdgeAndIsNeverTinyToHit() {
        let pill = NotchGeometry.islandRect(external, size: NotchGeometry.pillSize)
        let zone = NotchGeometry.hotZone(island: pill, screen: external)
        XCTAssertGreaterThanOrEqual(zone.width, 160)
        XCTAssertGreaterThanOrEqual(zone.height, 14)
        XCTAssertEqual(zone.maxY, external.frame.maxY)
        XCTAssertEqual(zone.midX, external.frame.midX, accuracy: 0.001)
    }

    func testPointerOnTheTopEdgeCountsAsInside() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertTrue(NotchGeometry.contains(frame, CGPoint(x: 50, y: 50)))
        XCTAssertTrue(NotchGeometry.contains(frame, CGPoint(x: 100, y: 0)))
        XCTAssertFalse(NotchGeometry.contains(frame, CGPoint(x: 50, y: 51)))
    }

    func testPanelSitsAboveTheMenuBarAndItsStatusItems() {
        XCTAssertGreaterThan(NotchGeometry.panelLevel, NotchGeometry.statusItemLevel)
        XCTAssertGreaterThan(NotchGeometry.statusItemLevel, NotchGeometry.menuBarLevel)
        XCTAssertEqual(NotchGeometry.menuBarLevel, 24)
        XCTAssertEqual(NotchGeometry.statusItemLevel, 25)
    }

    func testPanelReallyOverlapsTheMenuBar() {
        // The panel's top edge is the screen's top edge, not the menu bar's bottom.
        let panel = NotchGeometry.panelRect(notched, size: .regular)
        XCTAssertEqual(panel.maxY, notched.frame.maxY)
        XCTAssertGreaterThan(panel.maxY, notched.frame.maxY - notched.safeAreaTop)
    }

    func testCollapsedIslandCoversOnlyTheNotchAndItsGlyphs() {
        let idle = NotchGeometry.collapsedSize(notched, glyphs: NotchGlyphs())
        XCTAssertEqual(idle.width, NotchGeometry.notchSize(notched).width)
        let glyphs = NotchGlyphs.make(NotchActivity(working: 1))
        XCTAssertLessThan(NotchGeometry.collapsedSize(notched, glyphs: glyphs).width, 400)
    }

    // MARK: Which screens

    func testMainDisplayIsThePrimaryOneWhateverTheSettingsOrPointer() {
        let ids = NotchScreenChooser.targets(displays: .main, screens: [notched, external], primaryID: 1,
                                             pointer: CGPoint(x: 2000, y: 500), showWithoutNotch: true)
        XCTAssertEqual(ids, [1])
    }

    func testPointerModeFollowsTheScreenUnderThePointer() {
        let on: (CGPoint) -> [Int] = { point in
            NotchScreenChooser.targets(displays: .pointer, screens: [self.notched, self.external], primaryID: 1,
                                       pointer: point, showWithoutNotch: true)
        }
        XCTAssertEqual(on(CGPoint(x: 100, y: 100)), [1])
        XCTAssertEqual(on(CGPoint(x: 2000, y: 500)), [2])
        // The very top edge belongs to the display too.
        XCTAssertEqual(on(CGPoint(x: 2000, y: external.frame.maxY)), [2])
        // Off every display: back to the primary.
        XCTAssertEqual(on(CGPoint(x: -500, y: -500)), [1])
    }

    func testAllDisplaysShowsEveryOne() {
        let ids = NotchScreenChooser.targets(displays: .all, screens: [notched, external], primaryID: 1,
                                             pointer: .zero, showWithoutNotch: true)
        XCTAssertEqual(ids, [1, 2])
    }

    func testDisplaysWithoutANotchCanBeLeftOut() {
        XCTAssertEqual(NotchScreenChooser.targets(displays: .all, screens: [notched, external], primaryID: 1,
                                                  pointer: .zero, showWithoutNotch: false), [1])
        // Main display is the one without a notch and they asked for none.
        XCTAssertEqual(NotchScreenChooser.targets(displays: .main, screens: [external, notched], primaryID: 2,
                                                  pointer: .zero, showWithoutNotch: false), [])
        XCTAssertEqual(NotchScreenChooser.targets(displays: .main, screens: [], primaryID: nil, pointer: .zero,
                                                  showWithoutNotch: true), [])
    }

    func testPrimaryFallsBackToTheFirstScreen() {
        XCTAssertEqual(NotchScreenChooser.targets(displays: .main, screens: [external, notched], primaryID: 99,
                                                  pointer: .zero, showWithoutNotch: true), [2])
    }

    // MARK: Full screen

    func testFullScreenHidesUnlessAskedFor() {
        XCTAssertTrue(NotchVisibility.shouldShow(enabled: true, fullScreenFront: false, showInFullScreen: false))
        XCTAssertFalse(NotchVisibility.shouldShow(enabled: true, fullScreenFront: true, showInFullScreen: false))
        XCTAssertTrue(NotchVisibility.shouldShow(enabled: true, fullScreenFront: true, showInFullScreen: true))
        XCTAssertFalse(NotchVisibility.shouldShow(enabled: false, fullScreenFront: false, showInFullScreen: true))
    }

    func testOnlyAWindowCoveringTheWholeDisplayIsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertTrue(NotchVisibility.coversScreen(window: screen, screen: screen))
        XCTAssertTrue(NotchVisibility.coversScreen(window: screen.insetBy(dx: -1, dy: -1), screen: screen))
        // A maximised window leaves the menu bar.
        XCTAssertFalse(NotchVisibility.coversScreen(window: CGRect(x: 0, y: 38, width: 1512, height: 944), screen: screen))
        XCTAssertFalse(NotchVisibility.coversScreen(window: CGRect(x: 0, y: 0, width: 800, height: 600), screen: screen))
    }

    // MARK: Glyphs

    func testQuietActivityShowsNothing() {
        let glyphs = NotchGlyphs.make(NotchActivity())
        XCTAssertTrue(glyphs.isEmpty)
        XCTAssertTrue(NotchActivity().isQuiet)
        XCTAssertEqual(glyphs.leftWidth, 0)
        XCTAssertEqual(glyphs.rightWidth, 0)
    }

    func testGlyphsSplitAgentsLeftAndTheRestRight() {
        let glyphs = NotchGlyphs.make(NotchActivity(working: 3, needsYou: 1, ready: 2,
                                                    usage: NotchUsageWarning(agent: "Claude", percent: 91, level: .critical)))
        XCTAssertEqual(glyphs.left, [.working(3), .needsYou(1)])
        XCTAssertEqual(glyphs.right, [.ready(2), .usage(NotchUsageWarning(agent: "Claude", percent: 91, level: .critical))])
        XCTAssertGreaterThan(glyphs.leftWidth, 0)
        XCTAssertGreaterThan(glyphs.rightWidth, 0)
    }

    func testOnlyWhatIsHappeningGetsAGlyph() {
        XCTAssertEqual(NotchGlyphs.make(NotchActivity(working: 1)).left, [.working(1)])
        XCTAssertTrue(NotchGlyphs.make(NotchActivity(working: 1)).right.isEmpty)
        XCTAssertEqual(NotchGlyphs.make(NotchActivity(needsYou: 2)).left, [.needsYou(2)])
        XCTAssertEqual(NotchGlyphs.make(NotchActivity(ready: 1)).right, [.ready(1)])
    }

    func testACountOnlyShowsAboveOne() {
        XCTAssertLessThan(NotchGlyph.working(1).width, NotchGlyph.working(2).width)
        XCTAssertLessThan(NotchGlyph.working(9).width, NotchGlyph.working(10).width)
    }

    func testUsageWarnsFromEightyPercentAndShoutsFromNinety() {
        XCTAssertNil(NotchUsageWarning.worst([]))
        XCTAssertNil(NotchUsageWarning.worst([("claude", 0.79)]))
        XCTAssertEqual(NotchUsageWarning.worst([("claude", 0.8)])?.level, .warn)
        XCTAssertEqual(NotchUsageWarning.worst([("claude", 0.9)])?.level, .critical)
        let worst = NotchUsageWarning.worst([("claude", 0.5), ("codex", 0.93)])
        XCTAssertEqual(worst?.agent, "codex")
        XCTAssertEqual(worst?.percent, 93)
        XCTAssertEqual(NotchUsageWarning.worst([("claude", 1.4)])?.percent, 100)
    }

    func testAccessibilityLabelSaysWhatIsHappening() {
        XCTAssertEqual(NotchGlyphs().accessibilityLabel, "Octet Notch, nothing happening")
        let label = NotchGlyphs.make(NotchActivity(working: 2, needsYou: 1)).accessibilityLabel
        XCTAssertTrue(label.contains("2 agents working"))
        XCTAssertTrue(label.contains("1 agent needs you"))
    }

    // MARK: Agent rows

    private func row(_ id: String, _ status: NotchAgentRow.Status, title: String = "t", since: Double? = nil) -> NotchAgentRow {
        NotchAgentRow(id: id, vendor: "claude", title: title, workspace: nil, detail: nil, status: status,
                      since: since.map { Date(timeIntervalSince1970: $0) })
    }

    func testRowsOrderWaitingThenWorkingThenSettled() {
        let rows = [row("done", .done, since: 5), row("work", .working, since: 5), row("wait", .needsInput, since: 5)]
        XCTAssertEqual(NotchAgentOrdering.sorted(rows).map(\.id), ["wait", "work", "done"])
    }

    func testLongestWaitingAndLongestRunningComeFirstNewestSettledFirst() {
        let rows = [
            row("wait-new", .needsInput, since: 200), row("wait-old", .needsInput, since: 100),
            row("work-new", .working, since: 300), row("work-old", .working, since: 150),
            row("done-old", .done, since: 10), row("done-new", .done, since: 90),
        ]
        XCTAssertEqual(NotchAgentOrdering.sorted(rows).map(\.id),
                       ["wait-old", "wait-new", "work-old", "work-new", "done-new", "done-old"])
    }

    func testRowsWithoutATimeComeAfterTimedOnesAndTiesAreStable() {
        let rows = [row("b", .working, title: "Beta"), row("a", .working, title: "alpha"), row("c", .working, title: "Gamma", since: 1)]
        XCTAssertEqual(NotchAgentOrdering.sorted(rows).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(NotchAgentOrdering.sorted(rows.reversed()).map(\.id), ["c", "a", "b"])
        let same = [row("2", .done, title: "x"), row("1", .done, title: "x")]
        XCTAssertEqual(NotchAgentOrdering.sorted(same).map(\.id), ["1", "2"])
    }

    func testVisibleRowsAlwaysKeepWhatNeedsYouAndWhatWorks() {
        let rows = (0..<4).map { row("w\($0)", .working, since: Double($0)) }
            + [row("n", .needsInput, since: 1)]
            + (0..<5).map { row("d\($0)", .done, since: Double($0)) }
        let result = NotchAgentOrdering.visible(rows, limit: 6)
        XCTAssertEqual(result.shown.count, 6)
        XCTAssertEqual(result.hidden, 4)
        XCTAssertEqual(result.shown.first?.id, "n")
        XCTAssertEqual(result.shown.filter { $0.status == .done }.map(\.id), ["d4"])
        // Even a limit smaller than the urgent rows doesn't hide them.
        let tight = NotchAgentOrdering.visible(rows, limit: 2)
        XCTAssertEqual(tight.shown.count, 5)
        XCTAssertEqual(tight.hidden, 5)
    }

    func testActivityCountsWorkingAndWaiting() {
        let rows = [row("a", .working), row("b", .working), row("c", .needsInput), row("d", .done)]
        let counts = NotchAgentOrdering.activity(of: rows)
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.needsYou, 1)
    }

    // MARK: Peeks

    private func event(_ id: String, _ kind: AgentEvent.Kind, label: String = "migrate schema", agent: String? = "claude") -> AgentEvent {
        AgentEvent(id: id, kind: kind, agent: agent, paneId: "p", tabId: "t", workspaceId: "w", label: label, workedFor: nil, at: Date())
    }

    func testAPeekIsOnlyForSomeoneLookingAway() {
        XCTAssertTrue(NotchPeekRules.shouldPeek(enabled: true, octetActive: false, visible: true, phase: .collapsed))
        XCTAssertFalse(NotchPeekRules.shouldPeek(enabled: false, octetActive: false, visible: true, phase: .collapsed))
        XCTAssertFalse(NotchPeekRules.shouldPeek(enabled: true, octetActive: true, visible: true, phase: .collapsed))
        XCTAssertFalse(NotchPeekRules.shouldPeek(enabled: true, octetActive: false, visible: false, phase: .collapsed))
        XCTAssertFalse(NotchPeekRules.shouldPeek(enabled: true, octetActive: false, visible: true, phase: .expanded))
        // A newer notice may replace one already showing.
        XCTAssertTrue(NotchPeekRules.shouldPeek(enabled: true, octetActive: false, visible: true, phase: .peek))
    }

    func testPeekLineSaysWhoAndWhat() {
        XCTAssertNil(NotchPeekRules.compose([]))
        let finished = NotchPeekRules.compose([event("1", .finished)])
        XCTAssertEqual(finished?.line, "migrate schema finished")
        XCTAssertEqual(finished?.more, 0)
        let waiting = NotchPeekRules.compose([event("2", .needsInput, label: "review auth")])
        XCTAssertEqual(waiting?.line, "review auth needs you")
    }

    func testSomeoneWaitingOutranksSomeoneFinishing() {
        let peek = NotchPeekRules.compose([event("1", .needsInput, label: "review auth"), event("2", .finished, label: "later")])
        XCTAssertEqual(peek?.kind, .needsInput)
        XCTAssertEqual(peek?.line, "review auth needs you")
        XCTAssertEqual(peek?.more, 1)
    }

    func testAnUnnamedAgentFallsBackToItsBrand() {
        XCTAssertEqual(NotchPeekRules.compose([event("1", .finished, label: "  ", agent: "claude")])?.line, "Claude Code finished")
        XCTAssertEqual(NotchPeekRules.compose([event("1", .finished, label: "", agent: nil)])?.line, "An agent finished")
    }

    // MARK: Interaction

    func testHoverOpensAfterAShortPause() {
        var machine = NotchMachine()
        XCTAssertEqual(machine.handle(.pointerEntered), [.startTimer(.expand, NotchMachine.hoverDelay)])
        XCTAssertEqual(machine.phase, .collapsed)
        XCTAssertEqual(machine.handle(.timerFired(.expand)), [.cancelTimer, .expand])
        XCTAssertEqual(machine.phase, .expanded)
    }

    func testPassingOverTheNotchDoesNotOpenIt() {
        var machine = NotchMachine()
        _ = machine.handle(.pointerEntered)
        XCTAssertEqual(machine.handle(.pointerExited), [.cancelTimer])
        // The timer that was already scheduled fires into nothing.
        XCTAssertEqual(machine.handle(.timerFired(.expand)), [])
        XCTAssertEqual(machine.phase, .collapsed)
    }

    func testClickModeIgnoresHoverButOpensOnClick() {
        var machine = NotchMachine(expandOnHover: false)
        XCTAssertEqual(machine.handle(.pointerEntered), [])
        XCTAssertEqual(machine.handle(.clicked), [.cancelTimer, .expand])
        XCTAssertEqual(machine.phase, .expanded)
    }

    func testClickOpensImmediatelyInHoverModeToo() {
        var machine = NotchMachine()
        _ = machine.handle(.pointerEntered)
        XCTAssertEqual(machine.handle(.clicked), [.cancelTimer, .expand])
    }

    func testLeavingClosesAfterAGraceDelay() {
        var machine = open()
        XCTAssertEqual(machine.handle(.pointerExited), [.startTimer(.collapse, NotchMachine.collapseGrace)])
        XCTAssertEqual(machine.phase, .expanded)
        XCTAssertEqual(machine.handle(.timerFired(.collapse)), [.cancelTimer, .collapse])
        XCTAssertEqual(machine.phase, .collapsed)
    }

    func testComingBackWithinTheGraceKeepsItOpen() {
        var machine = open()
        _ = machine.handle(.pointerExited)
        XCTAssertEqual(machine.handle(.pointerEntered), [.cancelTimer])
        XCTAssertEqual(machine.handle(.timerFired(.collapse)), [])
        XCTAssertEqual(machine.phase, .expanded)
    }

    func testAFocusedTextFieldKeepsItOpen() {
        var machine = open()
        _ = machine.handle(.textFocus(true))
        XCTAssertEqual(machine.handle(.pointerExited), [])
        XCTAssertEqual(machine.handle(.timerFired(.collapse)), [])
        XCTAssertEqual(machine.phase, .expanded)
        // Letting go of the field with the pointer away starts the countdown.
        XCTAssertEqual(machine.handle(.textFocus(false)), [.startTimer(.collapse, NotchMachine.collapseGrace)])
    }

    func testFocusingTextCancelsACountdownInProgress() {
        var machine = open()
        _ = machine.handle(.pointerExited)
        XCTAssertEqual(machine.handle(.textFocus(true)), [.cancelTimer])
        XCTAssertEqual(machine.handle(.timerFired(.collapse)), [])
    }

    func testEscapeClosesEvenWithTextFocused() {
        var machine = open()
        _ = machine.handle(.textFocus(true))
        XCTAssertEqual(machine.handle(.escape), [.cancelTimer, .collapse])
        XCTAssertEqual(machine.phase, .collapsed)
        XCTAssertEqual(machine.handle(.escape), [])
    }

    func testClickingAwayClosesButClickingInsideDoesNot() {
        var inside = open()
        _ = inside.handle(.pointerEntered)
        XCTAssertEqual(inside.handle(.clickedAway), [])
        var away = open()
        XCTAssertEqual(away.handle(.clickedAway), [.cancelTimer, .collapse])
        var closed = NotchMachine()
        XCTAssertEqual(closed.handle(.clickedAway), [])
    }

    func testAStaleTimerIsIgnored() {
        var machine = NotchMachine()
        _ = machine.handle(.pointerEntered)
        _ = machine.handle(.pointerExited)
        _ = machine.handle(.pointerEntered)
        // Only the latest start counts; the same timer fires, and the pointer
        // is still there.
        XCTAssertEqual(machine.handle(.timerFired(.collapse)), [])
        XCTAssertEqual(machine.handle(.timerFired(.expand)), [.cancelTimer, .expand])
    }

    func testPeekShowsThenEndsOnItsOwn() {
        var machine = NotchMachine()
        XCTAssertEqual(machine.handle(.peek(4)), [.showPeek, .startTimer(.endPeek, 4)])
        XCTAssertEqual(machine.phase, .peek)
        XCTAssertEqual(machine.handle(.timerFired(.endPeek)), [.cancelTimer, .collapse])
        XCTAssertEqual(machine.phase, .collapsed)
    }

    func testAPeekWaitsWhileThePointerIsOnIt() {
        var machine = NotchMachine(expandOnHover: false)
        _ = machine.handle(.peek(4))
        XCTAssertEqual(machine.handle(.pointerEntered), [.cancelTimer])
        XCTAssertEqual(machine.handle(.timerFired(.endPeek)), [])
        XCTAssertEqual(machine.phase, .peek)
        XCTAssertEqual(machine.handle(.pointerExited), [.startTimer(.endPeek, NotchMachine.peekGrace)])
        XCTAssertEqual(machine.handle(.timerFired(.endPeek)), [.cancelTimer, .collapse])
    }

    func testHoveringAPeekOpensTheIslandInHoverMode() {
        var machine = NotchMachine()
        _ = machine.handle(.peek(4))
        XCTAssertEqual(machine.handle(.pointerEntered), [.cancelTimer, .expand])
        XCTAssertEqual(machine.phase, .expanded)
    }

    func testClickingAPeekOpensIt() {
        var machine = NotchMachine(expandOnHover: false)
        _ = machine.handle(.peek(4))
        XCTAssertEqual(machine.handle(.clicked), [.cancelTimer, .expand])
    }

    func testAPeekNeverInterruptsAnOpenIsland() {
        var machine = open()
        XCTAssertEqual(machine.handle(.peek(4)), [])
        XCTAssertEqual(machine.phase, .expanded)
    }

    func testANewPeekReplacesOneShowing() {
        var machine = NotchMachine()
        _ = machine.handle(.peek(4))
        XCTAssertEqual(machine.handle(.peek(4)), [.showPeek, .startTimer(.endPeek, 4)])
        XCTAssertEqual(machine.phase, .peek)
    }

    private func open() -> NotchMachine {
        var machine = NotchMachine()
        _ = machine.handle(.clicked)
        return machine
    }

    // MARK: Settings

    func testNotchIsOffByDefaultWithEveryPage() {
        let settings = NotchSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.expand, .hover)
        XCTAssertEqual(settings.displays, .main)
        XCTAssertEqual(settings.shownTabs, NotchTab.allCases)
        XCTAssertFalse(settings.showInFullScreen)
    }

    func testSettingsRoundTripAndTolerateMissingKeys() throws {
        var settings = NotchSettings()
        settings.enabled = true
        settings.expand = .click
        settings.size = .compact
        settings.set(.usage, shown: false)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(NotchSettings.self, from: data), settings)

        let partial = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"enabled":true,"future":1}"#.utf8))
        XCTAssertTrue(partial.enabled)
        XCTAssertEqual(partial.expand, .hover)
        XCTAssertEqual(partial.tabs, NotchTab.allCases)
        let junk = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"expand":"wave","tabs":["agents","nope"]}"#.utf8))
        XCTAssertEqual(junk.expand, .hover)
        XCTAssertEqual(junk.tabs, [.agents])
    }

    func testTabsKeepTheirOrderAndNeverAllDisappear() {
        var settings = NotchSettings()
        settings.set(.now, shown: false)
        XCTAssertEqual(settings.shownTabs, [.agents, .usage, .actions])
        settings.set(.now, shown: true)
        XCTAssertEqual(settings.shownTabs, NotchTab.allCases)
        settings.tabs = []
        XCTAssertEqual(settings.shownTabs, [.agents])
    }

    // MARK: Text

    func testElapsedTimeIsShort() {
        let start = Date(timeIntervalSince1970: 1_000)
        func after(_ seconds: Double) -> String { NotchText.elapsed(from: start, now: start.addingTimeInterval(seconds)) }
        XCTAssertEqual(after(-5), "0s")
        XCTAssertEqual(after(42), "42s")
        XCTAssertEqual(after(125), "2m")
        XCTAssertEqual(after(3_600), "1h")
        XCTAssertEqual(after(3_900), "1h 5m")
        XCTAssertEqual(after(90_000), "1d")
    }
}
