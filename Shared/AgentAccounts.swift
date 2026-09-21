import Foundation

/// One usage window of a subscription plan, e.g. Claude's 5-hour and 7-day
/// limits or Codex's weekly limit.
struct UsageWindow: Codable, Equatable {
    /// "5h", "7d", …
    let name: String
    /// Fraction of the window used, 0...1.
    let used: Double
    let resetsAt: Date?
}

/// How an agent CLI is signed in: a subscription (show allowance) or an API
/// key (show cost).
struct AgentAccount: Codable, Equatable {
    enum Kind: String, Codable { case subscription, apiKey, signedOut, unknown }

    let agent: String
    var kind: Kind
    /// "Max", "Pro", "ChatGPT", … for subscriptions.
    var plan: String?
    var windows: [UsageWindow] = []
    /// When the windows were last reported.
    var updatedAt: Date?

    /// The windows still running. A window that has reset says nothing about
    /// the one replacing it: an agent reports its allowance only as it works,
    /// so the last report outlives the window it described, and showing 100%
    /// hours after that window rolled over is worse than showing nothing.
    var live: [UsageWindow] {
        windows.filter { window in
            // A window with no reset time can't expire on its own, so it is
            // judged by the age of the reading that carried it.
            guard let resetsAt = window.resetsAt else {
                return updatedAt.map { Date().timeIntervalSince($0) < Self.readingLifetime } ?? true
            }
            return resetsAt > Date()
        }
    }

    /// How long a reading with no reset time of its own is worth showing.
    static let readingLifetime: TimeInterval = 3600

    /// When every window has gone, when the last one did.
    var expiredAt: Date? {
        guard live.isEmpty, !windows.isEmpty else { return nil }
        return windows.compactMap(\.resetsAt).max() ?? updatedAt
    }

    /// The window closest to its limit, for compact displays.
    var tightest: UsageWindow? { live.max { $0.used < $1.used } }
}

