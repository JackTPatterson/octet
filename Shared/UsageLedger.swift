import Foundation

/// What each conversation spent and when, kept for two weeks, so "where did
/// my usage go" has an answer. Agents report a running cost for a
/// conversation (Claude Code and OpenCode do; Codex does not); each time it
/// grows, the growth is recorded against the time it happened. For a
/// subscription that cost is at API prices, so it shows each conversation's
/// weight in the allowance rather than money.
struct UsageEntry: Codable, Equatable {
    var date: Date
    var sessionId: String
    var title: String
    var agent: String
    var cwd: String
    /// What this turn added, at API prices.
    var cost: Double
    /// How full the context was after it, 0 to 1, when known.
    var contextFraction: Double?
}

struct UsageLedger: Codable, Equatable {
    var entries: [UsageEntry] = []

    static let keepDays = 14
    static let maxEntries = 5000

    /// How much a conversation's cost grew, or nil when it didn't. A lower
    /// reading than before is a new baseline (a resumed process counts from
    /// zero), not a refund.
    static func growth(from previous: Double?, to current: Double?) -> Double? {
        guard let current, current > 0 else { return nil }
        let before = previous ?? 0
        if current > before { return current - before }
        return nil
    }

    mutating func record(_ entry: UsageEntry, now: Date = Date()) {
        guard entry.cost > 0 else { return }
        entries.append(entry)
        prune(now: now)
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        entries.removeAll { $0.date < cutoff }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// One conversation's spending over a period.
    struct Row: Identifiable, Equatable {
        var id: String { sessionId }
        let sessionId: String
        var title: String
        var agent: String
        var cwd: String
        var cost: Double
        var turns: Int
        var lastDate: Date
        /// The fullest its context got in the period.
        var peakContext: Double?

        var costPerTurn: Double { turns > 0 ? cost / Double(turns) : 0 }

        /// A long conversation: each message re-reads all of it, so a fresh
        /// start with a summary costs less to carry on.
        var heavyContext: Bool { (peakContext ?? 0) >= UsageLedger.heavyContext && turns >= 3 }
    }

    /// Past this fraction of the window, the context is what costs.
    static let heavyContext = 0.6

    /// Conversations that spent anything since `date`, the biggest first.
    func rows(since date: Date) -> [Row] {
        var byId: [String: Row] = [:]
        var order: [String] = []
        for entry in entries where entry.date >= date {
            if var row = byId[entry.sessionId] {
                row.cost += entry.cost
                row.turns += 1
                if entry.date >= row.lastDate {
                    row.lastDate = entry.date
                    row.title = entry.title
                    row.cwd = entry.cwd
                }
                if let fraction = entry.contextFraction { row.peakContext = max(row.peakContext ?? 0, fraction) }
                byId[entry.sessionId] = row
            } else {
                order.append(entry.sessionId)
                byId[entry.sessionId] = Row(sessionId: entry.sessionId, title: entry.title, agent: entry.agent, cwd: entry.cwd,
                                            cost: entry.cost, turns: 1, lastDate: entry.date, peakContext: entry.contextFraction)
            }
        }
        return order.compactMap { byId[$0] }.sorted { ($0.cost, $0.lastDate) > ($1.cost, $1.lastDate) }
    }

    func total(since date: Date) -> Double {
        entries.filter { $0.date >= date }.reduce(0) { $0 + $1.cost }
    }

    /// The periods the breakdown offers.
    enum Period: String, CaseIterable, Identifiable {
        case fiveHours, day, week
        var id: String { rawValue }

        var title: String {
            switch self {
            case .fiveHours: "Last 5 hours"
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .fiveHours: 5 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            }
        }

        func start(now: Date = Date()) -> Date { now.addingTimeInterval(-seconds) }
    }

    /// "$1.20", "$0.04", "<$0.01".
    static func money(_ amount: Double) -> String {
        if amount > 0, amount < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", amount)
    }
}
