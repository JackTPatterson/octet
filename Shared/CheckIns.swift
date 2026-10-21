import Foundation

// Long-haul check-ins: a wait that comes back on a schedule. Work that
// takes days or weeks to give a result (a paper-trading run, a backtest, a
// soak test) is checked now and then; whether the agent's session is still
// alive, was closed, or the Mac slept in between, Octet brings the work
// back at the right time and carries on. A check-in is a `Wait` with
// `checkIn` set, so it lives in the same list, file and socket as the rest.
// Everything here is pure (no UI, no I/O) so the date maths, quiet hours,
// stall thresholds and heuristics can be tested.

/// What an occurrence of a check-in does.
enum CheckInMode: String, Codable, CaseIterable, Identifiable {
    /// Notify, and leave it in the list to run when the person is ready.
    case remind
    /// Resume the agent's session and send the saved prompt.
    case wake
    /// Both: wake the agent, and leave a reminder to look at what it did.
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remind: "Remind only"
        case .wake: "Wake the agent"
        case .both: "Remind and wake"
        }
    }

    var detail: String {
        switch self {
        case .remind: "Notifies you; nothing is sent until you run it."
        case .wake: "Resumes the session and sends the prompt."
        case .both: "Sends the prompt, and keeps a reminder until you look."
        }
    }

    var icon: String {
        switch self {
        case .remind: "bell"
        case .wake: "play.circle"
        case .both: "bell.badge"
        }
    }

    var wakesAgent: Bool { self != .remind }
    /// Stays in the list as due until the person acts on it.
    var leavesReminder: Bool { self != .wake }

    /// A word an agent or a person writes: "remind", "wake", "both".
    static func parse(_ raw: String?) -> CheckInMode? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "remind", "reminder", "remind_only", "remind only", "notify": .remind
        case "wake", "resume", "wake_agent", "wake the agent": .wake
        case "both", "remind_and_wake", "remind and wake": .both
        default: nil
        }
    }
}

/// When a check-in comes round again, and when it stops.
struct CheckInRecurrence: Codable, Equatable {
    enum Kind: String, Codable { case every, daily, weekly }
    enum Unit: String, Codable, CaseIterable {
        case hours, days, weeks, months

        var component: Calendar.Component {
            switch self {
            case .hours: .hour
            case .days: .day
            case .weeks: .weekOfYear
            case .months: .month
            }
        }

        var title: String { rawValue }
    }

    var kind: Kind
    /// For `.every`: every N hours, days, weeks or months.
    var every = 1
    var unit: Unit = .days
    /// For `.daily` and `.weekly`: the time of day, and the weekday
    /// (`Calendar`'s numbering, 1 = Sunday) for weekly.
    var hour = 9
    var minute = 0
    var weekday = 2
    /// The first occurrence; `.every` counts from it, so months keep their
    /// day (Jan 31, Feb 28, Mar 31) instead of drifting.
    var start: Date
    /// Nothing after this.
    var until: Date?
    /// Stops after this many occurrences.
    var count: Int?

    /// The soonest apart two occurrences of an hourly one may be.
    static let shortestInterval: TimeInterval = 3600

    static func every(_ every: Int, _ unit: Unit, startingAt start: Date, until: Date? = nil, count: Int? = nil) -> CheckInRecurrence {
        CheckInRecurrence(kind: .every, every: max(1, every), unit: unit, start: start, until: until, count: count)
    }

    static func daily(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current,
                      until: Date? = nil, count: Int? = nil) -> CheckInRecurrence {
        var rule = CheckInRecurrence(kind: .daily, hour: hour, minute: minute, start: .distantPast, until: until, count: count)
        rule.start = rule.next(after: now, calendar: calendar) ?? now
        return rule
    }

    static func weekly(weekday: Int, hour: Int, minute: Int, after now: Date, calendar: Calendar = .current,
                       until: Date? = nil, count: Int? = nil) -> CheckInRecurrence {
        var rule = CheckInRecurrence(kind: .weekly, hour: hour, minute: minute, weekday: weekday, start: .distantPast,
                                     until: until, count: count)
        rule.start = rule.next(after: now, calendar: calendar) ?? now
        return rule
    }

