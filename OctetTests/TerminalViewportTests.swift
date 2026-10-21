import XCTest

final class TerminalViewportTests: XCTestCase {
    func testRejectsTransientLayoutSizesWithoutUnsignedConversionTraps() {
        for size in [CGSize.zero, CGSize(width: -1, height: 100),
                     CGSize(width: CGFloat.nan, height: 100), CGSize(width: 100, height: CGFloat.infinity),
                     CGSize(width: CGFloat(UInt32.max) + 1, height: 100), CGSize(width: 0.5, height: 100)] {
            XCTAssertNil(TerminalPixelSize(size))
        }
    }

    func testFractionalPointsWithSameFramebufferDimensionsAreEquivalent() throws {
        let first = try XCTUnwrap(TerminalPixelSize(CGSize(width: 1600.2, height: 1200.9)))
        let next = try XCTUnwrap(TerminalPixelSize(CGSize(width: 1600.8, height: 1200.1)))
        XCTAssertEqual(first, next)
        XCTAssertEqual(first.width, 1600)
        XCTAssertNotEqual(first, TerminalPixelSize(CGSize(width: 1601, height: 1200)))
    }
}
