import Foundation

/// What a transcript notice is, said by whoever wrote it, so the view draws
/// an error as an error and a compaction as a compaction without guessing
/// from the words.
enum AgentNoticeStyle: Equatable {
    case plain
    /// Something failed: a turn, a request, an answer Octet couldn't give.
    case error
    /// Context is being summarized to make room; becomes `compacted`.
    case compacting
    case compacted
}

/// A usage or spend limit the agent stopped on, as the agent reported it:
/// Claude Code's rejected rate-limit event, Codex's `usageLimitExceeded`
/// error. Another agent, or the time it resets, gets past it.
struct AgentLimitHit: Equatable {
    /// The agent's own words about it, when it said any.
    var message: String
    var resetsAt: Date?
}

/// Why an agent couldn't start at all.
enum AgentLaunchFailure: Equatable {
    /// Its command isn't installed, or isn't on the login shell's PATH
    /// (the shell exits 127).
    case notInstalled(String)
}

/// Reading a limit message for what to show with it: the sentences, the
/// links (raise the limit, manage usage) and, when the agent gave no
/// timestamp, the reset time written in it.
enum AgentLimitText {
    struct Action: Equatable {
        let title: String
        let url: URL
    }

    /// Claude Code writes "You've hit your limit · resets 3pm (Europe/London)
    /// · claude.ai/settings/usage": sentences and links between dots.
    static func parts(_ message: String) -> (lines: [String], actions: [Action]) {
        var lines: [String] = []
        var actions: [Action] = []
        for part in message.split(separator: "·").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if let url = link(in: part) {
                let lower = part.lowercased()
                let title = lower.contains("raise") ? "Raise limit"
                    : lower.contains("usage") || lower.contains("settings") ? "Manage usage" : "Open link"
                actions.append(Action(title: title, url: url))
            } else if !part.isEmpty {
                lines.append(sentence(part))
            }
        }
        return (lines, actions)
    }

    /// CLI notices sometimes omit the scheme (`claude.ai/settings/...`).
    /// Accept web-looking tokens, while leaving ordinary dotted prose alone.
    static func link(in text: String) -> URL? {
        let token = text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "·,.;()")) }
            .first { value in
                value.hasPrefix("https://") || value.hasPrefix("http://")
                    || (value.contains(".") && value.contains("/"))
            }
        guard let token else { return nil }
        return URL(string: token.contains("://") ? token : "https://" + token)
    }

    /// "resets 3pm (America/New_York)": the next such time after `now`.
    static func resetDate(in message: String, now: Date = Date()) -> Date? {
        guard message.lowercased().contains("reset"),
              let expression = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#,
                                                        options: .caseInsensitive),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let hourRange = Range(match.range(at: 1), in: message),
              var hour = Int(message[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: message).flatMap { Int(message[$0]) } ?? 0
        let meridiem = Range(match.range(at: 3), in: message).map { message[$0].lowercased() } ?? "am"
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        let timezone = message.split(separator: "(").dropFirst().first
            .flatMap { $0.split(separator: ")").first }
            .flatMap { TimeZone(identifier: String($0)) }
            ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute),
                                 matchingPolicy: .nextTime)
    }

    /// Whether a Codex error is its usage limit: `codexErrorInfo` is a
    /// string for plain cases and an object keyed by the case otherwise.
    static func isCodexUsageLimit(_ error: [String: Any]?) -> Bool {
        guard let info = error?["codexErrorInfo"] else { return false }
        if let name = info as? String { return name == "usageLimitExceeded" }
        if let object = info as? [String: Any] { return object["usageLimitExceeded"] != nil }
        return false
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

extension AgentConversation {
    /// A notice in the transcript, of the kind its writer says it is.
    mutating func appendNotice(_ text: String, style: AgentNoticeStyle) {
        items.append(AgentItem(id: UUID().uuidString, kind: .notice(text), noticeStyle: style))
    }

    /// Compaction has begun: one row says so, however many times it's said.
    mutating func beginCompaction() {
        if items.last?.noticeStyle == .compacting { return }
        appendNotice("Compacting the conversation to free context…", style: .compacting)
    }

    /// The summary is in: the row that said it was starting now says it's
    /// done, or a row says so when the start went unannounced.
    mutating func finishCompaction() {
        if let index = items.lastIndex(where: { $0.noticeStyle == .compacting }) {
            items[index].noticeStyle = .compacted
            items[index].kind = .notice("The conversation was compacted.")
        } else {
            appendNotice("The conversation was compacted.", style: .compacted)
        }
    }

    /// A turn ended: whatever compaction it started has finished with it.
    mutating func settleCompaction() {
        for index in items.indices where items[index].noticeStyle == .compacting {
            items[index].noticeStyle = .compacted
            items[index].kind = .notice("The conversation was compacted.")
        }
    }
}
