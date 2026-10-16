import Foundation

// MARK: - Records

/// What one conversation spent on one model, from the agent's own logs.
///
/// The usage page reads Claude Code's, Codex's and OpenCode's logs rather
/// than Octet's ledger: the logs go back months, include sessions run in a
/// plain terminal, and carry tokens by kind and the model, which the ledger
/// never saw. Parsers emit one record per model call; `UsageRecords.compact`
/// folds them into one per conversation, model and hour, which is the finest
/// grain the page draws.
struct UsageRecord: Codable, Equatable {
    var date: Date
    /// "claude", "codex" or "opencode".
    var provider: String
    var sessionId: String
    var model: String
    /// The folder the conversation ran in, when the log says.
    var cwd: String?
    var tokens: TokenUsage
    var cost: UsageCost
    /// What the cached input would have cost at the uncached rate, less
    /// what it did cost.
    var cacheSavings: Double
    /// The model call's id, for dropping the copies a resumed Claude Code
    /// session writes into its new log. Nil once compacted.
    var key: String?
}

/// Cost by what it paid for. `other` is spend the tokens don't explain:
/// a provider's own reported cost beyond the estimate, or the whole cost of
/// a model with no known price.
struct UsageCost: Codable, Equatable {
    var input = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var output = 0.0
    var other = 0.0

    var total: Double { input + cacheRead + cacheWrite + output + other }

    static func + (lhs: UsageCost, rhs: UsageCost) -> UsageCost {
        UsageCost(input: lhs.input + rhs.input, cacheRead: lhs.cacheRead + rhs.cacheRead,
                  cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output,
                  other: lhs.other + rhs.other)
    }

    /// The same split, scaled so it sums to `total`.
    func scaled(to total: Double) -> UsageCost {
        let current = self.total
        guard current > 0 else { return UsageCost(other: total) }
        let factor = total / current
        return UsageCost(input: input * factor, cacheRead: cacheRead * factor, cacheWrite: cacheWrite * factor,
                         output: output * factor, other: other * factor)
    }
}

extension TokenUsage {
    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, cacheRead: lhs.cacheRead + rhs.cacheRead,
                   cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output)
    }

    /// Every token the model read or wrote.
    var processed: Int { read + output }
    /// Input not served from cache: fresh input plus what was written to it.
    var uncachedInput: Int { input + cacheWrite }
}

enum UsageRecords {
    /// One record per key, the one with the most output: Claude Code logs a
    /// streamed message once per content block, the earlier lines carrying
    /// a partial output count.
    static func dedupe(_ records: [UsageRecord]) -> [UsageRecord] {
        var keyed: [String: Int] = [:]
        var result: [UsageRecord] = []
        result.reserveCapacity(records.count)
        for record in records {
            guard let key = record.key else { result.append(record); continue }
            if let index = keyed[key] {
                if record.tokens.output > result[index].tokens.output { result[index] = record }
            } else {
                keyed[key] = result.count
                result.append(record)
            }
        }
        return result
    }

    /// Folds records into one per provider, conversation, model and hour.
    /// Run after `dedupe`, since the keys go.
    static func compact(_ records: [UsageRecord]) -> [UsageRecord] {
        struct Group: Hashable { let provider: String, session: String, model: String, hour: Date }
        var groups: [Group: Int] = [:]
        var result: [UsageRecord] = []
        for record in records {
            let hour = hourStart(record.date)
            let group = Group(provider: record.provider, session: record.sessionId, model: record.model, hour: hour)
            if let index = groups[group] {
                result[index].tokens = result[index].tokens + record.tokens
                result[index].cost = result[index].cost + record.cost
                result[index].cacheSavings += record.cacheSavings
                if result[index].cwd == nil { result[index].cwd = record.cwd }
            } else {
                var copy = record
                copy.date = hour
                copy.key = nil
                groups[group] = result.count
                result.append(copy)
            }
        }
        return result
    }

    /// The start of the UTC hour. Every whole-hour time zone agrees on it,
    /// so local days can still be drawn from hour-grained records.
    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - Pricing

/// API list prices, per million tokens, for estimating what a session cost.
/// On a subscription nothing is billed per token; the estimate is each
/// session's weight, in the units everyone compares.
struct ModelRates: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    /// Five-minute cache writes; one-hour writes cost twice the input rate.
    var cacheWrite: Double
    var cacheWriteLong: Double

