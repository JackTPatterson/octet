import XCTest

final class IdleShelvesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-14 is a Wednesday; 2026-10-12 a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private struct Item: Identifiable, Equatable {
        let id: String
    }

    // MARK: Wake times

    func testAnHourIsAnHour() {
        let now = date(14, 10, 30)
        XCTAssertEqual(SnoozeChoice.hour.wakeTime(now: now, calendar: calendar), date(14, 11, 30))
    }

    func testThisEveningIsSixAndGoneOnceItIsClose() {
        XCTAssertEqual(SnoozeChoice.evening.wakeTime(now: date(14, 10), calendar: calendar), date(14, 18))
        XCTAssertEqual(SnoozeChoice.evening.wakeTime(now: date(14, 17), calendar: calendar), date(14, 18))
        XCTAssertNil(SnoozeChoice.evening.wakeTime(now: date(14, 17, 1), calendar: calendar))
        XCTAssertNil(SnoozeChoice.evening.wakeTime(now: date(14, 21), calendar: calendar))
        XCTAssertFalse(SnoozeChoice.offered(now: date(14, 21), calendar: calendar).contains(.evening))
        XCTAssertEqual(SnoozeChoice.offered(now: date(14, 10), calendar: calendar), SnoozeChoice.allCases)
    }

    func testTomorrowMorningIsNineTomorrowExceptInTheSmallHours() {
        XCTAssertEqual(SnoozeChoice.tomorrowMorning.wakeTime(now: date(14, 15), calendar: calendar), date(15, 9))
        XCTAssertEqual(SnoozeChoice.tomorrowMorning.wakeTime(now: date(14, 23, 50), calendar: calendar), date(15, 9))
        // At 2am the coming morning is today's.
        XCTAssertEqual(SnoozeChoice.tomorrowMorning.wakeTime(now: date(14, 2), calendar: calendar), date(14, 9))
    }

    func testNextWeekIsTheNextMondayMorningAfterToday() {
        // Wednesday → the coming Monday.
        XCTAssertEqual(SnoozeChoice.nextWeek.wakeTime(now: date(14, 15), calendar: calendar), date(19, 9))
        // Monday, even before nine → a week on, not this morning.
        XCTAssertEqual(SnoozeChoice.nextWeek.wakeTime(now: date(12, 7), calendar: calendar), date(19, 9))
        // Sunday → tomorrow.
        XCTAssertEqual(SnoozeChoice.nextWeek.wakeTime(now: date(18, 20), calendar: calendar), date(19, 9))
    }

    func testUntilUsedHasNoWakeTime() {
        XCTAssertNil(SnoozeChoice.untilUsed.wakeTime(now: date(14, 10), calendar: calendar))
        XCTAssertEqual(SnoozeChoice.offered(now: date(14, 21), calendar: calendar).last, .untilUsed)
    }

    // MARK: Shelves

    func testSnoozedComeSoonestFirstThenThoseAWaitHolds() {
        let idle = ["a", "b", "c", "d", "e"].map(Item.init)
        let shelves = IdleShelves.partition(
            idle, wakeTimes: ["b": date(15, 9), "d": date(14, 18), "e": date(15, 9)], heldByWait: ["c", "d"])
        XCTAssertEqual(shelves.snoozed.map(\.id), ["d", "b", "e", "c"])
        XCTAssertEqual(shelves.idle.map(\.id), ["a"])
    }

    func testNothingSnoozedLeavesIdleAsItWas() {
        let idle = ["x", "y"].map(Item.init)
        let shelves = IdleShelves.partition(idle, wakeTimes: ["gone": date(15, 9)])
        XCTAssertTrue(shelves.snoozed.isEmpty)
        XCTAssertEqual(shelves.idle, idle)
    }

    // MARK: Waking

    func testDueWhenTheWakeTimeHasCome() {
        let wakes = ["a": date(14, 10), "b": date(14, 11), "c": date(14, 12)]
        XCTAssertEqual(IdleShelves.due(wakes, now: date(14, 11)), ["a", "b"])
        XCTAssertEqual(IdleShelves.due(wakes, now: date(14, 9)), [])
        XCTAssertEqual(IdleShelves.nextWake(wakes, now: date(14, 11)), date(14, 12))
        XCTAssertNil(IdleShelves.nextWake(wakes, now: date(14, 13)))
    }

    func testAWorkspaceThatLeftIdleForgetsItsWakeTime() {
        let wakes = ["a": date(15, 9), "b": date(15, 9)]
        XCTAssertEqual(IdleShelves.reconcile(wakes, parked: ["a", "z"]), ["a": date(15, 9)])
    }

    func testWakeDescriptions() {
        let now = date(14, 10)
        let locale = Locale(identifier: "en_US_POSIX")
        func describe(_ wake: Date) -> String {
            IdleShelves.wakeDescription(wake, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(describe(date(14, 18)), "at 6:00 PM")
        XCTAssertEqual(describe(date(15, 9)), "tomorrow at 9:00 AM")
        XCTAssertEqual(describe(date(19, 9)), "Monday at 9:00 AM")
        XCTAssertTrue(describe(date(30, 9)).contains("2026"))
    }

    func testWakeLabels() {
        let now = date(14, 10)
        XCTAssertEqual(IdleShelves.wakeLabel(now.addingTimeInterval(20), now: now), "now")
        XCTAssertEqual(IdleShelves.wakeLabel(now.addingTimeInterval(45 * 60), now: now), "in 45m")
        // A moment after snoozing for an hour.
        XCTAssertEqual(IdleShelves.wakeLabel(now.addingTimeInterval(3599), now: now), "in 1h")
        XCTAssertEqual(IdleShelves.wakeLabel(date(14, 18), now: now), "in 8h")
        XCTAssertEqual(IdleShelves.wakeLabel(date(19, 9), now: now), "in 5d")
        XCTAssertEqual(IdleShelves.wakeLabel(now.addingTimeInterval(23.8 * 3600), now: now), "in 1d")
    }
}
