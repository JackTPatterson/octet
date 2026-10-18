import XCTest
@testable import Octet

final class DiffEdgesTests: XCTestCase {
    func testRemovedThenAddedMeetFlush() {
        let kinds: [DiffLineKind] = [.context, .removed, .added, .context]
        // The pair is one block: only the removed line's top and the added
        // line's bottom are outer corners.
        XCTAssertEqual(DiffStyle.edges(kinds, at: 1).first, true)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 1).last, false)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 2).first, false)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 2).last, true)
    }

    func testLoneChangeRoundsBothEnds() {
        let kinds: [DiffLineKind] = [.context, .added, .context]
        XCTAssertEqual(DiffStyle.edges(kinds, at: 1).first, true)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 1).last, true)
    }

    func testContextNeverRounds() {
        let kinds: [DiffLineKind] = [.context, .added]
        XCTAssertEqual(DiffStyle.edges(kinds, at: 0).first, false)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 0).last, false)
    }

    func testEndsOfTheDiffRound() {
        let kinds: [DiffLineKind] = [.removed, .removed]
        XCTAssertEqual(DiffStyle.edges(kinds, at: 0).first, true)
        XCTAssertEqual(DiffStyle.edges(kinds, at: 1).last, true)
    }
}