    init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite = cacheWrite ?? input * 1.25
        self.cacheWriteLong = input * 2
    }
}

enum UsagePricing {
    /// The list price of `model`, matched loosely so dated and routed ids
    /// ("claude-haiku-4-5-20251001", "anthropic/claude-sonnet-5") still
    /// find theirs. Nil when the model is unknown.
    static func rates(for model: String) -> ModelRates? {
        let id = model.lowercased()
        if id.contains("claude") || id.contains("opus") || id.contains("sonnet") || id.contains("haiku")
            || id.contains("fable") || id.contains("mythos") {
            return claude(id)
        }
        if id.contains("gpt") || id.contains("codex") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.contains("/o3")
            || id.contains("/o4") {
            return openAI(id)
        }
        return nil
    }

    private static func claude(_ id: String) -> ModelRates? {
        func has(_ parts: String...) -> Bool { parts.allSatisfy { id.contains($0) } }
        if has("fable-5-1") || has("mythos-5-1") { return ModelRates(input: 10, output: 50, cacheRead: 0.25) }
        if has("fable") || has("mythos") { return ModelRates(input: 10, output: 50) }
        if has("opus-5-5") { return ModelRates(input: 4, output: 20, cacheRead: 0.2) }
        if has("opus-5") || has("opus-4-8") || has("opus-4-7") || has("opus-4-6") || has("opus-4-5") {
            return ModelRates(input: 5, output: 25)
        }
        if has("opus") { return ModelRates(input: 15, output: 75) }
        if has("sonnet-5") { return ModelRates(input: 2, output: 10, cacheRead: 0.2) }
        if has("sonnet") { return ModelRates(input: 3, output: 15) }
        if has("haiku-5-5") { return ModelRates(input: 0.1, output: 0.5) }
        if has("haiku-4-5") { return ModelRates(input: 1, output: 5) }
        if has("haiku") { return ModelRates(input: 0.8, output: 4) }
        return nil
    }

    /// OpenAI publishes no cache-write price; writes are billed as input.
    private static func openAI(_ id: String) -> ModelRates {
        if id.contains("nano") { return ModelRates(input: 0.05, output: 0.4, cacheRead: 0.005, cacheWrite: 0.05) }
        if id.contains("mini") { return ModelRates(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.25) }
        if id.contains("gpt-4.1") || id.contains("o3") || id.contains("o4") {
            return ModelRates(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 2)
        }
        return ModelRates(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)
    }

    /// What `tokens` cost on `model`; `longWrites` of the cache writes were
    /// one-hour ones. Unknown models cost nothing here; a provider that
    /// reports its own cost fills `other` instead.
    static func cost(model: String, tokens: TokenUsage, longWrites: Int = 0) -> UsageCost {
        guard let rates = rates(for: model) else { return UsageCost() }
        let long = min(max(0, longWrites), tokens.cacheWrite)
        let perToken = 1.0 / 1_000_000
        return UsageCost(input: Double(tokens.input) * rates.input * perToken,
                         cacheRead: Double(tokens.cacheRead) * rates.cacheRead * perToken,
                         cacheWrite: (Double(tokens.cacheWrite - long) * rates.cacheWrite + Double(long) * rates.cacheWriteLong) * perToken,
                         output: Double(tokens.output) * rates.output * perToken)
    }

    /// What reading from cache saved: the cached tokens at the uncached
    /// input rate, less their cached rate.
    static func cacheSavings(model: String, tokens: TokenUsage) -> Double {
        guard let rates = rates(for: model) else { return 0 }
        return Double(tokens.cacheRead) * max(0, rates.input - rates.cacheRead) / 1_000_000
    }
}

// MARK: - Aggregation

