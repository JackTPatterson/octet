import Foundation

/// Project jobs share the Check-ins timer, global pause and catch-up lifecycle.
struct ProjectJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var root: String
    var name: String
    var prompt: String
    var provider: String
    var cron: String
    var timeZone: String
    var freshWorktree = true
    var precheck = ""
    var precheckTimeout = 60
    var enabled = true
    var nextRun: Date

    func next(after date: Date) throws -> Date {
        try CronSchedule(cron, timeZone: timeZone).next(after: date)
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["claude", "codex"].contains(provider), (1...3600).contains(precheckTimeout), root.hasPrefix("/") else {
            throw JobError("Name, prompt, project, installed provider and a 1–3600 second timeout are required.")
        }
        _ = try CronSchedule(cron, timeZone: timeZone)
    }
}

struct ProjectJobRun: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case preparing, setup, running, completed, skipped, failed, interrupted }
    var id = UUID()
    let jobId: UUID
    var started = Date()
    var status: Status = .preparing
    var detail = ""
    var checkout: String?
    var workspaceId: String?
    var paneId: String?
    var observedWorking = false
    var active: Bool { [.preparing, .setup, .running].contains(status) }
}

struct JobError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Standard five-field cron, including lists, ranges and steps. Day-of-month
/// and day-of-week use cron's OR rule when both are restricted. Absolute minute
/// stepping respects the selected timezone's skipped/repeated DST hours.
struct CronSchedule {
    let fields: [Set<Int>]
    let wildDays: (Bool, Bool)
    let zone: TimeZone
    init(_ expression: String, timeZone: String) throws {
        guard let zone = TimeZone(identifier: timeZone) else { throw JobError("Unknown timezone.") }
        self.zone = zone
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { throw JobError("Use five cron fields: minute hour day month weekday.") }
        let bounds = [0...59, 0...23, 1...31, 1...12, 0...7]
        fields = try zip(parts, bounds).map { try Self.parse($0, bounds: $1) }
        wildDays = (parts[2].hasPrefix("*"), parts[4].hasPrefix("*"))
    }
    static func parse(_ text: String, bounds: ClosedRange<Int>) throws -> Set<Int> {
        var values = Set<Int>()
        for term in text.split(separator: ",", omittingEmptySubsequences: false) {
            let stepParts = term.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(stepParts.count), let head = stepParts.first else { throw JobError("Invalid cron field.") }
            let step: Int
            if stepParts.count == 2 {
                guard let value = Int(stepParts[1]), value > 0, value <= bounds.count else { throw JobError("Invalid cron step.") }
                step = value
            } else { step = 1 }
            let low: Int, high: Int
            if head == "*" { low = bounds.lowerBound; high = bounds.upperBound }
            else {
                let range = head.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(range.count), let first = Int(range[0]) else { throw JobError("Invalid cron number.") }
                low = first
                if range.count == 2 {
                    guard let last = Int(range[1]) else { throw JobError("Invalid cron range.") }
                    high = last
                } else { high = stepParts.count == 2 ? bounds.upperBound : first }
            }
            guard bounds.contains(low), bounds.contains(high), low <= high else { throw JobError("Cron value outside its range.") }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values
    }
    func matches(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        let dom = fields[2].contains(c.day!), weekday = c.weekday! - 1
        let dow = fields[4].contains(weekday) || (weekday == 0 && fields[4].contains(7))
        let day = wildDays.0 || wildDays.1 ? dom && dow : dom || dow
        return fields[0].contains(c.minute!) && fields[1].contains(c.hour!) && fields[3].contains(c.month!) && day
    }
    func next(after date: Date) throws -> Date {
        var candidate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60 + 60)
        // Bound bad/impossible schedules; leap-day schedules can span four years.
        for _ in 0..<(60 * 24 * 366 * 4) {
            if matches(candidate) { return candidate }
            candidate.addTimeInterval(60)
        }
        throw JobError("Schedule has no occurrence within four years.")
    }
}
