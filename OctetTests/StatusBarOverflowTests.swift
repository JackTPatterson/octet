import XCTest

final class StatusBarOverflowTests: XCTestCase {
    private func span(_ id: String, _ minX: CGFloat, _ maxX: CGFloat) -> StatusBarOverflow.Span {
        .init(id: id, minX: minX, maxX: maxX)
    }

    func testABarThatFitsNeitherFadesNorHides() {
        let edges = StatusBarOverflow.edges(of: [span("a", 6, 80), span("b", 82, 200)], width: 300)
        XCTAssertEqual(edges, .init())
    }

    func testItemsPastTheTrailingEdgeAreHidden() {
        let edges = StatusBarOverflow.edges(of: [span("a", 0, 100), span("b", 100, 200), span("c", 200, 300)], width: 230)
        XCTAssertFalse(edges.leading)
        XCTAssertTrue(edges.trailing)
        // 30 of c's 100 points show: not enough to count.
        XCTAssertEqual(edges.hidden, ["c"])
    }

    func testScrolledAlongBothEdgesFade() {
        let edges = StatusBarOverflow.edges(of: [span("b", 100, 200), span("a", -90, 10), span("c", 200, 320)], width: 250)
        XCTAssertTrue(edges.leading)
        XCTAssertTrue(edges.trailing)
        XCTAssertEqual(edges.hidden, ["a", "c"])
    }
}
