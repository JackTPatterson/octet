import XCTest

final class AgentPresentationTests: XCTestCase {
    func testRuntimePollingDoesNotReplaceIdleOrLoadedContentWithSkeletons() {
        for scanning in [false, true] {
            XCTAssertFalse(AgentPresentationLogic.showsInitialRuntimeLoading(rowCount: 0, scanning: scanning,
                hasUnscannedPane: false, hasUnscannedNativeRoot: false))
            XCTAssertFalse(AgentPresentationLogic.showsInitialRuntimeLoading(rowCount: 3, scanning: scanning,
                hasUnscannedPane: true, hasUnscannedNativeRoot: true))
        }
        XCTAssertTrue(AgentPresentationLogic.showsInitialRuntimeLoading(rowCount: 0, scanning: true,
            hasUnscannedPane: true, hasUnscannedNativeRoot: false))
        XCTAssertTrue(AgentPresentationLogic.showsInitialRuntimeLoading(rowCount: 0, scanning: true,
            hasUnscannedPane: false, hasUnscannedNativeRoot: true))
    }
    func testPanelWidthDependsOnlyOnUserResizeAndAvailableSpace() {
        XCTAssertEqual(AgentPresentationLogic.panelWidth(normal: 420, available: 1200), 420)
        XCTAssertEqual(AgentPresentationLogic.panelWidth(normal: 420, available: 800), 420)
        XCTAssertEqual(AgentPresentationLogic.panelWidth(normal: 700, available: 800), 500)
        XCTAssertEqual(AgentPresentationLogic.panelWidth(normal: 700, available: 1200), 700)
    }
    func testCollapsedBranchDoesNotHideSiblingsOrOtherRoots() {
        let rows = [("root", 0), ("a", 1), ("aa", 2), ("b", 1), ("other", 0)]
        XCTAssertEqual(AgentPresentationLogic.visibleIDs(rows, collapsed: ["a"]), ["root", "a", "b", "other"])
        XCTAssertEqual(AgentPresentationLogic.visibleIDs(rows, collapsed: ["root"]), ["root", "other"])
        XCTAssertEqual(AgentPresentationLogic.visibleIDs(rows, collapsed: ["missing"]), Set(rows.map { $0.0 }))
    }
    func testTreeKeepsOrphansAndCyclesVisibleWithoutInventingOwnership() {
        let rows: [(String, String?)] = [("child", "parent"), ("parent", nil), ("orphan", "gone"), ("a", "b"), ("b", "a")]
        let ordered = RuntimeTree.order(rows, id: { $0.0 }, parent: { $0.1 })
        XCTAssertEqual(ordered.count, 5)
        XCTAssertEqual(ordered[0].0.0, "parent")
        XCTAssertEqual(ordered[1].1, 1)
        XCTAssertEqual(ordered[2].1, 0)
    }
}

final class BackgroundJobCacheTests: XCTestCase {
    func testReadsAgainOnlyWhenTheFileChanges() throws {
        let home = NSTemporaryDirectory() + "octet-jobs-\(UUID().uuidString)"
        let directory = home + "/.claude/jobs/j1"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = directory + "/state.json"
        try #"{"detail":"first"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: path)
        let cache = BackgroundJobCache()
        XCTAssertEqual(cache.load(id: "j1", home: home)?.detail, "first")
        // Same modification time: the cached copy, not the new text.
        try #"{"detail":"second"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: path)
        XCTAssertEqual(cache.load(id: "j1", home: home)?.detail, "first")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: path)
        XCTAssertEqual(cache.load(id: "j1", home: home)?.detail, "second")
        XCTAssertNil(cache.load(id: "missing", home: home))
    }
}

final class RuntimeGroupingTests: XCTestCase {
    func testFocusedThenLoudestThenRecent() {
        let now = Date()
        let groups: [RuntimeGrouping.Group] = [
            .init(id: "idle", focused: false, state: .idle, recency: now),
            .init(id: "asks", focused: false, state: .needsApproval, recency: nil),
            .init(id: "front", focused: true, state: .done, recency: nil),
            .init(id: "old", focused: false, state: .working, recency: now.addingTimeInterval(-60)),
            .init(id: "new", focused: false, state: .working, recency: now),
        ]
        XCTAssertEqual(RuntimeGrouping.order(groups), ["front", "asks", "new", "old", "idle"])
    }

    func testOnlyTheFocusedStartsOpenPastThree() {
        XCTAssertEqual(RuntimeGrouping.initiallyExpanded(["a", "b"], focused: nil), ["a", "b"])
        XCTAssertEqual(RuntimeGrouping.initiallyExpanded(["a", "b", "c", "d"], focused: "c"), ["c"])
        XCTAssertEqual(RuntimeGrouping.initiallyExpanded(["a", "b", "c", "d"], focused: nil), ["a"])
    }

    func testFinishedFoldKeepsLiveBranches() {
        let rows: [RuntimeGrouping.Row] = [
            .init(id: "p", parent: nil, finished: true),
            .init(id: "c", parent: "p", finished: false),
            .init(id: "q", parent: nil, finished: true),
            .init(id: "q1", parent: "q", finished: true),
        ]
        XCTAssertEqual(RuntimeGrouping.finished(rows), ["q", "q1"])
    }

    func testSummary() {
        XCTAssertEqual(RuntimeGrouping.summary(subagents: 3, tasks: 1, monitors: 0), "3 subagents · 1 task")
        XCTAssertEqual(RuntimeGrouping.summary(subagents: 0, tasks: 0, monitors: 0), "")
    }
}

final class RuntimeSeenTests: XCTestCase {
    func testFinishedRowsAreUnreadUntilSeen() {
        var seen = RuntimeSeen()
        XCTAssertTrue(seen.isUnread(id: "a", state: .done))
        XCTAssertTrue(seen.isUnread(id: "a", state: .failed))
        XCTAssertFalse(seen.isUnread(id: "a", state: .working))
        seen.markRead(["a"])
        XCTAssertFalse(seen.isUnread(id: "a", state: .done))
        seen.markUnread("a")
        XCTAssertTrue(seen.isUnread(id: "a", state: .done))
    }

    func testDismissMarksReadAndRestoreBringsBack() {
        var seen = RuntimeSeen()
        seen.dismiss(["a", "b"])
        XCTAssertTrue(seen.isDismissed("a"))
        XCTAssertFalse(seen.isUnread(id: "a", state: .done))
        seen.restore(["a"])
        XCTAssertFalse(seen.isDismissed("a"))
        XCTAssertTrue(seen.isDismissed("b"))
    }

    func testOldestGoWhenFull() {
        var seen = RuntimeSeen()
        seen.markRead((0..<(RuntimeSeen.limit + 5)).map(String.init))
        XCTAssertEqual(seen.seen.count, RuntimeSeen.limit)
        XCTAssertTrue(seen.isUnread(id: "0", state: .done))
        XCTAssertFalse(seen.isUnread(id: "\(RuntimeSeen.limit + 4)", state: .done))
    }
}
