import XCTest

final class ContextWindowUsageTests: XCTestCase {
    func testUnknownUsageDoesNotPretendToBeEmpty() {
        let usage = ContextWindowUsage(used: nil, limit: nil, tokens: nil)
        XCTAssertNil(usage.used)
        XCTAssertNil(usage.fraction)
        XCTAssertTrue(usage.parts.isEmpty)
        XCTAssertEqual(usage.cells().count, 216)
    }
    func testOnlyMatchingCallUsageMayBreakDownOccupancy() {
        let tokens = TokenUsage(input: 20, cacheRead: 60, cacheWrite: 10, output: 50)
        let matching = ContextWindowUsage(used: 90, limit: 100, tokens: tokens)
        XCTAssertEqual(matching.parts.map(\.tokens), [20, 60, 10])
        XCTAssertEqual(matching.cells(count: 100).compactMap { $0 }.count, 90)
        let mismatch = ContextWindowUsage(used: 80, limit: 100, tokens: tokens)
        XCTAssertEqual(mismatch.parts.map(\.id), ["context"])
        XCTAssertEqual(mismatch.remaining, 20)
    }
    func testOverfullAndMissingLimitsStayBounded() {
        let full = ContextWindowUsage(used: 130, limit: 100, tokens: nil)
        XCTAssertEqual(full.fraction, 1)
        XCTAssertEqual(full.remaining, 0)
        XCTAssertEqual(full.cells().compactMap { $0 }.count, 216)
        let unknown = ContextWindowUsage(used: 100, limit: 0, tokens: nil)
        XCTAssertNil(unknown.fraction)
        XCTAssertTrue(unknown.cells().allSatisfy { $0 == nil })
        XCTAssertTrue(full.cells(count: 0).isEmpty)
    }
}
