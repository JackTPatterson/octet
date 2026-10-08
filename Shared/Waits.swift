import Foundation

/// Work that can't go on until something outside it happens: a pull request
/// merged, a package published, a site up, a date, an answer from a person.
/// That can take days or months, by which time the conversation is closed
/// and what came next is forgotten. A wait writes both down when they're
/// known: what it waits for, and the next step. Octet checks the condition
/// itself, with no agent running, and when it's met brings the work back
/// with the next step ready to send.
struct Wait: Codable, Equatable, Identifiable {
    enum State: String, Codable { case waiting, ready }

    var id: String = UUID().uuidString
    /// What it waits for, in words: "the API migration PR merged".
    var title: String
    var condition: WaitCondition
    /// What to do then, as it will be sent to the agent. Empty for a
    /// workspace snoozed until something happens, which only comes back.
    var next: String
    var createdAt: Date
    /// "you", or the agent that set it.
    var createdBy: String
    var origin: Origin
    /// The conversation so far, written down when the wait was set, for a
    /// fresh conversation when the old one can't be resumed.
    var brief: String?
    var autoContinue = false

    var state: State = .waiting
    /// What the condition was when the wait was set (the latest release, a
    /// page's fingerprint), for "a new one" or "changes".
    var baseline: String?
    var lastCheckedAt: Date?
    /// What the last check found: "Open · checks running".
    var lastResult: String?
    var failures = 0
    var nextCheckAt: Date
    var readyAt: Date?
    /// When it was last confirmed as still wanted: set, or answered "still
    /// waiting".
    var confirmedAt: Date
    /// For a condition only a person can judge: how often to ask.
    var askEveryDays = 3

    /// Where the work was, to bring it back.
    struct Origin: Codable, Equatable {
        var cwd: String
        var branch: String?
        var workspaceId: String?
        var workspaceLabel: String?
        /// The agent: claude, codex, …
        var agent: String?
        /// The agent's own session id, to resume it.
        var sessionId: String?
        /// Octet's conversation, when it was one of Octet's own.
        var conversationId: String?

        init(cwd: String, branch: String? = nil, workspaceId: String? = nil, workspaceLabel: String? = nil,
             agent: String? = nil, sessionId: String? = nil, conversationId: String? = nil) {
            self.cwd = cwd
            self.branch = branch
            self.workspaceId = workspaceId
            self.workspaceLabel = workspaceLabel
            self.agent = agent
            self.sessionId = sessionId
            self.conversationId = conversationId
        }
    }