    /// The first occurrence strictly after `date`, or nil past the end date.
    /// (The occurrence count is the check-in's to enforce: it knows how many
    /// have run.)
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let found: Date?
        if date < start {
            found = start
        } else {
            switch kind {
            case .every: found = nextInterval(after: date, calendar: calendar)
            case .daily:
                found = calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                          matchingPolicy: .nextTime)
            case .weekly:
                found = calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                                          matchingPolicy: .nextTime)
            }
        }
        guard let found else { return nil }
        if let until, found > until { return nil }
        return found
    }

    private func occurrence(_ index: Int, calendar: Calendar) -> Date? {
        switch unit {
        case .hours: return start.addingTimeInterval(Double(index * every) * 3600)
        default: return calendar.date(byAdding: unit.component, value: index * every, to: start)
        }
    }

    private func nextInterval(after date: Date, calendar: Calendar) -> Date? {
        let step: TimeInterval
        switch unit {
        case .hours: step = Double(every) * 3600
        case .days: step = Double(every) * 86_400
        case .weeks: step = Double(every) * 7 * 86_400
        case .months: step = Double(every) * 30.4 * 86_400
        }
        var index = max(0, Int(floor(date.timeIntervalSince(start) / step)) - 1)
        // The estimate can be a little off across DST and short months:
        // settle on the first occurrence after `date`.
        var guardLoop = 0
        while let candidate = occurrence(index, calendar: calendar), candidate <= date, guardLoop < 1000 {
            index += 1
            guardLoop += 1
        }
        return occurrence(index, calendar: calendar)
    }

    /// How many occurrences fall after `due` up to and including `now`:
    /// what a Mac that slept, or an Octet that was closed, missed.
    func missed(after due: Date, upTo now: Date, calendar: Calendar = .current) -> Int {
        var total = 0
        var cursor = due
        while total < 10_000, let following = next(after: cursor, calendar: calendar), following <= now {
            total += 1
            cursor = following
        }
        return total
    }

    /// "Every 2 days", "Every day at 9:00 AM", "Every Monday at 9:00 AM".
    var summary: String {
        var text: String
        switch kind {
        case .every:
            text = every == 1 ? "Every " + String(unit.title.dropLast()) : "Every \(every) \(unit.title)"
        case .daily:
            text = "Every day at " + Self.clock(hour: hour, minute: minute)
        case .weekly:
            text = "Every " + Self.weekdayName(weekday) + " at " + Self.clock(hour: hour, minute: minute)
        }
        if let count { text += ", \(count) time\(count == 1 ? "" : "s")" }
        if let until { text += ", until " + Self.shortDate(until) }
        return text
    }

    static func clock(hour: Int, minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour >= 12 ? "PM" : "AM")
    }

    static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[((weekday - 1) % 7 + 7) % 7]
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// One line of a check-in's record: when an occurrence came round, whether
/// the session was alive, and what Octet did about it.
struct CheckInLogEntry: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        /// Told the person; sent nothing.
        case reminded
        /// Sent the prompt to the conversation still open in Octet.
        case sentToConversation
        /// Sent it to the agent still running in its terminal.
        case sentToTerminal
        /// The session was gone: resumed it with the agent's own resume command.
        case resumedSession
        /// It couldn't be resumed: started a new conversation from the summary.
        case newConversation
        /// Waiting to send: quiet hours, a busy agent, or too many resuming.
        case queued
        case skipped
        case failed
        /// A made-up run, for the debug sample.
        case simulated
    }

    /// The prompt reached the agent, one way or another.
    var sent: Bool {
        switch outcome {
        case .sentToConversation, .sentToTerminal, .resumedSession, .newConversation: true
        default: false
        }
    }

    var id = UUID().uuidString
    /// When Octet acted.
    var at: Date
    /// When it was due.
    var due: Date
    /// Whether the agent's session was alive then; nil when not known or not relevant.
    var sessionAlive: Bool?
    var outcome: Outcome
    /// Occurrences that came and went while Octet or the Mac was off; this
    /// one stands for them all.
    var missed = 0
    var note: String?
    /// Run by hand rather than by the schedule.
    var manual = false

    /// "Reminded", "Resumed the session", …
    var outcomeText: String {
        switch outcome {
        case .reminded: "Reminded you"
        case .sentToConversation: "Sent to the open conversation"
        case .sentToTerminal: "Sent to the agent in its terminal"
        case .resumedSession: "Session was gone; resumed it"
        case .newConversation: "Couldn't resume; started a new conversation"
        case .queued: "Waiting to send"
        case .skipped: "Skipped"
        case .failed: "Couldn't wake the agent"
        case .simulated: "Sample run"
        }
    }

    /// One line for the row: "Oct 18, 9:00 AM · closed · resumed the session · 2 missed".
    func line(now: Date = Date()) -> String {
        var parts = [CheckInInfo.dayTime(at)]
        if let sessionAlive { parts.append(sessionAlive ? "session alive" : "session was gone") }
        parts.append(outcomeText + (manual ? " (by hand)" : ""))
        if missed > 0 { parts.append("\(missed) missed, collapsed into this one") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// What makes a wait a check-in.
struct CheckInInfo: Codable, Equatable {
    var mode: CheckInMode
    /// Nil for a one-off ("wake me in 3 days").
    var recurrence: CheckInRecurrence?
    var paused = false
    /// Occurrences that have come round.
    var fired = 0
    /// An occurrence is waiting for the person (remind modes), since then.
    var dueSince: Date?
    /// Missed occurrences the waiting one stands for.
    var dueMissed = 0
    /// The prompt still has to be sent: quiet hours, a busy agent, a queue.
    var wakeQueued = false
    var queuedReason: String?
    /// The last occurrence has come round.
    var finishedAt: Date?
    var log: [CheckInLogEntry] = []

    static let logLimit = 40

    var isFinished: Bool { finishedAt != nil }
    var hasReminder: Bool { dueSince != nil }

    mutating func append(_ entry: CheckInLogEntry) {
        log.append(entry)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// Updates an entry in place (the outcome of a wake arrives after the occurrence).
    mutating func update(_ id: String, _ change: (inout CheckInLogEntry) -> Void) {
        guard let index = log.firstIndex(where: { $0.id == id }) else { return }
        change(&log[index])
    }

    /// What one occurrence does to the record. Missed occurrences collapse
    /// into this one (it fires once, however many came round), the next is
    /// the first one still ahead, and the count and end date finish it.
    /// Returns the next due time, or nil when this was the last.
    mutating func occur(due: Date, now: Date, calendar: Calendar = .current) -> (next: Date?, missed: Int) {
        fired += 1
        var missed = 0
        var next: Date?
        if let recurrence {
            missed = recurrence.missed(after: due, upTo: now, calendar: calendar)
            next = recurrence.next(after: max(now, due), calendar: calendar)
            if let count = recurrence.count, fired + missed >= count { next = nil }
            // Missed occurrences count towards the stop.
            fired += missed
        }
        if next == nil { finishedAt = now }
        return (next, missed)
    }

    /// Takes an edited schedule. A new one (another rule, or another next
    /// time), or any for a finished check-in, starts counting again: kept,
    /// the old count would finish it after one run, and an old reminder
    /// would stand for an occurrence that no longer exists.
    mutating func reschedule(_ new: CheckInRecurrence?, nextDue: Date, previousDue: Date) {
        // `start` is where counting begins, which the sheet sets to the next
        // time whatever was changed, so it's compared as the next due time.
        func rule(_ recurrence: CheckInRecurrence?) -> CheckInRecurrence? {
            recurrence.map { var rule = $0; rule.start = .distantPast; return rule }
        }
        let changed = isFinished || rule(new) != rule(recurrence) || nextDue != previousDue
        recurrence = new
        finishedAt = nil
        guard changed else { return }
        fired = 0
        dueSince = nil
        dueMissed = 0
    }

    /// "Next in 2d", "Due now", "Paused", "Done".
    func statusLine(nextDue: Date, now: Date = Date()) -> String {
        if isFinished { return "Done" }
        if paused { return "Paused" }
        if hasReminder { return wakeQueued ? "Due · \(queuedReason ?? "waiting to send")" : "Due" }
        if nextDue <= now { return "Due now" }
        return "Next " + CheckInInfo.dayTime(nextDue) + " (in " + WaitSchedule.span(nextDue.timeIntervalSince(now)) + ")"
    }

    static func dayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

extension Wait {
    var isCheckIn: Bool { checkIn != nil }

    /// A check-in: a wait that comes back at `first` (and again as `recurrence`
    /// says), with `prompt` as what's said then.
    static func makeCheckIn(title: String, prompt: String, mode: CheckInMode, first: Date, recurrence: CheckInRecurrence?,
                            origin: Origin, createdBy: String = "you", brief: String? = nil, now: Date = Date()) -> Wait {
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var wait = Wait(title: title, condition: .date(first), next: cleaned, origin: origin, createdBy: createdBy,
                        brief: brief, now: now)
        wait.checkIn = CheckInInfo(mode: mode, recurrence: recurrence)
        wait.nextCheckAt = first
        return wait
    }
}

/// Hours in which nothing is sent to an agent; wakes wait for the end.
struct QuietHours: Equatable {
    var enabled: Bool
    /// Minutes after midnight.
    var startMinute: Int
    var endMinute: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// When the quiet period that holds `date` ends; nil when `date` isn't in one.
    func end(after date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        return calendar.nextDate(after: date, matching: DateComponents(hour: endMinute / 60, minute: endMinute % 60, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// "10:00 PM – 7:00 AM".
    var summary: String {
        CheckInRecurrence.clock(hour: startMinute / 60, minute: startMinute % 60) + " – "
            + CheckInRecurrence.clock(hour: endMinute / 60, minute: endMinute % 60)
    }
}

/// Reopening Octet after two weeks mustn't launch a dozen agents at once.
enum WakeThrottle {
    /// Sessions brought back from the dead in one window.
    static let limit = 3
    static let window: TimeInterval = 300

    /// How many more may be resumed now, given when the last ones were.
    static func slots(recent: [Date], now: Date, limit: Int = WakeThrottle.limit, window: TimeInterval = WakeThrottle.window) -> Int {
        max(0, limit - recent.filter { now.timeIntervalSince($0) < window }.count)
    }
}

/// Notices a session that says it's working but has gone quiet.
struct StallTracker {
    struct Subject: Equatable {
        var id: String
        var label: String
        var isWorking: Bool
        /// Changes whenever the session does anything: a new message, a new
        /// state, different output on screen.
        var token: String
    }

    struct Stall: Equatable, Identifiable {
        var id: String
        var label: String
        /// How long it has been quiet.
        var quietFor: TimeInterval
    }

    private struct Entry {
        var token: String
        var changedAt: Date
        var reported = false
        var snoozedUntil: Date?
        var ignored = false
    }

    private var entries: [String: Entry] = [:]

    /// The default time a working session may go quiet.
    static let defaultThreshold: TimeInterval = 6 * 3600

    /// Takes in how the sessions look now and returns those that have newly
    /// been quiet for `threshold` (each once, until it does something again
    /// or a snooze runs out). A threshold of zero or less never reports.
    mutating func observe(_ subjects: [Subject], now: Date, threshold: TimeInterval) -> [Stall] {
        let ids = Set(subjects.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        var stalled: [Stall] = []
        for subject in subjects {
            guard subject.isWorking else {
                entries[subject.id] = nil
                continue
            }
            guard var entry = entries[subject.id], entry.token == subject.token else {
                entries[subject.id] = Entry(token: subject.token, changedAt: now)
                continue
            }
            defer { entries[subject.id] = entry }
            guard threshold > 0, !entry.ignored, now.timeIntervalSince(entry.changedAt) >= threshold else { continue }
            if let snoozed = entry.snoozedUntil {
                guard now >= snoozed else { continue }
                entry.snoozedUntil = nil
            } else if entry.reported {
                continue
            }
            entry.reported = true
            stalled.append(Stall(id: subject.id, label: subject.label, quietFor: now.timeIntervalSince(entry.changedAt)))
        }
        return stalled
    }

    mutating func snooze(_ id: String, until date: Date) {
        entries[id]?.snoozedUntil = date
    }

    /// What the screen says, without what moves while nothing happens: a
    /// spinner glyph, a timer counting up ("4m 47s"), a token count that has
    /// stopped. Only words of three letters or more count, so two screens
    /// with the same fingerprint show the same words.
    static func fingerprint(screen: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var word = ""
        func mix(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        func finish() {
            if word.count >= 3 { mix(word + " ") }
            word = ""
        }
        for scalar in screen.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                finish()
            }
        }
        finish()
        return String(hash, radix: 16)
    }

    /// Stop mentioning this one until it does something and goes quiet again.
    mutating func ignore(_ id: String) {
        entries[id]?.ignored = true
    }

    var tracked: Int { entries.count }
}

/// Notices work that will take days or weeks to give a result, in an
/// agent's reply or in a task it left running, so Octet can offer a
/// check-in. Conservative on purpose: a stated duration of a day or more
/// next to words that say "come back later".
enum CheckInSuggestion {
    struct Found: Equatable {
        /// How long until the first check, as the reply suggests.
        var delay: TimeInterval
        /// Why, in a few words: "runs for 2 weeks".
        var reason: String
        /// A prompt to send when it comes round, ready to edit.
        var prompt: String
    }

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "twelve": 12, "a few": 3, "few": 3, "a couple of": 2, "couple of": 2, "a couple": 2, "several": 5,
    ]

    private static let durationPattern =
        #"\b(?:about |around |roughly |at least |another |the next |next |over the next )?(\d+(?:\.\d+)?|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve|a few|a couple of|a couple|several)\s*[- ]?(day|week|month)s?\b"#

    /// Words that say the work goes on without the agent.
    private static let triggers = [
        "run for", "running for", "runs for", "keep running", "let it run", "let this run", "let them run", "leave it running",
        "check back", "check in", "check on it", "come back to", "revisit", "results in", "results will", "results after",
        "will take", "to finish", "to complete", "to accumulate", "to collect", "bake", "soak", "forward-test", "forward test",
        "paper trad", "monitor for", "observe for", "give it", "wait for", "needs time",
    ]

    static func detect(_ text: String) -> Found? {
        var kept: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.hasPrefix(">") { continue }
            kept.append(line)
        }
        let sentences = kept.joined(separator: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".!;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for sentence in sentences {
            let lower = sentence.lowercased()
            // A question to the person is an offer, not a plan.
            if lower.hasSuffix("?") || lower.hasPrefix("should ") || lower.hasPrefix("do you") || lower.hasPrefix("would you") { continue }
            guard triggers.contains(where: { lower.contains($0) }),
                  let match = WaitCondition.firstMatch(durationPattern, in: lower), match.count > 2 else { continue }
            let amount = Double(match[1]) ?? numberWords[match[1]] ?? 0
            let unit = match[2]
            let days = amount * (unit == "day" ? 1 : unit == "week" ? 7 : 30)
            guard days >= 1, days <= 365 else { continue }
            let phrase = HandoffBrief.clip(sentence, 140)
            return Found(delay: days * 86_400,
                         reason: "\(unit == "day" ? "\(Int(amount)) day" : unit == "week" ? "\(Int(amount)) week" : "\(Int(amount)) month")\(amount == 1 ? "" : "s")",
                         prompt: draftPrompt(about: phrase))
        }
        return nil
    }

    /// Tasks and monitors an agent started that have been running a long
    /// time: more than 12 hours is more than a person sits through.
    static let longRunningAfter: TimeInterval = 12 * 3600

    static func longRunning(_ runtimes: [HandoffRuntime], now: Date = Date()) -> Found? {
        let long = runtimes.filter { runtime in
            guard runtime.kind != .agent, let started = runtime.startedAt else { return false }
            return now.timeIntervalSince(started) >= longRunningAfter
        }.sorted { ($0.startedAt ?? now) < ($1.startedAt ?? now) }
        guard let oldest = long.first, let started = oldest.startedAt else { return nil }
        let title = oldest.title.isEmpty ? (oldest.command ?? "a background task") : oldest.title
        return Found(delay: 86_400, reason: "\(HandoffBrief.clip(title, 40)) has run \(WaitSchedule.span(now.timeIntervalSince(started)))",
                     prompt: draftPrompt(about: "\(title) (started \(CheckInInfo.dayTime(started)))"))
    }

    /// Background tasks and monitors a conversation started and hasn't
    /// seen finish: a task's own id turning up in a later message means it
    /// reported back.
    static func runtimes(from items: [AgentItem]) -> [HandoffRuntime] {
        func text(_ item: AgentItem) -> String {
            switch item.kind {
            case .user(let text), .text(let text), .notice(let text), .thinking(let text): return text
            case .tool(let call): return call.result ?? ""
            }
        }
        var found: [HandoffRuntime] = []
        for (index, item) in items.enumerated() {
            guard item.parent == nil, case .tool(let call) = item.kind, let output = call.result else { continue }
            let input = call.inputObject ?? [:]
            let isMonitor = call.name == "Monitor"
            let isBackground = call.name == "Bash" && (input["run_in_background"] as? Bool) == true
            guard isMonitor || isBackground else { continue }
            if let taskId = WaitCondition.firstMatch(#"(?:\bID:?|\btask)\s+([A-Za-z0-9_-]{4,})"#, in: output)?[1],
               items[(index + 1)...].contains(where: { text($0).contains(taskId) }) { continue }
            found.append(HandoffRuntime(id: item.id, kind: isMonitor ? .monitor : .task,
                                        title: input["description"] as? String ?? "", command: input["command"] as? String,
                                        prompt: nil, startedAt: item.createdAt, expiresAt: nil))
        }
        return found
    }

    static func draftPrompt(about phrase: String) -> String {
        "Check back on the long-running work: \(phrase)\n\nLook at what has happened since last time, compare it with what we expected, and report any drift or anything unexpected. Then say what the next step should be."
    }

    /// Whether the phrase is a decent first check: the presets a banner offers.
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [(id: String, title: String, date: Date)] {
        var result: [(String, String, Date)] = []
        func morning(_ days: Int) -> Date? {
            calendar.date(byAdding: .day, value: days, to: now).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        }
        if let date = morning(1) { result.append(("tomorrow", "Tomorrow", date)) }
        if let date = morning(3) { result.append(("3d", "In 3 days", date)) }
        if let date = morning(7) { result.append(("week", "Next week", date)) }
        return result
    }
}

/// What an agent (or `octet-cli wait checkin`) asks for, read from its
/// arguments: when, how often, until when, what to say, what to do.
struct CheckInRequest: Equatable {
    var title: String
    var prompt: String
    var mode: CheckInMode
    var first: Date
    var recurrence: CheckInRecurrence?

    struct Failure: Error, CustomStringConvertible, Equatable {
        let message: String
        var description: String { message }
    }

    static let help = """
    When: "in" is a delay ("3 days", "12 hours", "2 weeks"), "at" a date or time ("2026-11-03", "2026-11-03 14:30", "tomorrow"). \
    Repeat: "every" is "6 hours", "2 days", "week", "month", "daily 09:00", "weekly monday 09:00" or "monday 09:00"; leave it out for a single check. \
    Stop: "until" is a date (inclusive), "count" a number of check-ins (the first counts); leave both out to go on until cancelled. \
    "prompt" is what is sent to you then: write it as the message you'd want to read. \
    "mode" is "wake" (resume this session and send the prompt), "remind" (only tell the person) or "both".
    """

    static func parse(_ arguments: [String: Any], now: Date = Date(), calendar: Calendar = .current,
                      defaultMode: CheckInMode = .both) throws -> CheckInRequest {
        func string(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let prompt = string("prompt") else {
            throw Failure(message: "Give the prompt to send when it's time (prompt).")
        }
        var mode = defaultMode
        if let raw = string("mode") {
            guard let parsed = CheckInMode.parse(raw) else {
                throw Failure(message: "mode is \"wake\", \"remind\" or \"both\".")
            }
            mode = parsed
        }
        var stop: Date?
        if let raw = string("until") {
            guard let date = parseStop(raw, now: now, calendar: calendar) else {
                throw Failure(message: "Couldn't read until \"\(raw)\". Use a date like 2026-12-01 or \"in 4 weeks\".")
            }
            stop = date
        }
        var count: Int?
        if let number = arguments["count"] as? Int ?? (arguments["count"] as? Double).map(Int.init) ?? string("count").flatMap(Int.init) {
            guard (1...1000).contains(number) else { throw Failure(message: "count is between 1 and 1000.") }
            count = number
        }
        var first: Date?
        if let raw = string("in") {
            guard let date = parseDelay(raw, now: now, calendar: calendar) else {
                throw Failure(message: "Couldn't read in \"\(raw)\". Use something like \"3 days\" or \"12 hours\".")
            }
            first = date
        } else if let raw = string("at") {
            guard let date = WaitSchedule.parseDate(raw, now: now, calendar: calendar) else {
                throw Failure(message: "Couldn't read at \"\(raw)\". Use a date like 2026-11-03 or 2026-11-03 14:30.")
            }
            first = date
        }
        var recurrence: CheckInRecurrence?
        if let raw = string("every") {
            guard let rule = parseEvery(raw, first: first, now: now, calendar: calendar, until: stop, count: count) else {
                throw Failure(message: "Couldn't read every \"\(raw)\". Use \"6 hours\", \"2 days\", \"week\", \"daily 09:00\" or \"weekly monday 09:00\".")
            }
            recurrence = rule
            if first == nil { first = rule.start }
        } else if stop != nil || (count ?? 1) > 1 {
            throw Failure(message: "until and count only apply with every.")
        }
        guard let first else { throw Failure(message: "Say when: in (\"3 days\"), at (a date), or every.") }
        guard first.timeIntervalSince(now) >= 0 else { throw Failure(message: "That time has already passed.") }
        guard first.timeIntervalSince(now) <= 2 * 366 * 86_400 else {
            throw Failure(message: "That's more than two years away; set it closer and let it repeat.")
        }
        if let rule = recurrence {
            if rule.kind == .every, rule.unit == .hours, Double(rule.every) * 3600 < CheckInRecurrence.shortestInterval {
                throw Failure(message: "Check-ins come at most once an hour.")
            }
            if rule.kind == .every, rule.unit == .hours, rule.every > 24 * 366 {
                throw Failure(message: "That interval is too long; use days.")
            }
        }
        return CheckInRequest(title: string("title") ?? "", prompt: prompt, mode: mode, first: first, recurrence: recurrence)
    }

    /// "3 days", "in 3 days", "12h", "90 minutes", "2 weeks".
    static func parseDelay(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let spelled = text.hasPrefix("in ") ? text : "in " + text
        return WaitSchedule.parseDate(spelled, now: now, calendar: calendar)
    }

    /// An end date; a bare day means the end of that day.
    static func parseStop(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           let morning = WaitSchedule.parseDate(text, now: now, calendar: calendar) {
            return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: morning)
        }
        return WaitSchedule.parseDate(text, now: now, calendar: calendar) ?? parseDelay(text, now: now, calendar: calendar)
    }

    /// Reads "6 hours", "week", "daily 09:00", "weekly monday 9am", "monday 09:00".
    static func parseEvery(_ raw: String, first: Date?, now: Date, calendar: Calendar,
                           until: Date?, count: Int?) -> CheckInRecurrence? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("every ") { text.removeFirst(6) }
        text = text.replacingOccurrences(of: ",", with: " ")
        // A time of day: "09:00", "9am", "9:30 pm", optionally after "at".
        var time: (hour: Int, minute: Int)?
        if let match = WaitCondition.firstMatch(#"(?:\bat\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b(?!\s*(?:hour|hr|day|week|month|h\b|d\b|w\b))"#, in: text),
           match[0].contains(":") || !match[3].isEmpty {
            var hour = Int(match[1]) ?? 0
            let minute = Int(match[2]) ?? 0
            if match[3] == "pm", hour < 12 { hour += 12 }
            if match[3] == "am", hour == 12 { hour = 0 }
            guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
            time = (hour, minute)
            text = text.replacingOccurrences(of: match[0], with: " ")
        }
        let words = text.split(separator: " ").map(String.init)
        let fullNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        func dayIndex(_ word: String) -> Int? {
            word.count >= 3 ? fullNames.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 } : nil
        }
        let weekday = words.compactMap(dayIndex).first
        let rest = words.filter { dayIndex($0) == nil }.joined(separator: " ")
        // "daily", "weekly", "monthly", "hourly", "day", "2 days", "3d".
        let unitMatch = WaitCondition.firstMatch(#"^(?:(\d+)\s*)?(hourly|daily|weekly|monthly|hours?|hrs?|h|days?|d|weeks?|wks?|w|months?|mo)$"#, in: rest)
        if let unitMatch {
            let amount = Int(unitMatch[1]) ?? 1
            guard amount >= 1 else { return nil }
            let word = unitMatch[2]
            let unit: CheckInRecurrence.Unit
            switch word {
            case "hourly", "hour", "hours", "hr", "hrs", "h": unit = .hours
            case "daily", "day", "days", "d": unit = .days
            case "weekly", "week", "weeks", "wk", "wks", "w": unit = .weeks
            default: unit = .months
            }
            if amount == 1, unit == .days, let time {
                return .daily(hour: time.hour, minute: time.minute, after: first.map { $0.addingTimeInterval(-1) } ?? now,
                              calendar: calendar, until: until, count: count)
            }
            if amount == 1, unit == .weeks, weekday != nil || time != nil {
                let reference = first.map { $0.addingTimeInterval(-1) } ?? now
                let day = weekday ?? calendar.component(.weekday, from: first ?? now)
                return .weekly(weekday: day, hour: time?.hour ?? 9, minute: time?.minute ?? 0, after: reference,
                               calendar: calendar, until: until, count: count)
            }
            let anchor = first ?? calendar.date(byAdding: unit.component, value: amount, to: now) ?? now
            return .every(amount, unit, startingAt: anchor, until: until, count: count)
        }
        // "monday 09:00": every week on that day.
        if rest.isEmpty, let weekday {
            let reference = first.map { $0.addingTimeInterval(-1) } ?? now
            return .weekly(weekday: weekday, hour: time?.hour ?? 9, minute: time?.minute ?? 0, after: reference,
                           calendar: calendar, until: until, count: count)
        }
        // "09:00" alone: daily.
        if rest.isEmpty, let time {
            return .daily(hour: time.hour, minute: time.minute, after: first.map { $0.addingTimeInterval(-1) } ?? now,
                          calendar: calendar, until: until, count: count)
        }
        return nil
    }
}

/// The macOS notifications to schedule for upcoming check-ins: the next two
/// occurrences of each active one, soonest first, at most `limit` in all.
enum CheckInNotificationPlan {
    struct Item: Equatable {
        var identifier: String
        var date: Date
        var waitId: String
        var title: String
        var body: String
    }

    static let identifierPrefix = "octet.checkin."
    /// macOS keeps at most 64 pending notifications per app.
    static let limit = 60

    static func plan(for waits: [Wait], now: Date, calendar: Calendar = .current) -> [Item] {
        var planned: [(date: Date, wait: Wait, index: Int)] = []
        for wait in waits {
            guard let info = wait.checkIn, !info.paused, !info.isFinished else { continue }
            var date = wait.nextCheckAt
            var shown = 0
            var fired = info.fired
            // Two occurrences ahead, so a Mac left closed over a long weekend is still reminded twice.
            while shown < 2 {
                if date > now {
                    planned.append((date, wait, shown))
                    shown += 1
                }
                guard let recurrence = info.recurrence, let following = recurrence.next(after: date, calendar: calendar) else { break }
                fired += 1
                if let count = recurrence.count, fired >= count { break }
                date = following
            }
        }
        return planned.sorted { $0.date < $1.date }.prefix(limit).map { entry in
            let mode = entry.wait.checkIn?.mode ?? .both
            let prompt = HandoffBrief.clip(entry.wait.next.replacingOccurrences(of: "\n", with: " "), 140)
            return Item(identifier: "\(identifierPrefix)\(entry.wait.id).\(entry.index)", date: entry.date, waitId: entry.wait.id,
                        title: "Check-in: " + entry.wait.title,
                        body: (mode.wakesAgent ? "Open Octet to wake the agent. " : "") + prompt)
        }
    }
}

// Fields with a default may be missing (written by an older build), so
// adding one doesn't drop the check-in, or the wait holding it, from disk.

extension CheckInRecurrence {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        every = try container.decodeIfPresent(Int.self, forKey: .every) ?? 1
        unit = try container.decodeIfPresent(Unit.self, forKey: .unit) ?? .days
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        start = try container.decode(Date.self, forKey: .start)
        until = try container.decodeIfPresent(Date.self, forKey: .until)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
    }
}

extension CheckInLogEntry {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        at = try container.decode(Date.self, forKey: .at)
        due = try container.decode(Date.self, forKey: .due)
        sessionAlive = try container.decodeIfPresent(Bool.self, forKey: .sessionAlive)
        // An outcome this build doesn't know is still a line of the record.
        outcome = (try? container.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .skipped
        missed = try container.decodeIfPresent(Int.self, forKey: .missed) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
        manual = try container.decodeIfPresent(Bool.self, forKey: .manual) ?? false
    }
}

extension CheckInInfo {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(CheckInMode.self, forKey: .mode)
        recurrence = try container.decodeIfPresent(CheckInRecurrence.self, forKey: .recurrence)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        fired = try container.decodeIfPresent(Int.self, forKey: .fired) ?? 0
        dueSince = try container.decodeIfPresent(Date.self, forKey: .dueSince)
        dueMissed = try container.decodeIfPresent(Int.self, forKey: .dueMissed) ?? 0
        wakeQueued = try container.decodeIfPresent(Bool.self, forKey: .wakeQueued) ?? false
        queuedReason = try container.decodeIfPresent(String.self, forKey: .queuedReason)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        log = try container.decodeIfPresent([CheckInLogEntry].self, forKey: .log) ?? []
    }
}
