import XCTest

final class MonitorLayoutsTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let portrait = CGRect(x: 1512, y: 0, width: 1080, height: 1920)

    func testOneDisplayOffersTwoToFourWindows() {
        let options = MonitorArrangement.across([laptop])
        XCTAssertEqual(options.map(\.title), ["2 Windows", "3 Windows", "4 Windows"])
        XCTAssertEqual(options[0].frames, [CGRect(x: 0, y: 0, width: 756, height: 944), CGRect(x: 756, y: 0, width: 756, height: 944)])
    }

    func testSeveralDisplaysGetOneEachAndTheCurrentComesFirst() {
        let options = MonitorArrangement.across([laptop, portrait], current: 1)
        XCTAssertEqual(options.first?.title, "1 on Each Display")
        XCTAssertEqual(options.first?.frames, [portrait, laptop])
        XCTAssertEqual(options[1].frames.count, 4)
    }

    func testPortraitDisplaysStackInsteadOfSqueezing() {
        let two = MonitorArrangement.split(portrait, into: 2)
        XCTAssertEqual(two.map(\.width), [1080, 1080])
        XCTAssertEqual(two.map(\.height), [960, 960])
        // Top first: AppKit's origin is at the bottom.
        XCTAssertGreaterThan(two[0].minY, two[1].minY)
    }

    func testLayoutsTurnForPortrait() {
        let columns = [PaneLayoutNode.Rect(x: 0, y: 0, width: 0.5, height: 1), PaneLayoutNode.Rect(x: 0.5, y: 0, width: 0.5, height: 1)]
        let rows = MonitorArrangement.fitted(columns, toPortrait: true)
        XCTAssertEqual(rows[1], PaneLayoutNode.Rect(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertEqual(MonitorArrangement.fitted(columns, toPortrait: false), columns)
    }
}