    init(title: String, condition: WaitCondition, next: String, origin: Origin, createdBy: String = "you",
         brief: String? = nil, autoContinue: Bool = false, now: Date = Date()) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? condition.description : trimmed
        self.condition = condition
        self.next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = origin
        self.createdBy = createdBy
        self.brief = brief
        self.autoContinue = autoContinue
        createdAt = now
        confirmedAt = now
        nextCheckAt = now
        if case .manual = condition { nextCheckAt = now.addingTimeInterval(Double(askEveryDays) * 86_400) }
        if case .date(let date) = condition { nextCheckAt = max(now, date) }
    }

    /// Only brings the workspace back; nothing to send.
    var isSnooze: Bool { next.isEmpty }

    /// Only a person can say it's happened.
    var isManual: Bool { if case .manual = condition { return true } else { return false } }

    /// Time to ask the person: whether it's happened yet for one only they
    /// can judge, or whether a long wait is still wanted.
    func needsAnswer(now: Date = Date()) -> Bool {
        guard state == .waiting else { return false }
        if isManual { return now >= nextCheckAt }
        return now.timeIntervalSince(confirmedAt) >= Self.reconfirmAfter
    }

    /// A wait this old asks whether it's still wanted, so the list doesn't
    /// fill with ones nobody needs.
    static let reconfirmAfter: TimeInterval = 21 * 86_400

    /// Due for Octet to check now.
    func isDue(now: Date = Date()) -> Bool {
        state == .waiting && !isManual && now >= nextCheckAt
    }

    /// Takes in what a check found.
    mutating func record(_ check: WaitCheck, baseline newBaseline: String? = nil, now: Date = Date()) {
        lastCheckedAt = now
        if let newBaseline, baseline == nil { baseline = newBaseline }
        switch check {
        case .met(let what):
            lastResult = what
            failures = 0
            state = .ready
            readyAt = now
        case .notYet(let what):
            lastResult = what
            failures = 0
        case .failed(let why):
            lastResult = why
            failures += 1
        }
        nextCheckAt = WaitSchedule.next(after: now, waitingSince: createdAt, failures: failures, condition: condition)
    }

    /// "Still waiting": asks again later.
    mutating func confirm(now: Date = Date()) {
        confirmedAt = now
        if isManual { nextCheckAt = now.addingTimeInterval(Double(askEveryDays) * 86_400) }
    }

    /// The person says it's happened.
    mutating func markReady(_ what: String = "Marked done", now: Date = Date()) {
        state = .ready
        readyAt = now
        lastResult = what
    }

    /// "Open · checks running · checked 5m ago".
    func statusLine(now: Date = Date()) -> String {
        if state == .ready { return lastResult ?? "Ready" }
        if isManual { return "Asks you " + (nextCheckAt > now ? "in " + WaitSchedule.span(nextCheckAt.timeIntervalSince(now)) : "now") }
        if case .date(let date) = condition { return date > now ? "in " + WaitSchedule.span(date.timeIntervalSince(now)) : "due" }
        guard let lastCheckedAt else { return "Not checked yet" }
        let age = WorkspaceActivity.ageLabel(since: lastCheckedAt, now: now)
        return [lastResult, "checked " + (age == "now" ? "just now" : age + " ago")].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What a wait waits for, and how Octet can tell.
enum WaitCondition: Codable, Equatable {
    enum PullRequestEvent: String, Codable, CaseIterable {
        case merged, approved, checksPass, checksDone, closed

        var title: String {
            switch self {
            case .merged: "is merged"
            case .approved: "is approved"
            case .checksPass: "passes its checks"
            case .checksDone: "finishes its checks"
            case .closed: "is merged or closed"
            }
        }
    }

    enum Registry: String, Codable, CaseIterable {
        case npm, pypi

        var title: String { self == .npm ? "npm" : "PyPI" }
    }

    enum Page: Codable, Equatable {
        case up, changes, contains(String)
    }

    /// `repo` is owner/name.
    case pullRequest(repo: String, number: Int, event: PullRequestEvent)
    /// A release tagged `tag`, or any release newer than the latest when it was set.
    case release(repo: String, tag: String?)
    /// `version` published, or any version newer than the latest when it was set.
    case package(registry: Registry, name: String, version: String?)
    case url(String, page: Page)
    case file(String)
    /// A shell command that succeeds (exits 0), run in the wait's folder.
    case command(String)
    case date(Date)
    /// Only a person can tell; Octet asks every few days.
    case manual(String)

    enum Kind: String, CaseIterable, Identifiable {
        case pullRequest, release, package, url, file, command, date, manual
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pullRequest: "Pull request"
            case .release: "GitHub release"
            case .package: "Package version"
            case .url: "Web page"
            case .file: "File"
            case .command: "Command succeeds"
            case .date: "Date"
            case .manual: "Something I'll confirm"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .pullRequest: .pullRequest
        case .release: .release
        case .package: .package
        case .url: .url
        case .file: .file
        case .command: .command
        case .date: .date
        case .manual: .manual
        }
    }

    var description: String {
        switch self {
        case .pullRequest(let repo, let number, let event):
            return "\(repo)#\(number) \(event.title)"
        case .release(let repo, let tag):
            return tag.map { "\(repo) \($0) is released" } ?? "a new release of \(repo)"
        case .package(let registry, let name, let version):
            return version.map { "\(name) \($0) is on \(registry.title)" } ?? "a new version of \(name) on \(registry.title)"
        case .url(let url, let page):
            switch page {
            case .up: return "\(url) is up"
            case .changes: return "\(url) changes"
            case .contains(let text): return "\(url) shows “\(text)”"
            }
        case .file(let path):
            return "\((path as NSString).abbreviatingWithTildeInPath) exists"
        case .command(let command):
            return "`\(command)` succeeds"
        case .date(let date):
            return WaitSchedule.dateLabel(date)
        case .manual(let text):
            return text
        }
    }

    /// A link to look at it, where there is one.
    var link: URL? {
        switch self {
        case .pullRequest(let repo, let number, _): URL(string: "https://github.com/\(repo)/pull/\(number)")
        case .release(let repo, let tag):
            URL(string: "https://github.com/\(repo)/releases" + (tag.map { "/tag/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) } ?? ""))
        case .package(let registry, let name, _):
            URL(string: registry == .npm ? "https://www.npmjs.com/package/\(name)" : "https://pypi.org/project/\(name)/")
        case .url(let url, _): URL(string: url)
        default: nil
        }
    }

    // MARK: - Reading one from words

    /// A condition from how a person or an agent writes it. Recognises a
    /// pull request (`https://github.com/o/r/pull/12`, `o/r#12`, with
    /// "approved", "checks pass", "checks done" or "closed"; merged by
    /// default), a release (`release:o/r [tag]` or its GitHub link), a
    /// package (`npm:name[@version]`, `pypi:name[==version]`), a page
    /// (`url:https://… [up|changes|contains:<text>]`, or a bare link),
    /// `file:<path>`, `command:<shell command>`, and a date (`date:2026-11-03`,
    /// `in 3 days`, `tomorrow`). Anything else is one only a person can
    /// judge. Nil when empty.
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current,
                      home: String = NSHomeDirectory()) -> WaitCondition? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        func after(_ prefixes: [String]) -> String? {
            for prefix in prefixes where lower.hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        if let rest = after(["date:", "on:", "at:", "until:"]) {
            return WaitSchedule.parseDate(rest, now: now, calendar: calendar).map { .date($0) } ?? .manual(text)
        }
        if let rest = after(["command:", "cmd:", "run:"]), !rest.isEmpty { return .command(rest) }
        if let rest = after(["file:"]), !rest.isEmpty {
            return .file(rest.hasPrefix("~") ? home + rest.dropFirst() : rest)
        }
        if let rest = after(["npm:"]), let package = splitPackage(rest, separators: ["@"]) {
            return .package(registry: .npm, name: package.name, version: package.version)
        }
        if let rest = after(["pypi:", "pip:"]), let package = splitPackage(rest, separators: ["==", "@"]) {
            return .package(registry: .pypi, name: package.name, version: package.version)
        }
        if let rest = after(["release:"]) {
            let parts = rest.split(whereSeparator: { $0 == " " || $0 == "@" }).map(String.init)
            guard let repo = parts.first, isRepo(repo) else { return .manual(text) }
            return .release(repo: repo, tag: parts.dropFirst().first)
        }
        if let pr = pullRequest(in: text) { return pr }
        if let match = firstMatch(#"https?://github\.com/([\w.-]+/[\w.-]+)/releases(?:/tag/([^\s/?#]+))?"#, in: text) {
            return .release(repo: match[1], tag: match.count > 2 && !match[2].isEmpty ? match[2].removingPercentEncoding ?? match[2] : nil)
        }
        if let rest = after(["url:", "page:"]) ?? (lower.hasPrefix("http://") || lower.hasPrefix("https://") ? text : nil) {
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let url = parts.first, URL(string: url)?.scheme?.hasPrefix("http") == true else { return .manual(text) }
            let tail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let tailLower = tail.lowercased()
            if tailLower.hasPrefix("contains") {
                let needle = tail.dropFirst("contains".count).trimmingCharacters(in: CharacterSet(charactersIn: ": \"'“”"))
                return .url(url, page: needle.isEmpty ? .up : .contains(needle))
            }
            if tailLower.hasPrefix("change") { return .url(url, page: .changes) }
            return .url(url, page: .up)
        }
        if let date = WaitSchedule.parseDate(text, now: now, calendar: calendar) { return .date(date) }
        return .manual(text)
    }

    /// A pull request named anywhere in `text`, with the event its words ask for.
    static func pullRequest(in text: String) -> WaitCondition? {
        let match = firstMatch(#"https?://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"#, in: text)
            ?? firstMatch(#"(?:^|[\s(:])([\w.-]+/[\w.-]+)#(\d+)\b"#, in: text)
        guard let match, let number = Int(match[2]), isRepo(match[1]) else { return nil }
        return .pullRequest(repo: match[1], number: number, event: event(in: text))
    }

    /// Which pull request event a sentence means; merged unless it says otherwise.
    static func event(in text: String) -> PullRequestEvent {
        let lower = text.lowercased()
        if lower.contains("approv") { return .approved }
        let aboutChecks = lower.contains("check") || lower.range(of: #"\bci\b"#, options: .regularExpression) != nil
            || lower.contains("build")
        if aboutChecks, lower.contains("finish") || lower.contains("done") || lower.contains("complete") { return .checksDone }
        if aboutChecks || lower.contains("green") || lower.contains("pass") { return .checksPass }
        if lower.contains("closed") || lower.contains("close") { return .closed }
        return .merged
    }

    private static func isRepo(_ text: String) -> Bool {
        let parts = text.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// `name@1.2.0`, `@scope/name@1.2.0`, `name==1.2`.
    private static func splitPackage(_ text: String, separators: [String]) -> (name: String, version: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        for separator in separators {
            guard let range = trimmed.range(of: separator, options: .backwards), range.lowerBound > trimmed.startIndex else { continue }
            let name = String(trimmed[..<range.lowerBound])
            let version = String(trimmed[range.upperBound...])
            return (name, version.isEmpty ? nil : version)
        }
        return (trimmed, nil)
    }

    /// The whole match and its groups.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// What one check of a condition found.
enum WaitCheck: Equatable {
    /// It's happened; the words say what.
    case met(String)
    /// Not yet; the words say where it stands.
    case notYet(String)
    /// Couldn't tell (offline, signed out, the command not found).
    case failed(String)
}

/// Reading what was fetched for a condition. Fetching is the app's; these
/// only decide, so they can be tested.
enum WaitEvaluation {
    static func pullRequest(_ pr: GitHubPullRequest, event: WaitCondition.PullRequestEvent) -> WaitCheck {
        let merged = pr.state == "MERGED"
        let closed = pr.state == "CLOSED"
        switch event {
        case .merged:
            if merged { return .met("Merged") }
            if closed { return .met("Closed without merging") }
        case .closed:
            if merged { return .met("Merged") }
            if closed { return .met("Closed") }
        case .approved:
            if pr.reviewDecision == "APPROVED" { return .met("Approved") }
            if merged { return .met("Merged") }
            if closed { return .met("Closed without merging") }
        case .checksPass:
            if pr.checks == .passing { return .met("Checks passed") }
            if merged { return .met("Merged") }
            if closed { return .met("Closed without merging") }
        case .checksDone:
            if pr.checks == .passing { return .met("Checks passed") }
            if pr.checks == .failing { return .met("Checks failed") }
            if merged { return .met("Merged") }
            if closed { return .met("Closed without merging") }
        }
        return .notYet(pr.statusText)
    }

    /// `tags`: the repository's releases, newest first.
    static func release(tags: [String], wanted: String?, baseline: String?) -> (check: WaitCheck, baseline: String?) {
        if let wanted {
            return (tags.contains(wanted) ? .met("\(wanted) released") : .notYet("Latest is \(tags.first ?? "none")"), nil)
        }
        guard let latest = tags.first else { return (.notYet("No releases yet"), "") }
        guard let baseline else { return (.notYet("Latest is \(latest)"), latest) }
        return latest != baseline ? (.met("\(latest) released"), nil) : (.notYet("Latest is \(latest)"), nil)
    }

    static func package(versions: Set<String>, latest: String?, wanted: String?, baseline: String?) -> (check: WaitCheck, baseline: String?) {
        if let wanted {
            return (versions.contains(wanted) ? .met("\(wanted) published") : .notYet("Latest is \(latest ?? "unknown")"), nil)
        }
        guard let latest else { return (.failed("No version listed"), nil) }
        guard let baseline else { return (.notYet("Latest is \(latest)"), latest) }
        return latest != baseline ? (.met("\(latest) published") , nil) : (.notYet("Latest is \(latest)"), nil)
    }

    /// `status` nil when the page couldn't be reached at all.
    static func page(status: Int?, body: Data?, page: WaitCondition.Page, baseline: String?) -> (check: WaitCheck, baseline: String?) {
        switch page {
        case .up:
            guard let status else { return (.notYet("Not reachable"), nil) }
            return (200..<400).contains(status) ? (.met("Up (\(status))"), nil) : (.notYet("Answers \(status)"), nil)
        case .contains(let text):
            guard let status, let body else { return (.notYet("Not reachable"), nil) }
            let found = String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains(text)
            return found ? (.met("Shows “\(text)”"), nil) : (.notYet("Not there yet (\(status))"), nil)
        case .changes:
            guard let status, let body else { return (.failed("Not reachable"), nil) }
            let print = fingerprint(body)
            guard let baseline else { return (.notYet("Watching (\(status))"), print) }
            return print != baseline ? (.met("Changed"), nil) : (.notYet("Unchanged"), nil)
        }
    }

    /// A stable fingerprint of a page (FNV-1a), enough to tell it changed.
    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// npm's registry document: every version, and `dist-tags.latest`.
    static func npmVersions(_ data: Data) -> (versions: Set<String>, latest: String?)? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let versions = Set((json["versions"] as? [String: Any])?.keys.map { $0 } ?? [])
        let latest = (json["dist-tags"] as? [String: Any])?["latest"] as? String
        guard !versions.isEmpty || latest != nil else { return nil }
        return (versions, latest)
    }

    /// PyPI's JSON: every release, and `info.version`.
    static func pypiVersions(_ data: Data) -> (versions: Set<String>, latest: String?)? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let versions = Set((json["releases"] as? [String: Any])?.keys.map { $0 } ?? [])
        let latest = (json["info"] as? [String: Any])?["version"] as? String
        guard !versions.isEmpty || latest != nil else { return nil }
        return (versions, latest)
    }

    /// `gh api repos/o/r/releases`: the published tags, newest first.
    static func releaseTags(_ data: Data) -> [String]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.filter { ($0["draft"] as? Bool) != true }.compactMap { $0["tag_name"] as? String }
    }
}

/// When to check again, and the words for times.
enum WaitSchedule {
    /// Often while it's new, when the thing waited on most often happens
    /// soon after; then less and less. A failure backs off further.
    static func interval(waitingFor age: TimeInterval, failures: Int) -> TimeInterval {
        let base: TimeInterval
        switch age {
        case ..<3600: base = 5 * 60
        case ..<86_400: base = 15 * 60
        case ..<(7 * 86_400): base = 3600
        default: base = 4 * 3600
        }
        let backoff = pow(2, Double(min(failures, 5)))
        return min(base * backoff, 12 * 3600)
    }

    static func next(after now: Date, waitingSince: Date, failures: Int, condition: WaitCondition) -> Date {
        if case .date(let date) = condition, date > now { return date }
        return now.addingTimeInterval(interval(waitingFor: now.timeIntervalSince(waitingSince), failures: failures))
    }

    /// "5m", "3h", "2d", "3w".
    static func span(_ seconds: TimeInterval) -> String {
        switch max(0, seconds) {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }

    static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// `2026-11-03`, `2026-11-03 14:30`, an ISO 8601 time, `tomorrow`,
    /// `in 3 days`, `in 2 weeks`, `in 90 minutes`. A day alone means 9:00
    /// that morning.
    static func parseDate(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        func morning(_ day: Date) -> Date? { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) }
        if text == "tomorrow" || text == "tomorrow morning" {
            return calendar.date(byAdding: .day, value: 1, to: now).flatMap(morning)
        }
        if text == "next week" {
            return calendar.date(byAdding: .day, value: 7, to: now).flatMap(morning)
        }
        if let match = WaitCondition.firstMatch(#"^in\s+(\d+)\s*(minute|min|m|hour|hr|h|day|d|week|wk|w|month|mo)s?$"#, in: text),
           let amount = Int(match[1]) {
            let unit = match[2]
            let component: Calendar.Component
            switch unit {
            case "minute", "min", "m": component = .minute
            case "hour", "hr", "h": component = .hour
            case "day", "d": component = .day
            case "week", "wk", "w": component = .weekOfYear
            default: component = .month
            }
            return calendar.date(byAdding: component, value: amount, to: now)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw.trimmingCharacters(in: .whitespaces)) { return date }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return format == "yyyy-MM-dd" ? morning(date) : date
            }
        }
        return nil
    }
}

/// Notices, in an agent's reply, work left waiting on something outside it
/// ("Once the PR is merged, we can remove the old endpoint"), so Octet can
/// offer to write it down as a wait.
enum WaitSuggestion {
    struct Found: Equatable {
        /// "the PR is merged".
        var waitingFor: String
        /// "remove the old endpoint".
        var next: String
        /// What Octet can check, when the reply names it (a pull request).
        var condition: WaitCondition?
    }

    /// Words that mark something happening outside the conversation, not a
    /// step the agent takes next.
    private static let external = [
        "merge", "approv", "review", "releas", "publish", "deploy", "live", "available", "propagat", "land",
        "ship", "rolls out", "rolled out", "goes out", "expire", "renew", "dns", "certificate", "app store",
        "testflight", "reply", "respond", "gets back", "signs", "signed", "granted", "access", "quota",
        "ci ", "checks", "pipeline", "upstream", "vendor", "support", "ticket", "notar", "apple", "google play",
    ]

    static func detect(_ text: String) -> Found? {
        let sentences = text
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let patterns = [
            #"\b(?:once|after|when)\s+(.{6,160}?)\s*,\s*(?:we|you|i|it)\s+(?:can|could|should|will|'ll|need to|have to|must)\s+(.{4,200})"#,
            #"\b(?:wait|waiting)\s+(?:for|on|until)\s+(.{6,160}?)\s+(?:before|so\s+(?:we|you|i)\s+can|and\s+then)\s+(.{4,200})"#,
            #"\bblocked\s+(?:on|by)\s+(.{6,160}?)\s*(?:[;,—-]+\s*(?:then|after that)\s+(.{4,200}))"#,
        ]
        for sentence in sentences {
            for pattern in patterns {
                guard let match = WaitCondition.firstMatch(pattern, in: sentence), match.count > 2 else { continue }
                let waitingFor = clean(match[1])
                let next = clean(match[2])
                let lower = waitingFor.lowercased() + " "
                guard !next.isEmpty, external.contains(where: { lower.contains($0) }) else { continue }
                let condition = WaitCondition.pullRequest(in: sentence) ?? WaitCondition.pullRequest(in: text).map { (found: WaitCondition) -> WaitCondition in
                    guard case .pullRequest(let repo, let number, _) = found else { return found }
                    return .pullRequest(repo: repo, number: number, event: WaitCondition.event(in: waitingFor))
                }
                return Found(waitingFor: waitingFor, next: next.prefix(1).uppercased() + next.dropFirst(), condition: condition)
            }
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!*_`\"'").union(.whitespacesAndNewlines))
    }
}
