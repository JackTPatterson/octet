import Foundation

/// How fast an allowance window is being spent against the clock, after
/// T3 Code's usage limits: ahead of pace when more of it is gone than of
/// the window's time, under pace when less, on pace otherwise.
enum UsagePace: String, Equatable {
    case ahead, on, under

    /// More than a tenth of the window either way counts as off pace.
    static let tolerance = 0.1

    static func of(used: Double, elapsed: Double) -> UsagePace {
        let difference = used - elapsed
        if difference > tolerance { return .ahead }
        if difference < -tolerance { return .under }
        return .on
    }

    /// "ahead of pace", for running text.
    var phrase: String {
        switch self {
        case .ahead: "ahead of pace"
        case .on: "on pace"
        case .under: "under pace"
        }
    }

    /// The longer reading, for a tooltip or a screen reader.
    var explanation: String {
        switch self {
        case .ahead: "Ahead of pace: spending faster than the window elapses"
        case .on: "On pace with the window"
        case .under: "Under pace: headroom left for the rest of the window"
        }
    }
}

extension UsageWindow {
    /// Used, as a whole percentage clamped to 0...100.
    var percentUsed: Int { Int((min(1, max(0, used)) * 100).rounded()) }

    /// What is left, as a whole percentage; always 100 minus `percentUsed`.
    var percentLeft: Int { 100 - percentUsed }

    /// The share of the window's time gone by `now`, 0...1; nil when its
    /// length or reset time isn't known.
    func elapsedShare(at now: Date) -> Double? {
        guard let resetsAt, let duration = UsageRate.duration(named: name), duration > 0 else { return nil }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        return min(1, max(0, elapsed / duration))
    }

    /// Spending against the clock; nil when the window's timing is unknown.
    func pace(at now: Date) -> UsagePace? {
        elapsedShare(at: now).map { UsagePace.of(used: used, elapsed: $0) }
    }

    /// "resets in 2h 10m", "resets in 3d 4h", "resets now"; nil without a
    /// reset time.
    func resetsIn(at now: Date) -> String? {
        guard let when = UsageReport.resetsIn(resetsAt, now: now) else { return nil }
        return when == "now" ? "resets now" : "resets \(when)"
    }

    /// When the window runs out at its average rate so far, if that is
    /// before it resets; nil when it would last, or the rate isn't known.
    func limitBeforeReset(at now: Date) -> Date? {
        guard let resetsAt, let reaches = UsageRate.projectedLimitDate(window: self, at: now),
              reaches > now, reaches < resetsAt else { return nil }
        return reaches
    }

    /// "5-hour limit", "Weekly limit", "Daily limit"; other names pass
    /// through with "limit" after them.
    var title: String {
        switch name {
        case "5h": "5-hour limit"
        case "7d": "Weekly limit"
        case "1d", "24h": "Daily limit"
        default: name.hasSuffix("d") || name.hasSuffix("h") || name.hasSuffix("m") ? "\(name) limit" : name
        }
    }
}
