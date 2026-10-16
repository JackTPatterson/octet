import XCTest

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func window(_ name: String = "5h", used: Double, left hours: Double?) -> UsageWindow {
        UsageWindow(name: name, used: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) })
    }

    func testPercentagesAreClampedAndAddUp() {
        XCTAssertEqual(window(used: 0.384, left: 1).percentUsed, 38)
        XCTAssertEqual(window(used: 0.384, left: 1).percentLeft, 62)
        XCTAssertEqual(window(used: 1.3, left: 1).percentUsed, 100)
        XCTAssertEqual(window(used: 1.3, left: 1).percentLeft, 0)
        XCTAssertEqual(window(used: -0.2, left: 1).percentLeft, 100)
    }

    func testElapsedShareOfTheWindow() {
        // A 5-hour window with an hour left is four fifths gone.
        XCTAssertEqual(window(used: 0, left: 1).elapsedShare(at: now) ?? -1, 0.8, accuracy: 1e-9)
        // A weekly window that resets in 3.5 days is halfway.
        XCTAssertEqual(window("7d", used: 0, left: 84).elapsedShare(at: now) ?? -1, 0.5, accuracy: 1e-9)
        // Clamped: a reset further off than the window is long, or already past.
        XCTAssertEqual(window(used: 0, left: 9).elapsedShare(at: now), 0)
        XCTAssertEqual(window(used: 0, left: -1).elapsedShare(at: now), 1)
        // Unknown without a reset or a length.
        XCTAssertNil(window(used: 0.5, left: nil).elapsedShare(at: now))
        XCTAssertNil(window("Opus", used: 0.5, left: 1).elapsedShare(at: now))
    }

    func testPaceAgainstTheClock() {
        // Halfway through a 5-hour window.
        XCTAssertEqual(window(used: 0.5, left: 2.5).pace(at: now), .on)
        XCTAssertEqual(window(used: 0.59, left: 2.5).pace(at: now), .on)
        XCTAssertEqual(window(used: 0.65, left: 2.5).pace(at: now), .ahead)
        XCTAssertEqual(window(used: 0.35, left: 2.5).pace(at: now), .under)
        XCTAssertNil(window(used: 0.35, left: nil).pace(at: now))
        XCTAssertEqual(UsagePace.ahead.phrase, "ahead of pace")
        XCTAssertEqual(UsagePace.under.phrase, "under pace")
        // The report's words come from the same verdict.
        XCTAssertEqual(UsageReport.pace(window(used: 0.65, left: 2.5), at: now), "ahead of pace")
    }

    func testResetsIn() {
        XCTAssertEqual(window(used: 0.1, left: 2 + 10.0 / 60).resetsIn(at: now), "resets in 2h 10m")
        XCTAssertEqual(window("7d", used: 0.1, left: 76).resetsIn(at: now), "resets in 3d 4h")
        XCTAssertEqual(window(used: 0.1, left: 0.25).resetsIn(at: now), "resets in 15m")
        XCTAssertEqual(window(used: 0.1, left: 0.001).resetsIn(at: now), "resets now")
        XCTAssertNil(window(used: 0.1, left: nil).resetsIn(at: now))
    }

    func testLimitOnlyWhenItComesBeforeTheReset() {
        // 80% gone two hours into a 5-hour window: 40 points an hour, so the
        // last 20 last half an hour, well before the reset in three.
        let fast = window(used: 0.8, left: 3)
        let limit = fast.limitBeforeReset(at: now)
        XCTAssertNotNil(limit)
        XCTAssertEqual(limit?.timeIntervalSince(now) ?? 0, 1800, accuracy: 1)
        // 20% gone halfway through lasts past the reset.
        XCTAssertNil(window(used: 0.2, left: 2.5).limitBeforeReset(at: now))
        XCTAssertNil(window(used: 0, left: 2.5).limitBeforeReset(at: now))
    }

    func testTitles() {
        XCTAssertEqual(window(used: 0, left: 1).title, "5-hour limit")
        XCTAssertEqual(window("7d", used: 0, left: 1).title, "Weekly limit")
        XCTAssertEqual(window("12h", used: 0, left: 1).title, "12h limit")
        XCTAssertEqual(window("Opus", used: 0, left: 1).title, "Opus")
    }
}