/// The page's periods. A day is drawn by the hour, the rest by the day.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, week, month, quarter
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Past 24h"
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        }
    }

    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        }
    }

    var hourly: Bool { self == .day }

    /// The first moment counted. Day-grained periods start at a midnight,
    /// so the first bar is a whole day like the rest.
    func start(now: Date, calendar: Calendar = .current) -> Date {
        if hourly { return UsageRecords.hourStart(now.addingTimeInterval(-23 * 3600)) }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

/// What the page counts: dollars or tokens.
enum UsageMeasure: String, CaseIterable, Identifiable {
    case cost, tokens
    var id: String { rawValue }

    func value(_ record: UsageRecord) -> Double {
        switch self {
        case .cost: record.cost.total
        case .tokens: Double(record.tokens.processed)
        }
    }
}

enum UsageSummary {
    static func filter(_ records: [UsageRecord], provider: String?, since: Date, until: Date = .distantFuture) -> [UsageRecord] {
        records.filter { ($0.provider == provider || provider == nil) && $0.date >= since && $0.date <= until }
    }

    struct Totals: Equatable {
        var cost = 0.0
        var sessions = 0
        var tokens = TokenUsage()
        var cacheSavings = 0.0
    }

    static func totals(_ records: [UsageRecord]) -> Totals {
        var totals = Totals()
        var sessions = Set<String>()
        for record in records {
            totals.cost += record.cost.total
            totals.tokens = totals.tokens + record.tokens
            totals.cacheSavings += record.cacheSavings
            sessions.insert(record.provider + "\u{0}" + record.sessionId)
        }
        totals.sessions = sessions.count
        return totals
    }

    /// One provider's part of the period.
    struct ProviderRow: Equatable, Identifiable {
        var id: String { provider }
        let provider: String
        var sessions: Int
        var cost: Double
        var tokens: Int
        /// Its part of the period's measure, 0…1.
        var share: Double
    }

    /// Providers, the biggest by `measure` first.
    static func providers(_ records: [UsageRecord], measure: UsageMeasure = .cost) -> [ProviderRow] {
        let grouped = Dictionary(grouping: records, by: \.provider)
        let whole = records.reduce(0) { $0 + measure.value($1) }
        return grouped.map { provider, rows in
            let totals = totals(rows)
            let value = rows.reduce(0) { $0 + measure.value($1) }
            return ProviderRow(provider: provider, sessions: totals.sessions, cost: totals.cost,
                               tokens: totals.tokens.processed, share: whole > 0 ? value / whole : 0)
        }
        .sorted { ($0.share, $0.cost, $0.provider) > ($1.share, $1.cost, $1.provider) }
    }

    struct SeriesPoint: Equatable, Identifiable {
        var id: String { provider + "@" + String(date.timeIntervalSince1970) }
        let date: Date
        let provider: String
        var value: Double
    }

    /// Each provider's measure per hour (a day) or per local day, every
    /// bucket present and zero-filled so the areas run unbroken.
    static func series(_ records: [UsageRecord], period: UsagePeriod, measure: UsageMeasure,
                       now: Date, calendar: Calendar = .current) -> [SeriesPoint] {
        let buckets = bucketStarts(period: period, now: now, calendar: calendar)
        guard let first = buckets.first else { return [] }
        let providers = Set(records.map(\.provider)).sorted()
        var values: [String: [Double]] = Dictionary(uniqueKeysWithValues: providers.map { ($0, Array(repeating: 0, count: buckets.count)) })
        for record in records where record.date >= first && record.date <= now {
            let index = bucketIndex(record.date, period: period, first: first, calendar: calendar)
            guard index >= 0, index < buckets.count else { continue }
            values[record.provider]?[index] += measure.value(record)
        }
        return providers.flatMap { provider in
            buckets.enumerated().map { SeriesPoint(date: $1, provider: provider, value: values[provider]?[$0] ?? 0) }
        }
    }

    static func bucketStarts(period: UsagePeriod, now: Date, calendar: Calendar = .current) -> [Date] {
        let start = period.start(now: now, calendar: calendar)
        if period.hourly { return (0..<24).map { start.addingTimeInterval(Double($0) * 3600) } }
        return (0..<period.days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func bucketIndex(_ date: Date, period: UsagePeriod, first: Date, calendar: Calendar) -> Int {
        if period.hourly { return Int(date.timeIntervalSince(first) / 3600) }
        return calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? -1
    }

    /// The period's cost by what it paid for.
    static func costByType(_ records: [UsageRecord]) -> UsageCost {
        records.reduce(UsageCost()) { $0 + $1.cost }
    }

    /// A breakdown table row: a model, a day or a conversation.
    struct BreakdownRow: Equatable, Identifiable {
        let id: String
        /// The provider it belongs to; nil for a day, which spans several.
        var provider: String?
        var title: String
        var cost: Double
        var tokens: Int
        /// Its part of the period's measure, 0…1.
        var share: Double
        var date: Date?
    }

    /// Models, the biggest by `measure` first.
    static func byModel(_ records: [UsageRecord], measure: UsageMeasure) -> [BreakdownRow] {
        breakdown(records, measure: measure, key: { $0.provider + "/" + $0.model }) { first in
            BreakdownRow(id: first.provider + "/" + first.model, provider: first.provider, title: first.model, cost: 0, tokens: 0, share: 0)
        }
    }

    /// Conversations, the biggest by `measure` first. The title is the
    /// conversation's folder; the view swaps in Octet's own title when it
    /// knows the conversation.
    static func bySession(_ records: [UsageRecord], measure: UsageMeasure) -> [BreakdownRow] {
        breakdown(records, measure: measure, key: { $0.provider + "/" + $0.sessionId }) { first in
            let folder = first.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
            return BreakdownRow(id: first.provider + "/" + first.sessionId, provider: first.provider, title: folder.isEmpty ? first.sessionId : folder,
                                cost: 0, tokens: 0, share: 0, date: first.date)
        }
    }

    /// Local days with any usage, newest first.
    static func byDay(_ records: [UsageRecord], measure: UsageMeasure, calendar: Calendar = .current) -> [BreakdownRow] {
        let whole = records.reduce(0) { $0 + measure.value($1) }
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return grouped.map { day, rows in
            let totals = totals(rows)
            let value = rows.reduce(0) { $0 + measure.value($1) }
            let providers = Set(rows.map(\.provider))
            return BreakdownRow(id: String(day.timeIntervalSince1970), provider: providers.count == 1 ? providers.first : nil,
                                title: day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                cost: totals.cost, tokens: totals.tokens.processed,
                                share: whole > 0 ? value / whole : 0, date: day)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private static func breakdown(_ records: [UsageRecord], measure: UsageMeasure, key: (UsageRecord) -> String,
                                  make: (UsageRecord) -> BreakdownRow) -> [BreakdownRow] {
        let whole = records.reduce(0) { $0 + measure.value($1) }
        var rows: [String: BreakdownRow] = [:]
        var values: [String: Double] = [:]
        for record in records {
            let id = key(record)
            var row = rows[id] ?? make(record)
            row.cost += record.cost.total
            row.tokens += record.tokens.processed
            if let date = row.date, record.date > date { row.date = record.date }
            rows[id] = row
            values[id, default: 0] += measure.value(record)
        }
        return rows.values.map { row in
            var row = row
            row.share = whole > 0 ? (values[row.id] ?? 0) / whole : 0
            return row
        }
        .sorted { ($0.share, $0.cost, $0.id) > ($1.share, $1.cost, $1.id) }
    }
}

// MARK: - Formatting

enum UsageFormat {
    /// "$7,375.96"; "<$0.01" for a sliver.
    static func money(_ amount: Double) -> String {
        if amount > 0, amount < 0.005 { return "<$0.01" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    /// "18.4B", "21.5M", "312K", "940".
    static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        func short(_ scaled: Double, _ unit: String) -> String {
            scaled < 100 ? String(format: "%.1f%@", scaled, unit) : String(format: "%.0f%@", scaled, unit)
        }
        switch value {
        case ..<1_000: return String(Int(value))
        case ..<1_000_000: return short(value / 1_000, "K")
        case ..<1_000_000_000: return short(value / 1_000_000, "M")
        default: return short(value / 1_000_000_000, "B")
        }
    }

    /// "92.5%"; "<0.1%" for a sliver.
    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    /// A measure's value as the page writes it.
    static func value(_ value: Double, _ measure: UsageMeasure) -> String {
        measure == .cost ? money(value) : tokens(Int(value))
    }
}
