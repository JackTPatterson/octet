import Foundation

/// The tokens the latest model call read and wrote, as each agent reports
/// them; what's unknown is zero.
struct TokenUsage: Equatable, Codable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    var read: Int { input + cacheRead + cacheWrite }
    var isEmpty: Bool { read + output == 0 }

    /// Claude Code's `usage`: input_tokens, cache_read_input_tokens, …
    static func claude(_ usage: [String: Any]) -> TokenUsage? {
        let value = TokenUsage(input: usage["input_tokens"] as? Int ?? 0,
                               cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                               cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                               output: usage["output_tokens"] as? Int ?? 0)
        return value.isEmpty ? nil : value
    }

    /// Codex's token usage breakdown: inputTokens (cached ones included),
    /// cachedInputTokens, outputTokens.
    static func codex(_ usage: [String: Any]) -> TokenUsage? {
        let input = usage["inputTokens"] as? Int ?? 0
        let cached = usage["cachedInputTokens"] as? Int ?? 0
        let value = TokenUsage(input: max(0, input - cached), cacheRead: cached, cacheWrite: 0,
                               output: (usage["outputTokens"] as? Int ?? 0) + (usage["reasoningOutputTokens"] as? Int ?? 0))
        return value.isEmpty ? nil : value
    }

    /// OpenCode's and Pi's: input, output, cache read/write (nested or flat).
    static func openCode(_ tokens: [String: Any]) -> TokenUsage? {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let value = TokenUsage(input: int(tokens["input"]),
                               cacheRead: int(cache["read"] ?? tokens["cacheRead"]),
                               cacheWrite: int(cache["write"] ?? tokens["cacheWrite"]),
                               output: int(tokens["output"]))
        return value.isEmpty ? nil : value
    }
}

/// Everything Octet knows about a conversation's usage at one moment, for
/// the card `/usage` (and `/cost`, `/context`, `/stats`) shows in place of
/// an agent's plain-text summary. Same shape for every agent; what an agent
/// doesn't report is left out of the card.
struct UsageReport: Equatable {
    var agent: String
    var model: String?
    var contextUsed: Int?
    var contextWindow: Int?
    /// Context in use after each turn, oldest first.
    var contextHistory: [Int] = []
    var tokens: TokenUsage?
    /// What the conversation has cost at API prices.
    var costUSD: Double?
    /// Paid per token (an API key), so the cost is money, not a share of a plan.
    var paysPerToken = false
    var plan: String?
    var windows: [UsageWindow] = []
    var turns = 0
    var startedAt: Date?
    /// API-price spend across every conversation, per hour for the last 24, oldest first.
    var lastDay: [Double] = []
    var at: Date

    var contextFraction: Double? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }

    /// Where a window should be by now if the allowance were spread evenly
    /// over it, 0…1; nil when its length or reset isn't known.
    static func expected(_ window: UsageWindow, at now: Date) -> Double? {
        guard let resetsAt = window.resetsAt, let duration = UsageRate.duration(named: window.name), duration > 0 else { return nil }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        return min(1, max(0, elapsed / duration))
    }

    /// "Ahead of pace", "on pace", "under pace" for a window, by more than
    /// a tenth of it either way.
    static func pace(_ window: UsageWindow, at now: Date) -> String? {
        guard let expected = expected(window, at: now) else { return nil }
        let difference = window.used - expected
        if difference > 0.1 { return "ahead of pace" }
        if difference < -0.1 { return "under pace" }
        return "on pace"
    }

    /// The level a share of something is at, for color and words.
    enum Level: Equatable { case normal, high, critical }

    static func level(_ fraction: Double) -> Level {
        fraction >= 0.9 ? .critical : fraction >= 0.7 ? .high : .normal
    }

    /// "84.2k", "1.2M", "512".
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return String(count)
        case ..<1_000_000:
            let value = Double(count) / 1000
            return value < 100 ? String(format: "%.1fk", value) : String(format: "%.0fk", value)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    /// "in 2h 10m", "in 3d 4h", "now".
    static func resetsIn(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 60 else { return "now" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    /// The same, as plain text, for copying or for a screen reader.
    var summary: String {
        var lines = ["Usage · \(agent)" + (model.map { " · \($0)" } ?? "")]
        if let used = contextUsed {
            var line = "Context: \(Self.tokens(used))"
            if let window = contextWindow, window > 0 { line += " of \(Self.tokens(window)) (\(Int((contextFraction ?? 0) * 100))%)" }
            lines.append(line)
        }
        for window in windows {
            var line = "\(window.name): \(Int((window.used * 100).rounded()))% used"
            if let reset = Self.resetsIn(window.resetsAt, now: at) { line += ", resets \(reset)" }
            lines.append(line)
        }
        if let cost = costUSD { lines.append("Cost: \(UsageLedger.money(cost))" + (paysPerToken ? "" : " at API prices")) }
        lines.append("Turns: \(turns)")
        return lines.joined(separator: "\n")
    }
}

extension UsageLedger {
    /// Spend per hour across every conversation, for the `hours` up to
    /// `now`, oldest first.
    func hourly(hours: Int = 24, now: Date = Date()) -> [Double] {
        var buckets = Array(repeating: 0.0, count: hours)
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        for entry in entries where entry.date > start && entry.date <= now {
            let index = min(hours - 1, Int(entry.date.timeIntervalSince(start) / 3600))
            buckets[index] += entry.cost
        }
        return buckets
    }
}
