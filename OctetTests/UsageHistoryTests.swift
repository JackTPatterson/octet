import XCTest

final class UsageHistoryTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2033-05-18 03:33:20 UTC.
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func record(_ provider: String, _ session: String, model: String = "m", hoursAgo: Double,
                        tokens: TokenUsage = TokenUsage(input: 10, cacheRead: 0, cacheWrite: 0, output: 5),
                        cost: Double = 1, savings: Double = 0, key: String? = nil) -> UsageRecord {
        UsageRecord(date: now.addingTimeInterval(-hoursAgo * 3600), provider: provider, sessionId: session, model: model,
                    cwd: "/code/\(session)", tokens: tokens, cost: UsageCost(input: cost), cacheSavings: savings, key: key)
    }

    // MARK: Pricing

    func testPricingMatchesDatedAndRoutedIds() {
        XCTAssertEqual(UsagePricing.rates(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(UsagePricing.rates(for: "claude-opus-5-5")?.cacheRead, 0.2)
        XCTAssertEqual(UsagePricing.rates(for: "claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertEqual(UsagePricing.rates(for: "anthropic/claude-sonnet-5")?.output, 10)
        XCTAssertEqual(UsagePricing.rates(for: "gpt-6-sol")?.input, 1.25)
        XCTAssertEqual(UsagePricing.rates(for: "gpt-5-mini")?.input, 0.25)
        XCTAssertNil(UsagePricing.rates(for: "deepseek/deepseek-flash-latest"))
    }

    func testCostSplitsByKindAndPricesLongCacheWritesAtDoubleInput() {
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, $5 five-minute write, $8 one-hour write.
        let tokens = TokenUsage(input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 2_000_000, output: 1_000_000)
        let cost = UsagePricing.cost(model: "claude-opus-5-5", tokens: tokens, longWrites: 1_000_000)
        XCTAssertEqual(cost.input, 4, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 0.2, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheWrite, 5 + 8, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 20, accuracy: 1e-9)
        XCTAssertEqual(cost.total, 37.2, accuracy: 1e-9)
        XCTAssertEqual(UsagePricing.cost(model: "mystery", tokens: tokens), UsageCost())
    }

    func testCacheSavingsIsCachedInputAtTheUncachedRateLessItsCachedRate() {
        let tokens = TokenUsage(input: 0, cacheRead: 10_000_000, cacheWrite: 0, output: 0)
        // 10M at ($4 - $0.20) per million.
        XCTAssertEqual(UsagePricing.cacheSavings(model: "claude-opus-5-5", tokens: tokens), 38, accuracy: 1e-9)
        XCTAssertEqual(UsagePricing.cacheSavings(model: "unknown", tokens: tokens), 0)
    }

    func testScaledCostKeepsTheSplitAndUnpricedCostIsOther() {
        let scaled = UsageCost(input: 1, output: 3).scaled(to: 8)
        XCTAssertEqual(scaled.input, 2, accuracy: 1e-9)
        XCTAssertEqual(scaled.output, 6, accuracy: 1e-9)
        XCTAssertEqual(UsageCost().scaled(to: 0.5), UsageCost(other: 0.5))
    }

    // MARK: Parsers

    func testClaudeLogKeepsOneRecordPerMessageWithItsFullOutput() {
        let line = { (output: Int, request: String) in
            #"{"type":"assistant","timestamp":"2033-05-18T03:00:00.000Z","sessionId":"s1","cwd":"/code/app","requestId":"\#(request)","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500,"output_tokens":\#(output),"cache_creation":{"ephemeral_1h_input_tokens":500}}}}"#
        }
        let log = [
            #"{"type":"user","message":{"content":"the word usage appears here"}}"#,
            line(3, "req_1"), line(120, "req_1"),
            #"{"type":"assistant","timestamp":"2033-05-18T03:01:00Z","sessionId":"s1","message":{"id":"msg_2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":1}}}"#,
            "not json",
        ].joined(separator: "\n")
        let records = UsageRecords.dedupe(UsageLogParsers.claude(Data(log.utf8)))
        XCTAssertEqual(records.count, 1)
        let first = records[0]
        XCTAssertEqual(first.provider, "claude")
        XCTAssertEqual(first.sessionId, "s1")
        XCTAssertEqual(first.cwd, "/code/app")
        XCTAssertEqual(first.tokens, TokenUsage(input: 2, cacheRead: 1000, cacheWrite: 500, output: 120))
        // 500 one-hour writes at $8 per million.
        XCTAssertEqual(first.cost.cacheWrite, 0.004, accuracy: 1e-12)
        XCTAssertEqual(first.date, Date(timeIntervalSince1970: 2_000_000_000 - 2000))
    }

    func testCodexLogRecordsGrowthOfTheRunningTotalUnderTheCurrentModel() {
        func count(_ input: Int, _ cached: Int, _ output: Int, at time: String) -> String {
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":1}}}}"#
        }
        let log = [
            #"{"timestamp":"2033-05-18T02:00:00Z","type":"session_meta","payload":{"id":"cx1","cwd":"/code/api"}}"#,
            #"{"timestamp":"2033-05-18T02:00:01Z","type":"turn_context","payload":{"model":"gpt-6-sol","cwd":"/code/api"}}"#,
            count(100, 40, 10, at: "2033-05-18T02:00:02Z"),
            count(100, 40, 10, at: "2033-05-18T02:00:03Z"), // the same total again
            count(250, 140, 30, at: "2033-05-18T02:00:04Z"),
            count(50, 0, 5, at: "2033-05-18T02:00:05Z"), // a restarted counter
        ].joined(separator: "\n")
        let records = UsageLogParsers.codex(Data(log.utf8))
        XCTAssertEqual(records.map(\.tokens), [
            TokenUsage(input: 60, cacheRead: 40, cacheWrite: 0, output: 10),
            TokenUsage(input: 50, cacheRead: 100, cacheWrite: 0, output: 20),
            TokenUsage(input: 50, cacheRead: 0, cacheWrite: 0, output: 5),
        ])
        XCTAssertEqual(Set(records.map(\.sessionId)), ["cx1"])
        XCTAssertEqual(Set(records.map(\.model)), ["gpt-6-sol"])
        XCTAssertEqual(records.first?.cwd, "/code/api")
    }

    func testOpenCodeReportedCostWinsAndReasoningCountsAsOutput() throws {
        let json = #"{"role":"assistant","path":{"cwd":"/code/web"},"cost":0.5,"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":1000,"write":0}},"modelID":"~anthropic/claude-sonnet-5","providerID":"openrouter","time":{"created":2000000000000}}"#
        let record = try XCTUnwrap(UsageLogParsers.openCode(messageJSON: Data(json.utf8), sessionId: "oc1"))
        XCTAssertEqual(record.model, "anthropic/claude-sonnet-5")
        XCTAssertEqual(record.tokens, TokenUsage(input: 100, cacheRead: 1000, cacheWrite: 0, output: 25))
        XCTAssertEqual(record.cost.total, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(record.cost.output, 0)
        XCTAssertEqual(record.date, now)

        let unpriced = #"{"role":"assistant","cost":0.25,"tokens":{"input":1,"output":1},"modelID":"mystery","time":{"created":1}}"#
        XCTAssertEqual(UsageLogParsers.openCode(messageJSON: Data(unpriced.utf8), sessionId: "x")?.cost, UsageCost(other: 0.25))
        let user = #"{"role":"user","tokens":{"input":1},"time":{"created":1}}"#
        XCTAssertNil(UsageLogParsers.openCode(messageJSON: Data(user.utf8), sessionId: "x"))
    }

    // MARK: Records

    func testDedupeAcrossFilesAndCompactByHour() {
        let a = record("claude", "s", hoursAgo: 0.1, key: "k1")
        var copy = a
        copy.tokens.output = 50
        let b = record("claude", "s", hoursAgo: 0.2, key: "k2")
        let other = record("claude", "s", hoursAgo: 2, key: "k3")
        let compacted = UsageRecords.compact(UsageRecords.dedupe([a, b, copy, other]))
        XCTAssertEqual(compacted.count, 2)
        let hour = compacted.first { $0.date == UsageRecords.hourStart(a.date) }
        XCTAssertEqual(hour?.tokens.output, 55)
        XCTAssertEqual(hour?.cost.total ?? 0, 2, accuracy: 1e-9)
        XCTAssertNil(hour?.key)
    }

    // MARK: Aggregation

    func testTotalsCountSessionsPerProviderAndSplitInput() {
        let records = [
            record("claude", "a", hoursAgo: 1, tokens: TokenUsage(input: 10, cacheRead: 100, cacheWrite: 20, output: 5), cost: 2, savings: 1),
            record("claude", "a", hoursAgo: 3, cost: 1),
            record("codex", "a", hoursAgo: 2, cost: 0.5),
        ]
        let totals = UsageSummary.totals(records)
        XCTAssertEqual(totals.sessions, 2)
        XCTAssertEqual(totals.cost, 3.5, accuracy: 1e-9)
        XCTAssertEqual(totals.cacheSavings, 1)
        XCTAssertEqual(totals.tokens.cacheRead, 100)
        XCTAssertEqual(totals.tokens.uncachedInput, 10 + 20 + 10 + 10)
        XCTAssertEqual(totals.tokens.processed, totals.tokens.cacheRead + totals.tokens.uncachedInput + totals.tokens.output)
    }

    func testProvidersRankBySharesOfTheMeasure() {
        let records = [
            record("claude", "a", hoursAgo: 1, tokens: TokenUsage(input: 10, cacheRead: 0, cacheWrite: 0, output: 0), cost: 3),
            record("codex", "b", hoursAgo: 1, tokens: TokenUsage(input: 90, cacheRead: 0, cacheWrite: 0, output: 0), cost: 1),
        ]
        let byCost = UsageSummary.providers(records, measure: .cost)
        XCTAssertEqual(byCost.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(byCost[0].share, 0.75, accuracy: 1e-9)
        XCTAssertEqual(byCost[0].sessions, 1)
        let byTokens = UsageSummary.providers(records, measure: .tokens)
        XCTAssertEqual(byTokens.map(\.provider), ["codex", "claude"])
        XCTAssertEqual(byTokens[0].share, 0.9, accuracy: 1e-9)
    }

    func testDailySeriesIsZeroFilledPerProviderInLocalDays() {
        let records = [
            record("claude", "a", hoursAgo: 1, cost: 2),
            record("claude", "a", hoursAgo: 2, cost: 1),
            record("codex", "b", hoursAgo: 48, cost: 4),
            record("codex", "b", hoursAgo: 24 * 40, cost: 9), // outside the week
        ]
        let points = UsageSummary.series(records, period: .week, measure: .cost, now: now, calendar: utc)
        XCTAssertEqual(points.count, 2 * 7)
        let claude = points.filter { $0.provider == "claude" }
        XCTAssertEqual(claude.last?.value, 3)
        XCTAssertEqual(claude.dropLast().map(\.value), Array(repeating: 0, count: 6))
        XCTAssertEqual(claude.first?.date, utc.date(byAdding: .day, value: -6, to: utc.startOfDay(for: now)))
        let codex = points.filter { $0.provider == "codex" }
        XCTAssertEqual(codex.map(\.value), [0, 0, 0, 0, 4, 0, 0])
    }

    func testDaySeriesRunsByTheHour() {
        let records = [record("claude", "a", hoursAgo: 0.1, cost: 2), record("claude", "a", hoursAgo: 24, cost: 1)]
        let points = UsageSummary.series(records, period: .day, measure: .tokens, now: now, calendar: utc)
        XCTAssertEqual(points.count, 24)
        XCTAssertEqual(points.last?.value, 15)
        XCTAssertEqual(points.first?.value, 0) // a day ago falls before the first whole hour
        XCTAssertEqual(points.last?.date, UsageRecords.hourStart(now))
    }

    func testPeriodStartsAtLocalMidnight() {
        XCTAssertEqual(UsagePeriod.month.start(now: now, calendar: utc),
                       utc.date(byAdding: .day, value: -29, to: utc.startOfDay(for: now)))
        XCTAssertEqual(UsagePeriod.day.start(now: now, calendar: utc), UsageRecords.hourStart(now).addingTimeInterval(-23 * 3600))
    }

    func testCostByTypeSumsEveryKind() {
        var a = record("claude", "a", hoursAgo: 1)
        a.cost = UsageCost(input: 1, cacheRead: 2, cacheWrite: 3, output: 4, other: 0)
        var b = record("opencode", "b", hoursAgo: 1)
        b.cost = UsageCost(other: 5)
        XCTAssertEqual(UsageSummary.costByType([a, b]), UsageCost(input: 1, cacheRead: 2, cacheWrite: 3, output: 4, other: 5))
    }

    func testModelBreakdownRanksByShare() {
        let records = [
            record("claude", "a", model: "opus", hoursAgo: 1, cost: 6),
            record("claude", "b", model: "opus", hoursAgo: 2, cost: 2),
            record("codex", "c", model: "gpt", hoursAgo: 1, cost: 2),
        ]
        let rows = UsageSummary.byModel(records, measure: .cost)
        XCTAssertEqual(rows.map(\.title), ["opus", "gpt"])
        XCTAssertEqual(rows.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(rows[0].cost, 8)
        XCTAssertEqual(rows[0].share, 0.8, accuracy: 1e-9)
        XCTAssertEqual(rows[0].tokens, 30)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
    }

    func testDayBreakdownIsNewestFirstAndSessionsNameTheirFolder() {
        let records = [
            record("claude", "a", hoursAgo: 1, cost: 1),
            record("codex", "b", hoursAgo: 30, cost: 3),
        ]
        let days = UsageSummary.byDay(records, measure: .cost, calendar: utc)
        XCTAssertEqual(days.map(\.cost), [1, 3])
        XCTAssertEqual(days.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(days[1].share, 0.75, accuracy: 1e-9)
        let sessions = UsageSummary.bySession(records, measure: .cost)
        XCTAssertEqual(sessions.map(\.title), ["b", "a"])
        XCTAssertEqual(sessions.first?.id, "codex/b")
    }

    func testFilterByProviderAndTime() {
        let records = [record("claude", "a", hoursAgo: 1), record("codex", "b", hoursAgo: 1), record("claude", "c", hoursAgo: 100)]
        XCTAssertEqual(UsageSummary.filter(records, provider: "claude", since: now.addingTimeInterval(-86_400)).map(\.sessionId), ["a"])
        XCTAssertEqual(UsageSummary.filter(records, provider: nil, since: .distantPast).count, 3)
    }

    func testAccountFilterSeparatesDefaultFoldersFromProfiles() {
        var work = record("claude", "w", hoursAgo: 1)
        work.account = "work"
        let personal = record("claude", "p", hoursAgo: 1)
        let records = [work, personal]
        XCTAssertEqual(UsageSummary.filter(records, provider: nil, account: nil, since: .distantPast).count, 2)
        XCTAssertEqual(UsageSummary.filter(records, provider: nil, account: "", since: .distantPast).map(\.sessionId), ["p"])
        XCTAssertEqual(UsageSummary.filter(records, provider: nil, account: "work", since: .distantPast).map(\.sessionId), ["w"])
        // The same conversation id under two accounts stays two records.
        var twin = personal
        twin.account = "work"
        XCTAssertEqual(UsageRecords.compact([personal, twin]).count, 2)
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(UsageFormat.money(7375.958), "$7,375.96")
        XCTAssertEqual(UsageFormat.money(0.001), "<$0.01")
        XCTAssertEqual(UsageFormat.tokens(18_400_000_000), "18.4B")
        XCTAssertEqual(UsageFormat.tokens(21_500_000), "21.5M")
        XCTAssertEqual(UsageFormat.tokens(312_000), "312K")
        XCTAssertEqual(UsageFormat.tokens(940), "940")
        XCTAssertEqual(UsageFormat.percent(0.925), "92.5%")
        XCTAssertEqual(UsageFormat.percent(0.0001), "<0.1%")
    }
}
