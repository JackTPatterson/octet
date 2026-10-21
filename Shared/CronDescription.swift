import Foundation

/// A cron schedule in words, for the jobs list and editor: "Every day at
/// 9:00", "Weekdays at 9:00", "Every 15 minutes". Covers the shapes people
/// actually write; anything rarer returns nil and the caller shows the raw
/// expression, which is always right if not friendly.
enum CronDescription {
    static func describe(_ expression: String) -> String? {
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { return nil }
        let (minute, hour, dayOfMonth, month, weekday) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        guard month == "*" else { return nil }

        // Sub-hourly and hourly schedules say nothing about days.
        if hour == "*", dayOfMonth == "*", weekday == "*" {
            if minute == "*" { return "Every minute" }
            if minute.hasPrefix("*/"), let step = Int(minute.dropFirst(2)), (1...59).contains(step) {
                return step == 1 ? "Every minute" : "Every \(step) minutes"
            }
            if let at = Int(minute), (0...59).contains(at) {
                return at == 0 ? "Every hour" : "Every hour at :\(twoDigits(at))"
            }
            return nil
        }

        guard let at = Int(minute), (0...59).contains(at), let hours = numbers(hour, in: 0...23) else { return nil }
        let times = list(hours.map { "\($0):\(twoDigits(at))" })

        switch (dayOfMonth, weekday) {
        case ("*", "*"):
            return "Every day at \(times)"
        case ("*", _):
            guard let days = numbers(weekday, in: 0...7) else { return nil }
            let set = Set(days.map { $0 % 7 })
            if set == [1, 2, 3, 4, 5] { return "Weekdays at \(times)" }
            if set == [0, 6] { return "Weekends at \(times)" }
            if set.count == 7 { return "Every day at \(times)" }
            // Monday first, as a week reads.
            let ordered = set.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
            return "\(list(ordered.map { dayNames[$0] + "s" })) at \(times)"
        case (_, "*"):
            guard let days = numbers(dayOfMonth, in: 1...31), days.count == 1 else { return nil }
            return "On the \(ordinal(days[0])) of every month at \(times)"
        default:
            return nil
        }
    }

    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// A field of plain numbers, lists and ranges (no steps or stars), in order.
    private static func numbers(_ field: String, in bounds: ClosedRange<Int>) -> [Int]? {
        var values: [Int] = []
        for term in field.split(separator: ",") {
            let range = term.split(separator: "-")
            guard (1...2).contains(range.count), let low = Int(range[0]),
                  let high = range.count == 2 ? Int(range[1]) : low,
                  bounds.contains(low), bounds.contains(high), low <= high else { return nil }
            values += Array(low...high)
        }
        let unique = Array(Set(values)).sorted()
        return unique.isEmpty ? nil : unique
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func ordinal(_ day: Int) -> String {
        let suffix: String
        switch (day % 10, day % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
