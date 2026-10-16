import XCTest

final class UsageReportTests: XCTestCase {
    func testTokenBreakdownsFromEachAgent() {
        XCTAssertEqual(TokenUsage.claude(["input_tokens": 12, "cache_read_input_tokens": 80_000, "cache_creation_input_tokens": 3000, "output_tokens": 900]),
                       TokenUsage(input: 12, cacheRead: 80_000, cacheWrite: 3000, output: 900))
        XCTAssertNil(TokenUsage.claude([:]))
        // Codex counts cached input inside input.
        XCTAssertEqual(TokenUsage.codex(["inputTokens": 10_000, "cachedInputTokens": 8000, "outputTokens": 500, "reasoningOutputTokens": 200]),
                       TokenUsage(input: 2000, cacheRead: 8000, cacheWrite: 0, output: 700))
        XCTAssertEqual(TokenUsage.openCode(["input": 100, "output": 50, "cache": ["read": 4000, "write": 10]]),
                       TokenUsage(input: 100, cacheRead: 4000, cacheWrite: 10, output: 50))
        XCTAssertEqual(TokenUsage.openCode(["input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4])?.read, 8)
    }

    func testPaceAgainstAnEvenSpread() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // A 5-hour window with 2.5 hours left: halfway.
        let window = UsageWindow(name: "5h", used: 0.5, resetsAt: now.addingTimeInterval(2.5 * 3600))
        XCTAssertEqual(UsageReport.expected(window, at: now) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(UsageReport.pace(window, at: now), "on pace")
        XCTAssertEqual(UsageReport.pace(UsageWindow(name: "5h", used: 0.9, resetsAt: window.resetsAt), at: now), "ahead of pace")
        XCTAssertEqual(UsageReport.pace(UsageWindow(name: "5h", used: 0.1, resetsAt: window.resetsAt), at: now), "under pace")
        XCTAssertNil(UsageReport.pace(UsageWindow(name: "5h", used: 0.1, resetsAt: nil), at: now))
    }

    func testWordsAndLevels() {
        XCTAssertEqual(UsageReport.tokens(512), "512")
        XCTAssertEqual(UsageReport.tokens(84_200), "84.2k")
        XCTAssertEqual(UsageReport.tokens(200_000), "200k")
        XCTAssertEqual(UsageReport.tokens(1_200_000), "1.2M")
        XCTAssertEqual(UsageReport.level(0.5), .normal)
        XCTAssertEqual(UsageReport.level(0.75), .high)
        XCTAssertEqual(UsageReport.level(0.95), .critical)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UsageReport.resetsIn(now.addingTimeInterval(2 * 3600 + 600), now: now), "in 2h 10m")
        XCTAssertEqual(UsageReport.resetsIn(now.addingTimeInterval(3 * 86_400 + 4 * 3600), now: now), "in 3d 4h")
        XCTAssertEqual(UsageReport.resetsIn(now.addingTimeInterval(30), now: now), "now")
    }

    func testSummaryAndContextShare() {
        let now = Date(timeIntervalSince1970: 0)
        let report = UsageReport(agent: "Claude Code", model: "Opus", contextUsed: 50_000, contextWindow: 200_000,
                                 costUSD: 1.5, windows: [UsageWindow(name: "5h", used: 0.42, resetsAt: now.addingTimeInterval(3600))],
                                 turns: 4, at: now)
        XCTAssertEqual(report.contextFraction, 0.25)
        XCTAssertEqual(report.summary, """
        Usage · Claude Code · Opus
        Context: 50.0k of 200k (25%)
        5h: 42% used, resets in 1h 0m
        Cost: $1.50 at API prices
        Turns: 4
        """)
    }

    func testSpendPerHourAcrossConversations() {
        let now = Date(timeIntervalSince1970: 100_000)
        var ledger = UsageLedger()
        func entry(_ hoursAgo: Double, _ cost: Double) -> UsageEntry {
            UsageEntry(date: now.addingTimeInterval(-hoursAgo * 3600), sessionId: "s", title: "t", agent: "claude", cwd: "/", cost: cost)
        }
        ledger.entries = [entry(0.1, 1), entry(0.5, 2), entry(23.5, 4), entry(30, 8)]
        let hourly = ledger.hourly(hours: 24, now: now)
        XCTAssertEqual(hourly.count, 24)
        XCTAssertEqual(hourly.last, 3)
        XCTAssertEqual(hourly.first, 4)
        XCTAssertEqual(hourly.reduce(0, +), 7)
    }
}
