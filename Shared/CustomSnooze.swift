import Foundation

/// The date logic behind Snooze › Pick a Time…, after T3 Code's custom
/// snooze: quick presets, a day and a time put together, and whether the
/// result is far enough off to be worth snoozing for.
enum CustomSnooze {
    struct Preset: Identifiable, Equatable {
        let id: String
        let title: String
        let date: Date
    }

    /// The soonest a picked time may be: a snooze that's over before the
    /// menu closes isn't one.
    static let minimumLead: TimeInterval = 60

    /// Times people reach for, soonest first, each once.
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [Preset] {
        var presets: [Preset] = [
            Preset(id: "30m", title: "In 30 Minutes", date: now.addingTimeInterval(30 * 60)),
            Preset(id: "3h", title: "In 3 Hours", date: now.addingTimeInterval(3 * 3600)),
        ]
        if let morning = SnoozeChoice.tomorrowMorning.wakeTime(now: now, calendar: calendar) {
            presets.append(Preset(id: "tomorrow", title: "Tomorrow Morning", date: morning))
            if let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: morning) {
                presets.append(Preset(id: "tomorrow-afternoon", title: "Tomorrow Afternoon", date: afternoon))
            }
        }
        // Saturday morning; at the weekend already, the next one.
        if let saturday = calendar.nextDate(after: now, matching: DateComponents(hour: SnoozeChoice.morningHour, minute: 0, second: 0, weekday: 7),
                                            matchingPolicy: .nextTime),
           !calendar.isDateInWeekend(now) {
            presets.append(Preset(id: "weekend", title: "This Weekend", date: saturday))
        }
        if let monday = SnoozeChoice.nextWeek.wakeTime(now: now, calendar: calendar) {
            presets.append(Preset(id: "next-week", title: "Next Week", date: monday))
        }
        var seen = Set<Date>()
        return presets
            .filter { $0.date.timeIntervalSince(now) >= minimumLead && seen.insert($0.date).inserted }
            .sorted { $0.date < $1.date }
    }

    /// A day and a 24-hour time as one date, in `calendar`'s time zone.
    static func date(day: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }

    /// Why `date` can't be snoozed until, or nil when it can.
    static func problem(with date: Date?, now: Date = Date()) -> String? {
        guard let date else { return "Choose a valid date and time." }
        return date.timeIntervalSince(now) < minimumLead ? "Choose a time in the future." : nil
    }

    /// Where the picker starts: an hour from now, rounded up to five minutes.
    static func initialPick(now: Date = Date(), calendar: Calendar = .current) -> (day: Date, hour: Int, minute: Int) {
        let later = now.addingTimeInterval(3600)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: later)
        var minute = parts.minute ?? 0
        if minute % 5 != 0 || (parts.second ?? 0) > 0 { minute = (minute / 5 + 1) * 5 }
        parts.minute = 0
        parts.second = 0
        let rounded = (calendar.date(from: parts) ?? later).addingTimeInterval(TimeInterval(minute * 60))
        return (calendar.startOfDay(for: rounded), calendar.component(.hour, from: rounded),
                calendar.component(.minute, from: rounded))
    }

    /// 12-hour clock to 24: 12 AM is 0, 12 PM is 12.
    static func hour24(_ hour12: Int, pm: Bool) -> Int {
        (hour12 % 12) + (pm ? 12 : 0)
    }

    static func hour12(_ hour24: Int) -> (hour: Int, pm: Bool) {
        let hour = hour24 % 12
        return (hour == 0 ? 12 : hour, hour24 >= 12)
    }

    /// A month's calendar page: nil for the blanks before the 1st (from the
    /// calendar's first weekday) and after the last day, in whole weeks.
    static func monthGrid(containing day: Date, calendar: Calendar = .current) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: day),
              let count = calendar.range(of: .day, in: .month, for: day)?.count else { return [] }
        let first = interval.start
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// The weekday initials in the calendar's order, Sunday or Monday first.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}
