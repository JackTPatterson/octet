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
