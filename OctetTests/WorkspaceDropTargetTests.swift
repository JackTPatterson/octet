import XCTest

final class WorkspaceDropTargetTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 600)

    func testEdgesSplitAndTheMiddleShowsHere() {
        XCTAssertEqual(WorkspaceDropTarget.at(CGPoint(x: 50, y: 300), in: size), .beside(.left))
        XCTAssertEqual(WorkspaceDropTarget.at(CGPoint(x: 960, y: 300), in: size), .beside(.right))
        XCTAssertEqual(WorkspaceDropTarget.at(CGPoint(x: 500, y: 20), in: size), .beside(.top))
        XCTAssertEqual(WorkspaceDropTarget.at(CGPoint(x: 500, y: 590), in: size), .beside(.bottom))
        XCTAssertEqual(WorkspaceDropTarget.at(CGPoint(x: 500, y: 300), in: size), .here)
        XCTAssertNil(WorkspaceDropTarget.at(.zero, in: .zero))
    }

    func testSplittingAWindowFrame() {
        // Screen coordinates: y grows upward, so "top" is the higher half.
        let frame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let left = WorkspaceDropTarget.split(frame, at: .left)
        XCTAssertEqual(left.new, CGRect(x: 100, y: 50, width: 600, height: 800))
        XCTAssertEqual(left.kept, CGRect(x: 700, y: 50, width: 600, height: 800))
        let top = WorkspaceDropTarget.split(frame, at: .top)
        XCTAssertEqual(top.new, CGRect(x: 100, y: 450, width: 1200, height: 400))
        XCTAssertEqual(top.kept, CGRect(x: 100, y: 50, width: 1200, height: 400))
    }

    func testEdgeZonesSplitTheScreenAndSayWhere() {
        XCTAssertEqual(WorkspaceDropTarget.beside(.right).title, "Split Right Here")
        XCTAssertEqual(WorkspaceDropTarget.beside(.top).title(workspace: "octet"), "Split Up in \u{201C}octet\u{201D}")
        XCTAssertEqual(WorkspaceDropTarget.beside(.left).title(workspace: ""), "Split Left Here")
        XCTAssertEqual(WorkspaceDropTarget.here.title(workspace: "octet"), "Show Here")
    }

    func testAFreshPaneLandsOnTheSideThatIsntKept() {
        // The engine puts a new pane right or below. Keeping the existing
        // pane on the right means the new one goes left: split, then swap.
        XCTAssertTrue(SplitEdge.right.swapsToKeep)
        XCTAssertTrue(SplitEdge.bottom.swapsToKeep)
        XCTAssertFalse(SplitEdge.left.swapsToKeep)
        XCTAssertFalse(SplitEdge.top.swapsToKeep)
        // A new pane taking the dropped side swaps the other way round.
        XCTAssertTrue(SplitEdge.left.swaps)
        XCTAssertFalse(SplitEdge.right.swaps)
    }

    func testHighlightIsTheHalfTaken() {
        XCTAssertEqual(WorkspaceDropTarget.beside(.right).highlight(in: size), CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(WorkspaceDropTarget.here.highlight(in: size), CGRect(origin: .zero, size: size))
    }
}
