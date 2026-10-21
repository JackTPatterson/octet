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

    func testEdgeZonesSayWhatMovesAndWhere() {
        XCTAssertEqual(WorkspaceDropTarget.beside(.right).title, "Move Its Terminal Right")
        XCTAssertEqual(WorkspaceDropTarget.beside(.top).title(workspace: "octet"), "Move \u{201C}octet\u{201D} Up")
        XCTAssertEqual(WorkspaceDropTarget.beside(.left).title(workspace: "octet", ownTab: true), "New Shell Left")
        XCTAssertEqual(WorkspaceDropTarget.here.title(workspace: "octet"), "Show Here")
    }

    func testEdgesNameTheirDirections() {
        // An engine that splits on every side is asked for the side itself.
        XCTAssertEqual(SplitEdge.left.rawDirection, "left")
        XCTAssertEqual(SplitEdge.top.rawDirection, "up")
        // Stock Herdr splits right and down; left and up swap after.
        XCTAssertEqual(SplitEdge.left.split, "right")
        XCTAssertTrue(SplitEdge.left.swaps)
        XCTAssertFalse(SplitEdge.right.swaps)
        XCTAssertEqual(SplitEdge.top.opposite, .bottom)
    }

    func testHighlightIsTheHalfTaken() {
        XCTAssertEqual(WorkspaceDropTarget.beside(.right).highlight(in: size), CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(WorkspaceDropTarget.here.highlight(in: size), CGRect(origin: .zero, size: size))
    }
}
