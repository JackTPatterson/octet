import Foundation

/// How long a workspace is snoozed for, after T3 Code's snooze menu. A
/// snoozed workspace waits in Idle's Snoozed shelf and comes back to the
/// main list by itself at its wake time.
enum SnoozeChoice: String, CaseIterable, Identifiable {
    case hour
    case evening
    case tomorrowMorning
    case nextWeek
    /// No wake time: moved to Idle until it's used, as Move to Idle does.
    case untilUsed

    var id: String { rawValue }

    /// Morning and evening as people mean them, not midnight.
    static let morningHour = 9
    static let eveningHour = 18

    var title: String {
        switch self {
        case .hour: "1 Hour"
        case .evening: "This Evening"
        case .tomorrowMorning: "Tomorrow Morning"
        case .nextWeek: "Next Week"
        case .untilUsed: "Until I Use It"
        }
    }

    /// When it wakes, or nil for `untilUsed` and for "this evening" once
    /// the evening is under an hour off (it would hardly be away).
    func wakeTime(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .hour:
            return now.addingTimeInterval(3600)
        case .evening:
            guard let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: now),
                  evening.timeIntervalSince(now) >= 3600 else { return nil }
            return evening
        case .tomorrowMorning:
            // In the small hours "tomorrow morning" is the coming one.
            let hour = calendar.component(.hour, from: now)
            let day = hour < 5 ? now : calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day)
        case .nextWeek:
            // The next Monday morning after today, so on a Monday it is a
            // week away rather than a few hours.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
            return calendar.nextDate(after: tomorrow.addingTimeInterval(-1),
                                     matching: DateComponents(hour: Self.morningHour, minute: 0, second: 0, weekday: 2),
                                     matchingPolicy: .nextTime)
        case .untilUsed:
            return nil
        }
    }

    /// The choices the menu shows now: those with a wake time, then
    /// "until I use it".
    static func offered(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeChoice] {
        allCases.filter { $0 == .untilUsed || $0.wakeTime(now: now, calendar: calendar) != nil }
    }
}

/// Idle's two shelves, after T3 Code's inbox: Snoozed (set aside with a wake
/// time, or until a wait is met) and Idle (gone quiet by itself, or moved
/// there until used; T3's Settled). The rules live here, apart from the
/// views, so they can be tested.
enum IdleShelves {
    /// Splits idle workspaces into the two shelves. Snoozed come soonest
    /// wake first, then those held by a wait in the order given; Idle keeps
    /// the order given (most recently used first).
    static func partition<Item: Identifiable>(
        _ idle: [Item],
        wakeTimes: [String: Date],
        heldByWait: Set<String> = []
    ) -> (snoozed: [Item], idle: [Item]) where Item.ID == String {
        var timed: [(Item, Date)] = []
        var held: [Item] = []
        var rest: [Item] = []
        for item in idle {
            if let wake = wakeTimes[item.id] {
                timed.append((item, wake))
            } else if heldByWait.contains(item.id) {
                held.append(item)
            } else {
                rest.append(item)
            }
        }
        // Stable for equal times: the order given breaks ties.
        let sorted = timed.enumerated().sorted { a, b in
            a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 < b.element.1
        }.map(\.element.0)
        return (sorted + held, rest)
    }

    /// Workspaces whose wake time has come.
    static func due(_ wakeTimes: [String: Date], now: Date = Date()) -> Set<String> {
        Set(wakeTimes.filter { $0.value <= now }.keys)
    }

    /// The soonest wake time still ahead, to set one timer for.
    static func nextWake(_ wakeTimes: [String: Date], now: Date = Date()) -> Date? {
        wakeTimes.values.filter { $0 > now }.min()
    }

    /// Wake times only for workspaces still moved to Idle by hand: one that
    /// was used, pinned, closed or asked a question has left Idle, and a
    /// stale wake time would bring it "back" later for no reason.
    static func reconcile(_ wakeTimes: [String: Date], parked: Set<String>) -> [String: Date] {
        wakeTimes.filter { parked.contains($0.key) }
    }

    /// Compact time until a wake, for a row: `in 45m`, `in 3h`, `in 2d`.
    static func wakeLabel(_ wake: Date, now: Date = Date()) -> String {
        let seconds = wake.timeIntervalSince(now)
        guard seconds >= 60 else { return "now" }
        // Rounded up: a snooze set for an hour reads "in 1h" a moment
        // later, not "in 59m".
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "in \(hours)h" }
        return "in \(max(1, Int((seconds / 86_400).rounded())))d"
    }
}
