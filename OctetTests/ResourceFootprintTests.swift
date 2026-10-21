import XCTest

final class ResourceFootprintTests: XCTestCase {
    func testParsingIgnoresMalformedAndNegativeRSS() {
        XCTAssertEqual(ResourceFootprint.parse("10 1 100\n11 10 -4\nbad row\n12 10 25"), [
            .init(pid: 10, parent: 1, bytes: 102400), .init(pid: 12, parent: 10, bytes: 25600)
        ])
    }

    func testOverlappingTreesCountEachProcessOnceAndExcludeUnrelatedProcesses() {
        let rows = ResourceFootprint.parse("10 1 100\n11 10 20\n12 11 30\n20 1 900")
        XCTAssertEqual(ResourceFootprint.total(rows, roots: [10, 11]), 150 * 1024)
        XCTAssertEqual(ResourceFootprint.total(rows, roots: []), 0)
    }

    func testCycleDoesNotLoopAndMissingRootStillFindsChildren() {
        let rows = ResourceFootprint.parse("10 11 100\n11 10 20\n30 99 40")
        XCTAssertEqual(ResourceFootprint.total(rows, roots: [10]), 120 * 1024)
        XCTAssertEqual(ResourceFootprint.total(rows, roots: [99]), 40 * 1024)
    }

    func testMemoryLabels() {
        XCTAssertEqual(ResourceFootprint.label(0), "0.0 MB")
        XCTAssertEqual(ResourceFootprint.label(1_048_576), "1.0 MB")
        XCTAssertEqual(ResourceFootprint.label(1_073_741_824), "1.00 GB")
    }
}
