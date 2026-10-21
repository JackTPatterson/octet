import XCTest

final class CheckInRecurrenceTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0, zone: String = "UTC") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parts(_ date: Date, zone: String = "UTC") -> DateComponents {
        calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func testEveryNDaysAndWeeksCountFromTheStart() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        let days = CheckInRecurrence.every(3, .days, startingAt: start)
        XCTAssertEqual(days.next(after: start, calendar: utc), date(2026, 10, 4))
        XCTAssertEqual(days.next(after: date(2026, 10, 4), calendar: utc), date(2026, 10, 7))
        XCTAssertEqual(days.next(after: date(2026, 10, 5, 12), calendar: utc), date(2026, 10, 7))
        // Before the start, the start itself is the first.
        XCTAssertEqual(days.next(after: date(2026, 9, 1), calendar: utc), start)
        let weeks = CheckInRecurrence.every(2, .weeks, startingAt: start)
        XCTAssertEqual(weeks.next(after: start, calendar: utc), date(2026, 10, 15))
        let hours = CheckInRecurrence.every(6, .hours, startingAt: start)
        XCTAssertEqual(hours.next(after: start, calendar: utc), date(2026, 10, 1, 15))
        XCTAssertEqual(hours.next(after: date(2026, 10, 1, 15), calendar: utc), date(2026, 10, 1, 21))
    }

    func testMonthsKeepTheirDayAcrossShortMonths() {
        let utc = calendar()
        let monthly = CheckInRecurrence.every(1, .months, startingAt: date(2026, 1, 31))
        let feb = monthly.next(after: date(2026, 1, 31), calendar: utc)
        XCTAssertEqual(feb, date(2026, 2, 28))
        // Counted from the start, not from February 28th: March is the 31st again.
        XCTAssertEqual(monthly.next(after: feb!, calendar: utc), date(2026, 3, 31))
        XCTAssertEqual(monthly.next(after: date(2026, 3, 31), calendar: utc), date(2026, 4, 30))
        // Leap years.
        let leap = CheckInRecurrence.every(1, .months, startingAt: date(2028, 1, 31))
        XCTAssertEqual(leap.next(after: date(2028, 1, 31), calendar: utc), date(2028, 2, 29))
        let quarterly = CheckInRecurrence.every(3, .months, startingAt: date(2026, 11, 30))
        XCTAssertEqual(quarterly.next(after: date(2026, 11, 30), calendar: utc), date(2027, 2, 28))
    }

    func testDailyAndWeeklyAtATimeOfDay() {
        let utc = calendar()
        let now = date(2026, 10, 18, 10)
        let daily = CheckInRecurrence.daily(hour: 9, minute: 30, after: now, calendar: utc)
        XCTAssertEqual(daily.start, date(2026, 10, 19, 9, 30))
        XCTAssertEqual(daily.next(after: daily.start, calendar: utc), date(2026, 10, 20, 9, 30))
        // Earlier the same day, today's is the first.
        let early = CheckInRecurrence.daily(hour: 9, minute: 30, after: date(2026, 10, 18, 8), calendar: utc)
        XCTAssertEqual(early.start, date(2026, 10, 18, 9, 30))

        // 2026-10-18 is a Sunday; Monday is weekday 2.
        let weekly = CheckInRecurrence.weekly(weekday: 2, hour: 8, minute: 30, after: now, calendar: utc)
        XCTAssertEqual(weekly.start, date(2026, 10, 19, 8, 30))
        XCTAssertEqual(weekly.next(after: weekly.start, calendar: utc), date(2026, 10, 26, 8, 30))
    }

    func testDaylightSavingKeepsTheWallClockTime() {
        let zone = "America/New_York"
        let newYork = calendar(zone)
        // Spring forward: March 8th 2026. A 9:00 check-in stays at 9:00 on the clock.
        let before = date(2026, 3, 7, 8, zone: zone)
        let daily = CheckInRecurrence.daily(hour: 9, minute: 0, after: before, calendar: newYork)
        XCTAssertEqual(parts(daily.start, zone: zone).hour, 9)
        let second = daily.next(after: daily.start, calendar: newYork)!
        XCTAssertEqual(parts(second, zone: zone).day, 8)
        XCTAssertEqual(parts(second, zone: zone).hour, 9)
        XCTAssertEqual(second.timeIntervalSince(daily.start), 23 * 3600, "the day the clocks go forward is 23 hours long")
        // Every 1 day (counted from a start) keeps the wall clock too, every 24 hours does not.
        let start = date(2026, 3, 7, 9, zone: zone)
        let byDay = CheckInRecurrence.every(1, .days, startingAt: start)
        XCTAssertEqual(parts(byDay.next(after: start, calendar: newYork)!, zone: zone).hour, 9)
        let byHours = CheckInRecurrence.every(24, .hours, startingAt: start)
        XCTAssertEqual(parts(byHours.next(after: start, calendar: newYork)!, zone: zone).hour, 10)
        // A time that doesn't exist that day (2:30 on spring-forward day) lands later that day, not a day late.
        let gap = CheckInRecurrence.daily(hour: 2, minute: 30, after: date(2026, 3, 7, 12, zone: zone), calendar: newYork)
        let landed = parts(gap.start, zone: zone)
        XCTAssertEqual(landed.day, 8)
        XCTAssertGreaterThanOrEqual(landed.hour ?? 0, 3)
        // Fall back: November 1st 2026 is 25 hours long; 9:00 stays 9:00.
        let fall = CheckInRecurrence.daily(hour: 9, minute: 0, after: date(2026, 10, 31, 8, zone: zone), calendar: newYork)
        let after = fall.next(after: fall.start, calendar: newYork)!
        XCTAssertEqual(parts(after, zone: zone).hour, 9)
        XCTAssertEqual(after.timeIntervalSince(fall.start), 25 * 3600)
    }

    func testTheEndDateStopsIt() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        let rule = CheckInRecurrence.every(1, .days, startingAt: start, until: date(2026, 10, 3, 12))
        XCTAssertEqual(rule.next(after: date(2026, 10, 2), calendar: utc), date(2026, 10, 3))
        XCTAssertNil(rule.next(after: date(2026, 10, 3), calendar: utc))
        XCTAssertEqual(rule.missed(after: start, upTo: date(2026, 11, 1), calendar: utc), 2)
    }

    func testSummaries() {
        let start = date(2026, 10, 1)
        XCTAssertEqual(CheckInRecurrence.every(1, .days, startingAt: start).summary, "Every day")
        XCTAssertEqual(CheckInRecurrence.every(6, .hours, startingAt: start).summary, "Every 6 hours")
        XCTAssertEqual(CheckInRecurrence.every(2, .weeks, startingAt: start, count: 4).summary, "Every 2 weeks, 4 times")
        XCTAssertEqual(CheckInRecurrence.daily(hour: 9, minute: 0, after: start).summary, "Every day at 9:00 AM")
        XCTAssertEqual(CheckInRecurrence.weekly(weekday: 2, hour: 20, minute: 15, after: start).summary, "Every Monday at 8:15 PM")
    }

    // MARK: Catching up

    func testMissedOccurrencesCollapseIntoOneCatchUp() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        let rule = CheckInRecurrence.every(1, .days, startingAt: start)
        var info = CheckInInfo(mode: .wake, recurrence: rule)
        // Octet was closed for ten and a half days.
        let now = date(2026, 10, 11, 21)
        let result = info.occur(due: start, now: now, calendar: utc)
        XCTAssertEqual(result.missed, 10)
        XCTAssertEqual(result.next, date(2026, 10, 12), "the next one is the first still ahead, not a flood of ten")
        XCTAssertEqual(info.fired, 11)
        XCTAssertNil(info.finishedAt)

        // Hourly ones too: three days and an hour late, every six hours.
        var hourly = CheckInInfo(mode: .both, recurrence: .every(6, .hours, startingAt: start))
        let late = hourly.occur(due: start, now: start.addingTimeInterval(73 * 3600), calendar: utc)
        XCTAssertEqual(late.missed, 12)
        XCTAssertEqual(late.next, start.addingTimeInterval(78 * 3600))
    }

    func testOnTimeIsNotMissed() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        var info = CheckInInfo(mode: .remind, recurrence: .every(1, .days, startingAt: start))
        let result = info.occur(due: start, now: start.addingTimeInterval(30), calendar: utc)
        XCTAssertEqual(result.missed, 0)
        XCTAssertEqual(result.next, date(2026, 10, 2))
    }

    func testCountAndOneOffsFinish() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        var counted = CheckInInfo(mode: .wake, recurrence: .every(1, .days, startingAt: start, count: 3))
        XCTAssertNotNil(counted.occur(due: start, now: start, calendar: utc).next)
        XCTAssertNotNil(counted.occur(due: date(2026, 10, 2), now: date(2026, 10, 2), calendar: utc).next)
        XCTAssertNil(counted.occur(due: date(2026, 10, 3), now: date(2026, 10, 3), calendar: utc).next)
        XCTAssertTrue(counted.isFinished)

        // Downtime that would have used up the count finishes it too.
        var lapsed = CheckInInfo(mode: .wake, recurrence: .every(1, .days, startingAt: start, count: 3))
        XCTAssertNil(lapsed.occur(due: start, now: date(2026, 10, 20), calendar: utc).next)
        XCTAssertTrue(lapsed.isFinished)

        var once = CheckInInfo(mode: .remind, recurrence: nil)
        XCTAssertNil(once.occur(due: start, now: start, calendar: utc).next)
        XCTAssertTrue(once.isFinished)
        XCTAssertEqual(once.statusLine(nextDue: start), "Done")
    }

    func testEditingAFinishedOneRunsItsWholeScheduleAgain() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        var info = CheckInInfo(mode: .both, recurrence: .every(1, .days, startingAt: start, count: 2))
        _ = info.occur(due: start, now: start, calendar: utc)
        _ = info.occur(due: date(2026, 10, 2), now: date(2026, 10, 2), calendar: utc)
        info.dueSince = date(2026, 10, 2)
        info.dueMissed = 1
        XCTAssertTrue(info.isFinished)

        let restart = date(2026, 11, 1)
        info.reschedule(.every(1, .days, startingAt: restart, count: 2), nextDue: restart, previousDue: date(2026, 10, 2))
        XCTAssertFalse(info.isFinished)
        XCTAssertEqual(info.fired, 0)
        XCTAssertNil(info.dueSince)
        XCTAssertEqual(info.dueMissed, 0)
        // Both runs, not one.
        XCTAssertNotNil(info.occur(due: restart, now: restart, calendar: utc).next)
        XCTAssertNil(info.occur(due: date(2026, 11, 2), now: date(2026, 11, 2), calendar: utc).next)
    }

    func testEditingOnlyTheWordsKeepsTheCount() {
        let utc = calendar()
        let start = date(2026, 10, 1)
        let rule = CheckInRecurrence.every(1, .days, startingAt: start, count: 3)
        var info = CheckInInfo(mode: .both, recurrence: rule)
        _ = info.occur(due: start, now: start, calendar: utc)
        let next = date(2026, 10, 2)
        // The sheet starts the rule at the next time; same rule, same time.
        info.reschedule(.every(1, .days, startingAt: next, count: 3), nextDue: next, previousDue: next)
        XCTAssertEqual(info.fired, 1)
        // Another rule starts counting again.
        info.reschedule(.every(2, .days, startingAt: next, count: 3), nextDue: next, previousDue: next)
        XCTAssertEqual(info.fired, 0)
    }

    func testOlderCheckInsMissingDefaultedFieldsStillLoad() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {"mode": "both", "recurrence": {"kind": "daily", "start": "2026-10-01T09:00:00Z"},
         "log": [{"at": "2026-10-01T09:00:00Z", "due": "2026-10-01T09:00:00Z", "outcome": "somethingNew"}]}
        """
        let info = try decoder.decode(CheckInInfo.self, from: Data(json.utf8))
        XCTAssertFalse(info.paused)
        XCTAssertEqual(info.fired, 0)
        XCTAssertEqual(info.recurrence?.hour, 9)
        XCTAssertEqual(info.recurrence?.every, 1)
        XCTAssertEqual(info.log.count, 1)
        XCTAssertEqual(info.log[0].outcome, .skipped)
        XCTAssertFalse(info.log[0].manual)
    }

    func testTheRecordKeepsTheLatestEntries() {
        var info = CheckInInfo(mode: .both, recurrence: nil)
        for index in 0..<(CheckInInfo.logLimit + 5) {
            info.append(CheckInLogEntry(at: Date(timeIntervalSince1970: Double(index)), due: Date(), sessionAlive: nil, outcome: .reminded))
        }
        XCTAssertEqual(info.log.count, CheckInInfo.logLimit)
        XCTAssertEqual(info.log.first?.at, Date(timeIntervalSince1970: 5))
        let id = info.log[0].id
        info.update(id) { $0.outcome = .resumedSession }
        XCTAssertEqual(info.log[0].outcome, .resumedSession)
    }

    func testLogLinesSayWhatHappened() {
        let entry = CheckInLogEntry(at: Date(timeIntervalSince1970: 1_800_000_000), due: Date(), sessionAlive: false,
                                    outcome: .resumedSession, missed: 2, note: "in ~/api")
        let line = entry.line()
        XCTAssertTrue(line.contains("session was gone"))
        XCTAssertTrue(line.contains("resumed it"))
        XCTAssertTrue(line.contains("2 missed"))
        XCTAssertTrue(line.hasSuffix("in ~/api"))
    }
}

final class CheckInQuietHoursTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testOvernightWindow() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertTrue(quiet.contains(at(18, 22), calendar: calendar))
        XCTAssertTrue(quiet.contains(at(18, 23, 59), calendar: calendar))
        XCTAssertTrue(quiet.contains(at(19, 3), calendar: calendar))
        XCTAssertTrue(quiet.contains(at(19, 6, 59), calendar: calendar))
        XCTAssertFalse(quiet.contains(at(19, 7), calendar: calendar), "the end is the first minute that's allowed")
        XCTAssertFalse(quiet.contains(at(19, 12), calendar: calendar))
        XCTAssertFalse(quiet.contains(at(19, 21, 59), calendar: calendar))
    }

    func testWakesQueueToTheEnd() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertEqual(quiet.end(after: at(18, 23, 30), calendar: calendar), at(19, 7))
        XCTAssertEqual(quiet.end(after: at(19, 3), calendar: calendar), at(19, 7))
        XCTAssertNil(quiet.end(after: at(19, 12), calendar: calendar))
    }

    func testDaytimeWindowAndOff() {
        let lunch = QuietHours(enabled: true, startMinute: 12 * 60, endMinute: 13 * 60)
        XCTAssertTrue(lunch.contains(at(18, 12, 30), calendar: calendar))
        XCTAssertFalse(lunch.contains(at(18, 13), calendar: calendar))
        XCTAssertEqual(lunch.end(after: at(18, 12, 30), calendar: calendar), at(18, 13))
        XCTAssertFalse(QuietHours(enabled: false, startMinute: 0, endMinute: 23 * 60).contains(at(18, 5), calendar: calendar))
        XCTAssertFalse(QuietHours(enabled: true, startMinute: 600, endMinute: 600).contains(at(18, 10), calendar: calendar))
        XCTAssertEqual(QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60).summary, "10:00 PM – 7:00 AM")
    }

    func testResumeThrottle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(WakeThrottle.slots(recent: [], now: now), 3)
        XCTAssertEqual(WakeThrottle.slots(recent: [now.addingTimeInterval(-10), now.addingTimeInterval(-60)], now: now), 1)
        XCTAssertEqual(WakeThrottle.slots(recent: [now, now, now, now], now: now), 0)
        // Ones that resumed a while ago free their slot.
        XCTAssertEqual(WakeThrottle.slots(recent: [now.addingTimeInterval(-WakeThrottle.window - 1), now], now: now), 2)
    }
}

final class StallTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let threshold: TimeInterval = StallTracker.defaultThreshold

    private func subject(_ token: String = "a", working: Bool = true, id: String = "s1") -> StallTracker.Subject {
        .init(id: id, label: "Claude", isWorking: working, token: token)
    }

    func testDefaultIsSixHours() {
        XCTAssertEqual(StallTracker.defaultThreshold, 6 * 3600)
    }

    func testReportsOnlyAfterTheThreshold() {
        var tracker = StallTracker()
        XCTAssertTrue(tracker.observe([subject()], now: start, threshold: threshold).isEmpty)
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(threshold - 60), threshold: threshold).isEmpty)
        let found = tracker.observe([subject()], now: start.addingTimeInterval(threshold), threshold: threshold)
        XCTAssertEqual(found.map(\.id), ["s1"])
        XCTAssertEqual(found.first?.quietFor, threshold)
        // Once, not on every look after.
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(threshold + 600), threshold: threshold).isEmpty)
    }

    func testActivityStartsTheClockAgain() {
        var tracker = StallTracker()
        _ = tracker.observe([subject("a")], now: start, threshold: threshold)
        _ = tracker.observe([subject("b")], now: start.addingTimeInterval(5 * 3600), threshold: threshold)
        XCTAssertTrue(tracker.observe([subject("b")], now: start.addingTimeInterval(10 * 3600), threshold: threshold).isEmpty)
        XCTAssertEqual(tracker.observe([subject("b")], now: start.addingTimeInterval(11 * 3600), threshold: threshold).count, 1)
        // And after being reported, doing something makes it reportable again later.
        _ = tracker.observe([subject("c")], now: start.addingTimeInterval(12 * 3600), threshold: threshold)
        XCTAssertEqual(tracker.observe([subject("c")], now: start.addingTimeInterval(18 * 3600), threshold: threshold).count, 1)
    }

    func testOnlyWorkingSessionsCount() {
        var tracker = StallTracker()
        _ = tracker.observe([subject(working: false)], now: start, threshold: threshold)
        XCTAssertTrue(tracker.observe([subject(working: false)], now: start.addingTimeInterval(24 * 3600), threshold: threshold).isEmpty)
        XCTAssertEqual(tracker.tracked, 0)
        // Going idle and coming back to work resets the clock.
        _ = tracker.observe([subject()], now: start.addingTimeInterval(25 * 3600), threshold: threshold)
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(30 * 3600), threshold: threshold).isEmpty)
    }

    func testSnoozeAndIgnore() {
        var tracker = StallTracker()
        _ = tracker.observe([subject()], now: start, threshold: threshold)
        XCTAssertEqual(tracker.observe([subject()], now: start.addingTimeInterval(threshold), threshold: threshold).count, 1)
        tracker.snooze("s1", until: start.addingTimeInterval(threshold + 2 * 3600))
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(threshold + 3600), threshold: threshold).isEmpty)
        XCTAssertEqual(tracker.observe([subject()], now: start.addingTimeInterval(threshold + 2 * 3600), threshold: threshold).count, 1)
        tracker.ignore("s1")
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(threshold * 4), threshold: threshold).isEmpty)
        // Until it does something and goes quiet again.
        _ = tracker.observe([subject("new")], now: start.addingTimeInterval(threshold * 5), threshold: threshold)
        XCTAssertEqual(tracker.observe([subject("new")], now: start.addingTimeInterval(threshold * 6), threshold: threshold).count, 1)
    }

    func testZeroThresholdNeverReportsAndGoneSessionsAreForgotten() {
        var tracker = StallTracker()
        _ = tracker.observe([subject()], now: start, threshold: 0)
        XCTAssertTrue(tracker.observe([subject()], now: start.addingTimeInterval(100 * 3600), threshold: 0).isEmpty)
        XCTAssertEqual(tracker.tracked, 1)
        _ = tracker.observe([], now: start.addingTimeInterval(101 * 3600), threshold: 0)
        XCTAssertEqual(tracker.tracked, 0)
    }

    func testScreensCompareByWordsNotByMovingParts() {
        let before = "● Backtesting walk-forward folds\n✻ Thinking… (12s · ↓ 1.2k tokens)\n"
        let after = "● Backtesting walk-forward folds\n✶ Thinking… (4m 47s · ↓ 1.2k tokens)\n"
        XCTAssertEqual(StallTracker.fingerprint(screen: before), StallTracker.fingerprint(screen: after))
        let moved = "● Backtesting walk-forward folds\n● Wrote results.csv\n✶ Thinking… (4m 47s)\n"
        XCTAssertNotEqual(StallTracker.fingerprint(screen: before), StallTracker.fingerprint(screen: moved))
    }
}

final class CheckInSuggestionTests: XCTestCase {
    func testMultiDayWorkIsNoticed() {
        let cases: [(String, Double)] = [
            ("I've started the paper-trading run. Let it run for 2 weeks and we can compare it with the benchmark.", 14),
            ("The walk-forward backtest will take about 3 days to finish.", 3),
            ("Leave it running for a couple of days, then check back.", 2),
            ("Results in a week or so; check back then.", 7),
            ("Give it a week to accumulate enough fills.", 7),
            ("We should let this run for several days before judging it.", 5),
            ("The soak test needs to run for 1 month.", 30),
        ]
        for (text, days) in cases {
            let found = CheckInSuggestion.detect(text)
            XCTAssertNotNil(found, text)
            XCTAssertEqual(found?.delay, days * 86_400, text)
            XCTAssertTrue(found?.prompt.contains("Check back") == true)
        }
    }

    func testConservativeAboutEverythingElse() {
        let not = [
            "The build will take 5 minutes.",
            "Should I let it run for 2 weeks?",
            "Do you want me to check back in 3 days?",
            "It ran for 3 days last time and nothing went wrong.",
            "I checked in with the team yesterday.",
            "Done. The tests pass.",
            "The cache lasts 7 days.",
            "```\nsleep 86400  # run for 2 weeks\n```",
            "> let it run for 2 weeks",
            "Let it run for 3 hours.",
        ]
        for text in not { XCTAssertNil(CheckInSuggestion.detect(text), text) }
    }

    func testLongRunningTasksAndMonitorsPastTwelveHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func runtime(_ kind: HandoffRuntime.Kind, hoursAgo: Double, title: String = "paper trader") -> HandoffRuntime {
            HandoffRuntime(id: UUID().uuidString, kind: kind, title: title, command: "python run.py", prompt: nil,
                           startedAt: now.addingTimeInterval(-hoursAgo * 3600), expiresAt: nil)
        }
        XCTAssertNil(CheckInSuggestion.longRunning([runtime(.task, hoursAgo: 11.9)], now: now))
        let found = CheckInSuggestion.longRunning([runtime(.task, hoursAgo: 12.1), runtime(.monitor, hoursAgo: 30, title: "log watcher")], now: now)
        XCTAssertEqual(found?.delay, 86_400)
        XCTAssertTrue(found?.reason.contains("log watcher") == true, "the longest-running one is named")
        XCTAssertNil(CheckInSuggestion.longRunning([runtime(.agent, hoursAgo: 48)], now: now))
        XCTAssertNil(CheckInSuggestion.longRunning([], now: now))
    }

    func testBackgroundTasksAreReadFromTheConversation() {
        func tool(_ id: String, _ name: String, _ input: [String: Any], result: String) -> AgentItem {
            AgentItem(id: id, kind: .tool(AgentToolCall(name: name, summary: "", input: "",
                                                        inputData: try? JSONSerialization.data(withJSONObject: input), result: result)))
        }
        let started = tool("t1", "Bash", ["command": "python run.py", "run_in_background": true, "description": "Paper trader"],
                           result: "Command running in background with ID: bg_91ab")
        let foreground = tool("t2", "Bash", ["command": "ls"], result: "ok")
        XCTAssertEqual(CheckInSuggestion.runtimes(from: [started, foreground]).map(\.title), ["Paper trader"])
        // Its own id turning up later means it reported back.
        let done = AgentItem(id: "u2", kind: .user("<task-notification>bg_91ab completed</task-notification>"))
        XCTAssertTrue(CheckInSuggestion.runtimes(from: [started, done]).isEmpty)
        let monitor = tool("t3", "Monitor", ["command": "tail -f log", "description": "Watch"], result: "Monitor started (task mon_77ff, expires in 1h)")
        XCTAssertEqual(CheckInSuggestion.runtimes(from: [monitor]).first?.kind, .monitor)
    }

    func testPresets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let presets = CheckInSuggestion.presets(now: now)
        XCTAssertEqual(presets.map(\.id), ["tomorrow", "3d", "week"])
        XCTAssertTrue(presets.allSatisfy { $0.date > now })
    }
}

final class CheckInRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func parse(_ arguments: [String: Any], mode: CheckInMode = .both) throws -> CheckInRequest {
        try CheckInRequest.parse(arguments, now: now, calendar: calendar, defaultMode: mode)
    }

    func testWakeMeInThreeDays() throws {
        let request = try parse(["prompt": "Check the trading test", "in": "3 days", "title": "Trading test"])
        XCTAssertEqual(request.first, now.addingTimeInterval(3 * 86_400))
        XCTAssertNil(request.recurrence)
        XCTAssertEqual(request.mode, .both)
        XCTAssertEqual(request.title, "Trading test")
        XCTAssertEqual(try parse(["prompt": "p", "in": "in 12 hours"]).first, now.addingTimeInterval(12 * 3600))
        XCTAssertEqual(try parse(["prompt": "p", "in": "2 weeks"], mode: .remind).mode, .remind)
    }

    func testADateInsteadOfADelay() throws {
        let request = try parse(["prompt": "p", "at": "2027-03-01"])
        XCTAssertEqual(request.first, calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9)))
        let timed = try parse(["prompt": "p", "at": "2027-03-01 14:30"])
        XCTAssertEqual(timed.first, calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 14, minute: 30)))
    }

    func testRepeatsUntilACountOrADate() throws {
        let daily = try parse(["prompt": "p", "in": "1 day", "every": "day", "count": 7, "mode": "wake"])
        XCTAssertEqual(daily.recurrence?.kind, .every)
        XCTAssertEqual(daily.recurrence?.unit, .days)
        XCTAssertEqual(daily.recurrence?.count, 7)
        XCTAssertEqual(daily.mode, .wake)
        XCTAssertEqual(daily.recurrence?.start, daily.first)

        let hours = try parse(["prompt": "p", "every": "6 hours", "until": "2026-12-31"])
        XCTAssertEqual(hours.recurrence?.every, 6)
        XCTAssertEqual(hours.recurrence?.unit, .hours)
        XCTAssertEqual(hours.first, now.addingTimeInterval(6 * 3600), "with no 'in', the first comes one interval later")
        XCTAssertEqual(hours.recurrence?.until, calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59)))

        let weekly = try parse(["prompt": "p", "every": "weekly monday 09:00"])
        XCTAssertEqual(weekly.recurrence?.kind, .weekly)
        XCTAssertEqual(weekly.recurrence?.weekday, 2)
        XCTAssertEqual(weekly.recurrence?.hour, 9)
        XCTAssertGreaterThan(weekly.first, now)

        let dailyAt = try parse(["prompt": "p", "every": "daily 9:30pm"])
        XCTAssertEqual(dailyAt.recurrence?.kind, .daily)
        XCTAssertEqual(dailyAt.recurrence?.hour, 21)
        XCTAssertEqual(dailyAt.recurrence?.minute, 30)

        let every = try parse(["prompt": "p", "every": "every 2 weeks", "count": "3"])
        XCTAssertEqual(every.recurrence?.every, 2)
        XCTAssertEqual(every.recurrence?.unit, .weeks)
        XCTAssertEqual(every.recurrence?.count, 3)

        XCTAssertEqual(try parse(["prompt": "p", "every": "month"]).recurrence?.unit, .months)
        XCTAssertEqual(try parse(["prompt": "p", "every": "monday 08:00"]).recurrence?.kind, .weekly)
    }

    func testMistakesComeBackWithAReason() {
        func message(_ arguments: [String: Any]) -> String? {
            do { _ = try parse(arguments); return nil } catch { return String(describing: error) }
        }
        XCTAssertTrue(message(["in": "3 days"])?.contains("prompt") == true)
        XCTAssertTrue(message(["prompt": "p"])?.contains("Say when") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "soon"])?.contains("Couldn't read in") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "1 day", "mode": "shout"])?.contains("mode") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "1 day", "every": "fortnightly-ish"])?.contains("every") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "1 day", "count": 5])?.contains("only apply with every") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "1 day", "every": "day", "count": 0])?.contains("between 1 and 1000") == true)
        XCTAssertTrue(message(["prompt": "p", "at": "2020-01-01"])?.contains("passed") == true)
        XCTAssertTrue(message(["prompt": "p", "in": "40 months"])?.contains("two years") == true)
        XCTAssertNil(message(["prompt": "p", "in": "1 day", "count": 1]), "a count of one is a single check-in")
    }

    func testModeWords() {
        XCTAssertEqual(CheckInMode.parse("Wake"), .wake)
        XCTAssertEqual(CheckInMode.parse(" remind "), .remind)
        XCTAssertEqual(CheckInMode.parse("both"), .both)
        XCTAssertNil(CheckInMode.parse("nap"))
        XCTAssertTrue(CheckInMode.wake.wakesAgent && !CheckInMode.wake.leavesReminder)
        XCTAssertTrue(!CheckInMode.remind.wakesAgent && CheckInMode.remind.leavesReminder)
        XCTAssertTrue(CheckInMode.both.wakesAgent && CheckInMode.both.leavesReminder)
    }
}

final class CheckInWaitIntegrationTests: XCTestCase {
    private func rpc(_ method: String, params: [String: Any] = [:]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]), as: UTF8.self)
    }

    private func result(_ line: String?) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(line).utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String? {
        (result["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    private let origin = WaitControl.Origin(pane: "w1:p1", workspace: "w1", conversation: nil, cwd: "/repo")

    func testTheCheckBackToolIsOfferedAndTheOldOnesRemain() throws {
        let tools = try result(WaitMCP.respond(to: rpc("tools/list"), origin: origin, call: { _, _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["wait_for", "list_waits", "cancel_wait", "check_back"])
        let description = tools?.first { $0["name"] as? String == "check_back" }?["description"] as? String
        XCTAssertTrue(description?.contains("polling") == true && description?.contains("days or weeks") == true)
        let waitFor = tools?.first { $0["name"] as? String == "wait_for" }?["description"] as? String
        XCTAssertTrue(waitFor?.contains("check_back") == true)
    }

    func testCheckBackPassesItsPartsAndOldWaitForStillWorks() throws {
        var asked: [String: Any] = [:]
        var method: WaitControl.Method?
        let reply = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "check_back", "arguments": [
                "prompt": "Check the paper-trading run", "in": "3 days", "every": "day", "count": 5, "mode": "wake"]]),
            origin: origin,
            call: { called, params in
                method = called
                asked = params
                return ["status": "Next Oct 21, 9:00 AM (in 3d)", "repeats": "Every day, 5 times", "mode": "wake"]
            }))
        XCTAssertEqual(method, .checkin)
        XCTAssertEqual(asked["prompt"] as? String, "Check the paper-trading run")
        XCTAssertEqual(asked["every"] as? String, "day")
        XCTAssertEqual(asked["count"] as? Int, 5)
        XCTAssertEqual(asked["from_pane"] as? String, "w1:p1")
        XCTAssertTrue(text(reply)?.contains("resumes the session and sends you the prompt") == true)

        // A mistake comes back to the agent without bothering the app.
        var called = false
        let bad = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "check_back", "arguments": ["prompt": "p"]]), origin: origin,
            call: { _, _ in called = true; return [:] }))
        XCTAssertEqual(bad["isError"] as? Bool, true)
        XCTAssertFalse(called)

        // The old call is untouched.
        method = nil
        _ = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "wait_for", "arguments": ["until": "acme/api#3", "then": "Delete the flag"]]),
            origin: origin, call: { called, _ in method = called; return ["condition": "x", "checked_by_octet": true] }))
        XCTAssertEqual(method, .add)
    }

    func testListingShowsCheckIns() throws {
        let rule = CheckInRecurrence.every(1, .days, startingAt: Date(timeIntervalSinceNow: 3600))
        var wait = Wait.makeCheckIn(title: "Trading test", prompt: "Look at it", mode: .wake, first: rule.start, recurrence: rule,
                                    origin: Wait.Origin(cwd: "/repo"), createdBy: "Claude")
        wait.checkIn?.append(CheckInLogEntry(at: Date(), due: Date(), sessionAlive: false, outcome: .resumedSession))
        let item = WaitControl.describe(wait)
        XCTAssertEqual(item["kind"] as? String, "check_in")
        XCTAssertEqual(item["repeats"] as? String, "Every day")
        XCTAssertEqual(item["mode"] as? String, "wake")
        let list = WaitMCP.formatList(["waits": [item]])
        XCTAssertTrue(list.contains("check-in: Trading test"))
        XCTAssertTrue(list.contains("prompt: Look at it"))
        XCTAssertTrue(list.contains("resumed it"))
    }

    func testACheckInIsAWaitThatNeverGetsChecked() throws {
        let rule = CheckInRecurrence.every(1, .days, startingAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down)))
        let wait = Wait.makeCheckIn(title: "T", prompt: "p", mode: .remind, first: rule.start, recurrence: rule,
                                    origin: Wait.Origin(cwd: "/repo"))
        XCTAssertTrue(wait.isCheckIn)
        XCTAssertFalse(wait.isDue(), "the wait checker leaves check-ins to the check-in layer")
        XCTAssertFalse(wait.needsAnswer())
        XCTAssertFalse(wait.isSnooze)
        XCTAssertEqual(wait.statusLine(), "Due now")
        // Written to waits.json and read back, and old files without the field still load.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Wait.self, from: encoder.encode(wait))
        XCTAssertEqual(back.checkIn, wait.checkIn)
        var plain = Wait(title: "PR", condition: .manual("x"), next: "n", origin: Wait.Origin(cwd: "/r"))
        plain.checkIn = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any])
        json["checkIn"] = nil
        let old = try decoder.decode(Wait.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.checkIn)
    }

    func testOctetLinks() {
        XCTAssertEqual(OctetURL(URL(string: "octet://checkin?id=3F2A9C10-7B6D-4E2A-9B1D-0A5C7D8E9F10")!),
                       .checkin(id: "3F2A9C10-7B6D-4E2A-9B1D-0A5C7D8E9F10"))
        XCTAssertEqual(OctetURL.checkin(id: "abc-123").url.absoluteString, "octet://checkin?id=abc-123")
        XCTAssertEqual(OctetURL(OctetURL.checkin(id: "abc-123").url), .checkin(id: "abc-123"))
        XCTAssertNil(OctetURL(URL(string: "octet://checkin")!))
        XCTAssertNil(OctetURL(URL(string: "octet://checkin?id=")!))
        XCTAssertNil(OctetURL(URL(string: "octet://checkin?id=../../etc")!))
        XCTAssertNil(OctetURL(URL(string: "octet://checkin?id=a%20b")!))
        XCTAssertNil(OctetURL(URL(string: "octet://checkin?id=" + String(repeating: "a", count: 65))!))
    }

    func testNotificationsForUpcomingCheckInsOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let daily = CheckInRecurrence.every(1, .days, startingAt: now.addingTimeInterval(3600))
        let active = Wait.makeCheckIn(title: "A", prompt: "check a", mode: .wake, first: daily.start, recurrence: daily,
                                      origin: Wait.Origin(cwd: "/r"), now: now)
        var paused = Wait.makeCheckIn(title: "P", prompt: "p", mode: .wake, first: daily.start, recurrence: daily,
                                      origin: Wait.Origin(cwd: "/r"), now: now)
        paused.checkIn?.paused = true
        var done = Wait.makeCheckIn(title: "D", prompt: "d", mode: .remind, first: now.addingTimeInterval(60), recurrence: nil,
                                    origin: Wait.Origin(cwd: "/r"), now: now)
        done.checkIn?.finishedAt = now
        let ordinary = Wait(title: "PR", condition: .date(now.addingTimeInterval(60)), next: "go", origin: Wait.Origin(cwd: "/r"), now: now)
        let plan = CheckInNotificationPlan.plan(for: [active, paused, done, ordinary], now: now)
        // Two occurrences ahead of the one active check-in; nothing for the rest.
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan.allSatisfy { $0.waitId == active.id && $0.identifier.hasPrefix("octet.checkin." + active.id) })
        XCTAssertEqual(plan.map(\.date), [daily.start, daily.start.addingTimeInterval(86_400)])
        XCTAssertTrue(plan.first?.body.contains("Open Octet to wake the agent") == true)
        XCTAssertEqual(plan.first?.title, "Check-in: A")
        // A one-off in the past, or a count that has run out, schedules nothing.
        XCTAssertTrue(CheckInNotificationPlan.plan(for: [active], now: now.addingTimeInterval(-10)).count == 2)
        var spent = active
        spent.checkIn?.recurrence = .every(1, .days, startingAt: daily.start, count: 1)
        XCTAssertEqual(CheckInNotificationPlan.plan(for: [spent], now: now).count, 1)
    }
}
