import XCTest

final class SpaceHoldTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testATapTypesASpace() {
        var hold = SpaceHold()
        XCTAssertEqual(hold.down(at: start, text: "fix"), .type)
        XCTAssertEqual(hold.up(), .type)
        XCTAssertFalse(hold.listening)
    }

    func testHoldingTalksAndTakesTheSpacesBack() {
        var hold = SpaceHold()
        XCTAssertEqual(hold.down(at: start, text: "fix"), .type)
        // The first repeats come before the threshold: still typing.
        XCTAssertEqual(hold.repeated(at: start.addingTimeInterval(0.2)), .type)
        XCTAssertEqual(hold.repeated(at: start.addingTimeInterval(0.4)), .startListening(restore: "fix"))
        XCTAssertEqual(hold.repeated(at: start.addingTimeInterval(0.5)), .swallow)
        XCTAssertEqual(hold.up(), .stopListening)
        XCTAssertFalse(hold.listening)
        XCTAssertEqual(hold.down(at: start.addingTimeInterval(2), text: "x"), .type, "the next tap types again")
    }

    func testACancelledStartTypesAgain() {
        var hold = SpaceHold()
        _ = hold.down(at: start, text: "")
        _ = hold.repeated(at: start.addingTimeInterval(1))
        hold.cancel()
        XCTAssertEqual(hold.up(), .type)
    }

    func testWhatWasSaidJoinsTheText() {
        XCTAssertEqual(SpaceHold.inserting(" Fix the login loop. ", into: ""), "Fix the login loop.")
        XCTAssertEqual(SpaceHold.inserting("and add a test", into: "Fix it"), "Fix it and add a test")
        XCTAssertEqual(SpaceHold.inserting("then", into: "Fix it\n"), "Fix it\nthen")
        XCTAssertEqual(SpaceHold.inserting("  ", into: "Fix it"), "Fix it")
    }
}
