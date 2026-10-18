import XCTest

final class CustomSnoozeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    /// 2026-10-14 is a Wednesday.
    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func testComposesADayAndATime() {
        XCTAssertEqual(CustomSnooze.date(day: date(10, 20, 23, 59), hour: 9, minute: 30, calendar: calendar), date(10, 20, 9, 30))
        XCTAssertNil(CustomSnooze.date(day: date(10, 20, 0), hour: 24, minute: 0, calendar: calendar))
        XCTAssertNil(CustomSnooze.date(day: date(10, 20, 0), hour: 1, minute: 60, calendar: calendar))
    }

    func testOnlyTheFutureCanBePicked() {
        let now = date(10, 14, 12)
        XCTAssertNil(CustomSnooze.problem(with: date(10, 14, 12, 5), now: now))
        XCTAssertEqual(CustomSnooze.problem(with: date(10, 14, 11), now: now), "Choose a time in the future.")
        // Less than a minute off is over before the dialog closes.
        XCTAssertNotNil(CustomSnooze.problem(with: now.addingTimeInterval(30), now: now))
        XCTAssertEqual(CustomSnooze.problem(with: nil, now: now), "Choose a valid date and time.")
    }

    func testStartsAnHourOutRoundedToFiveMinutes() {
        let pick = CustomSnooze.initialPick(now: date(10, 14, 12, 7, second: 10), calendar: calendar)
        XCTAssertEqual(pick.day, date(10, 14, 0))
        XCTAssertEqual(pick.hour, 13)
        XCTAssertEqual(pick.minute, 10)
        // Rounding past the hour, and past midnight.
        let late = CustomSnooze.initialPick(now: date(10, 14, 22, 58), calendar: calendar)
        XCTAssertEqual(late.day, date(10, 15, 0))
        XCTAssertEqual(late.hour, 0)
        XCTAssertEqual(late.minute, 0)
        let exact = CustomSnooze.initialPick(now: date(10, 14, 9, 15), calendar: calendar)
        XCTAssertEqual(exact.hour, 10)
        XCTAssertEqual(exact.minute, 15)
    }

    func testTwelveHourClock() {
        XCTAssertEqual(CustomSnooze.hour24(12, pm: false), 0)
        XCTAssertEqual(CustomSnooze.hour24(12, pm: true), 12)
        XCTAssertEqual(CustomSnooze.hour24(9, pm: true), 21)
        XCTAssertTrue(CustomSnooze.hour12(0) == (12, false))
        XCTAssertTrue(CustomSnooze.hour12(12) == (12, true))
        XCTAssertTrue(CustomSnooze.hour12(17) == (5, true))
        for hour in 0..<24 {
            let clock = CustomSnooze.hour12(hour)
            XCTAssertEqual(CustomSnooze.hour24(clock.hour, pm: clock.pm), hour)
        }
    }

    func testPresetsAreFutureSortedAndDistinct() {
        let now = date(10, 14, 12) // Wednesday noon
        let presets = CustomSnooze.presets(now: now, calendar: calendar)
        XCTAssertEqual(presets.map(\.id), ["30m", "3h", "tomorrow", "tomorrow-afternoon", "weekend", "next-week"])
        XCTAssertEqual(presets.first { $0.id == "tomorrow" }?.date, date(10, 15, 9))
        XCTAssertEqual(presets.first { $0.id == "weekend" }?.date, date(10, 17, 9))
        XCTAssertEqual(presets.first { $0.id == "next-week" }?.date, date(10, 19, 9))
        XCTAssertEqual(presets.map(\.date), presets.map(\.date).sorted())
        // At the weekend there's no "this weekend".
        let saturday = CustomSnooze.presets(now: date(10, 17, 10), calendar: calendar)
        XCTAssertFalse(saturday.contains { $0.id == "weekend" })
    }

    func testMonthGrid() {
        // October 2026 starts on a Thursday: four blanks with Sunday first.
        let grid = CustomSnooze.monthGrid(containing: date(10, 14, 12), calendar: calendar)
        XCTAssertEqual(grid.count % 7, 0)
        XCTAssertEqual(grid.prefix(4).filter { $0 == nil }.count, 4)
        XCTAssertEqual(grid[4], date(10, 1, 0))
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
        XCTAssertEqual(grid.compactMap { $0 }.last, date(10, 31, 0))
        var monday = calendar
        monday.firstWeekday = 2
        let mondayGrid = CustomSnooze.monthGrid(containing: date(10, 14, 12), calendar: monday)
        XCTAssertEqual(mondayGrid.prefix(while: { $0 == nil }).count, 3)
        XCTAssertEqual(CustomSnooze.weekdaySymbols(calendar: monday).count, 7)
        XCTAssertEqual(CustomSnooze.weekdaySymbols(calendar: monday).first, monday.veryShortStandaloneWeekdaySymbols[1])
    }
}