enum AgentAccounts {
    /// `claude auth status` prints JSON: `authMethod` "claude.ai" is a
    /// subscription (`subscriptionType` names the plan); an API key, a
    /// console login, or a third-party provider is billed per token.
    static func claude(authStatus data: Data) -> AgentAccount {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentAccount(agent: "claude", kind: .unknown)
        }
        guard json["loggedIn"] as? Bool == true else { return AgentAccount(agent: "claude", kind: .signedOut) }
        let method = (json["authMethod"] as? String ?? "").lowercased()
        let provider = (json["apiProvider"] as? String ?? "firstParty")
        if method == "claude.ai", provider == "firstParty" {
            let plan = (json["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return AgentAccount(agent: "claude", kind: .subscription, plan: plan)
        }
        return AgentAccount(agent: "claude", kind: .apiKey, plan: provider == "firstParty" ? nil : provider)
    }

    /// `codex login status` prints a sentence: "Logged in using ChatGPT" or
    /// "Logged in using an API key".
    static func codex(loginStatus text: String) -> AgentAccount {
        let lower = text.lowercased()
        if lower.contains("not logged in") { return AgentAccount(agent: "codex", kind: .signedOut) }
        if lower.contains("chatgpt") { return AgentAccount(agent: "codex", kind: .subscription, plan: "ChatGPT") }
        if lower.contains("api key") { return AgentAccount(agent: "codex", kind: .apiKey) }
        return AgentAccount(agent: "codex", kind: .unknown)
    }

    /// Claude's stream reports plan limits in `rate_limit_event`s:
    /// `unifiedWindows` holds every window with utilization as a fraction.
    static func claudeWindows(rateLimitInfo info: [String: Any]) -> [UsageWindow] {
        if let unified = info["unifiedWindows"] as? [String: [String: Any]], !unified.isEmpty {
            return unified.compactMap { key, value in
                guard let used = value["utilization"] as? Double else { return nil }
                return UsageWindow(name: name(claudeWindow: key), used: used,
                                   resetsAt: (value["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
            }
            .sorted { order($0.name) < order($1.name) }
        }
        // Older CLIs report only the window that triggered the event.
        guard let type = info["rateLimitType"] as? String, let used = info["utilization"] as? Double else { return [] }
        return [UsageWindow(name: name(claudeWindow: type), used: used,
                            resetsAt: (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))]
    }

    /// Claude Code keeps what it last fetched for its own usage display in
    /// `~/.claude.json` under `cachedUsageUtilization`. It is the only record
    /// of the allowance on disk, so it fills the title bar before a
    /// conversation has run; `fetchedAtMs` says how old it is, and a live
    /// stream supersedes it. Percentages here are 0...100, and `limits`
    /// describes each window: a session window, the weekly total, and a
    /// weekly one scoped to a model.
    static func claudeWindows(cachedUsage object: Any) -> ([UsageWindow], Date?)? {
        guard let cached = object as? [String: Any], let utilization = cached["utilization"] else { return nil }
        let windows = claudeWindows(utilization: utilization)
        guard !windows.isEmpty else { return nil }
        return (windows, (cached["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// The account's own usage, as `/api/oauth/usage` answers and as the cache
    /// stores it. Percentages here are 0...100, unlike a stream's fractions.
    /// `limits` describes each window; older payloads carry named keys.
    static func claudeWindows(utilization object: Any) -> [UsageWindow] {
        guard let utilization = object as? [String: Any] else { return [] }

        var windows: [UsageWindow] = []
        if let limits = utilization["limits"] as? [[String: Any]] {
            windows = limits.compactMap { limit in
                guard let name = name(cachedLimit: limit), let percent = limit["percent"] as? Double else { return nil }
                return UsageWindow(name: name, used: percent / 100, resetsAt: date(iso: limit["resets_at"]))
            }
        }
        if windows.isEmpty {
            windows = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].compactMap { key in
                guard let window = utilization[key] as? [String: Any],
                      let percent = window["utilization"] as? Double else { return nil }
                return UsageWindow(name: name(claudeWindow: key), used: percent / 100, resetsAt: date(iso: window["resets_at"]))
            }
        }
        return windows.sorted { order($0.name) < order($1.name) }
    }

    /// The label for one entry of the cache's `limits`, or nil for a kind
    /// Octet doesn't show.
    private static func name(cachedLimit limit: [String: Any]) -> String? {
        switch limit["kind"] as? String {
        case "session": return "5h"
        case "weekly_all": return "7d"
        case "weekly_scoped":
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            return model.map { "7d \($0)" } ?? "7d scoped"
        default: return nil
        }
    }

    /// The cache writes times as ISO 8601 with fractional seconds.
    private static func date(iso value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Codex writes `rate_limits` into its session logs with each token
    /// count; the newest entry with a window is the current allowance.
    static func codexWindows(sessionLines lines: [String]) -> [UsageWindow]? {
        for line in lines.reversed() where line.contains("\"rate_limits\"") {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let limits = findRateLimits(record) else { continue }
            let windows = codexWindows(rateLimits: limits)
            if !windows.isEmpty { return windows }
        }
        return nil
    }

    /// One `rate_limits` payload: a primary window and sometimes a shorter
    /// one. The session logs spell it `used_percent` / `window_minutes` /
    /// `resets_at`; the app server answers in camel case.
    static func codexWindows(rateLimits limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["used_percent"] ?? window["usedPercent"]) as? Double else { return nil }
            let minutes = ((window["window_minutes"] ?? window["windowDurationMins"]) as? Double).map(Int.init) ?? 0
            let resets = ((window["resets_at"] ?? window["resetsAt"]) as? Double).map(Date.init(timeIntervalSince1970:))
            return UsageWindow(name: name(minutes: minutes), used: percent / 100, resetsAt: resets)
        }
        .sorted { order($0.name) < order($1.name) }
    }

    private static func findRateLimits(_ object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let limits = dict["rate_limits"] as? [String: Any] { return limits }
            for value in dict.values { if let found = findRateLimits(value) { return found } }
        }
        return nil
    }

    static func name(claudeWindow key: String) -> String {
        switch key {
        case "five_hour": "5h"
        case "seven_day": "7d"
        case "seven_day_opus": "7d Opus"
        case "seven_day_sonnet": "7d Sonnet"
        default: key.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func name(minutes: Int) -> String {
        switch minutes {
        case 0: "window"
        case ..<60: "\(minutes)m"
        case ..<1440: "\(minutes / 60)h"
        default: "\(minutes / 1440)d"
        }
    }

    private static func order(_ name: String) -> Int {
        name.hasSuffix("h") || name.hasSuffix("m") ? 0 : 1
    }
}
