import XCTest

final class UsageLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func entry(_ session: String, _ cost: Double, hoursAgo: Double, title: String = "T", context: Double? = nil) -> UsageEntry {
        UsageEntry(date: now.addingTimeInterval(-hoursAgo * 3600), sessionId: session, title: title, agent: "claude",
                   cwd: "/r", cost: cost, contextFraction: context)
    }

    func testOnlyGrowthIsRecorded() {
        XCTAssertEqual(UsageLedger.growth(from: nil, to: 0.4), 0.4)
        XCTAssertEqual(UsageLedger.growth(from: 0.4, to: 1.0) ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertNil(UsageLedger.growth(from: 1.0, to: 1.0))
        // A resumed process counts from zero again: not a refund, and not new spend either.
        XCTAssertNil(UsageLedger.growth(from: 3.0, to: 0.2))
        XCTAssertNil(UsageLedger.growth(from: nil, to: nil))
        XCTAssertNil(UsageLedger.growth(from: 0.5, to: nil))
        XCTAssertNil(UsageLedger.growth(from: nil, to: 0))
    }

    func testRowsAreTheBiggestSpendersInThePeriod() {
        var ledger = UsageLedger()
        ledger.record(entry("a", 1.0, hoursAgo: 1, title: "Old title", context: 0.2), now: now)
        ledger.record(entry("a", 2.0, hoursAgo: 0.5, title: "New title", context: 0.7), now: now)
        ledger.record(entry("a", 1.0, hoursAgo: 0.2, context: 0.65), now: now)
        ledger.record(entry("b", 3.5, hoursAgo: 2), now: now)
        ledger.record(entry("c", 9.0, hoursAgo: 30), now: now)

        let recent = ledger.rows(since: UsageLedger.Period.fiveHours.start(now: now))
        XCTAssertEqual(recent.map(\.sessionId), ["a", "b"])
        XCTAssertEqual(recent[0].cost, 4.0, accuracy: 0.0001)
        XCTAssertEqual(recent[0].turns, 3)
        XCTAssertEqual(recent[0].peakContext, 0.7)
        XCTAssertTrue(recent[0].heavyContext)
        XCTAssertEqual(recent[0].costPerTurn, 4.0 / 3, accuracy: 0.0001)
        XCTAssertFalse(recent[1].heavyContext)
        XCTAssertEqual(ledger.total(since: UsageLedger.Period.fiveHours.start(now: now)), 7.5, accuracy: 0.0001)

        let week = ledger.rows(since: UsageLedger.Period.week.start(now: now))
        XCTAssertEqual(week.map(\.sessionId), ["c", "a", "b"])
        // The latest title wins.
        XCTAssertEqual(recent[0].title, "T")
    }

    func testAShortConversationIsNotCalledHeavy() {
        var ledger = UsageLedger()
        ledger.record(entry("a", 1, hoursAgo: 1, context: 0.9), now: now)
        XCTAssertFalse(ledger.rows(since: now.addingTimeInterval(-86_400))[0].heavyContext)
    }

    func testOldEntriesAndFreeOnesAreDropped() {
        var ledger = UsageLedger()
        ledger.record(entry("a", 1, hoursAgo: 24 * 15), now: now)
        ledger.record(entry("b", 0, hoursAgo: 1), now: now)
        ledger.record(entry("c", 1, hoursAgo: 24 * 13), now: now)
        XCTAssertEqual(ledger.entries.map(\.sessionId), ["c"])
        var many = UsageLedger()
        for index in 0..<(UsageLedger.maxEntries + 50) { many.record(entry("s\(index)", 0.01, hoursAgo: 1), now: now) }
        XCTAssertEqual(many.entries.count, UsageLedger.maxEntries)
        XCTAssertEqual(many.entries.first?.sessionId, "s50")
    }

    func testMoneyAndPeriods() {
        XCTAssertEqual(UsageLedger.money(1.234), "$1.23")
        XCTAssertEqual(UsageLedger.money(0.001), "<$0.01")
        XCTAssertEqual(UsageLedger.money(0), "$0.00")
        XCTAssertEqual(UsageLedger.Period.fiveHours.seconds, 18_000)
        XCTAssertEqual(UsageLedger.Period.week.title, "Last 7 days")
    }

    func testTheLedgerSurvivesTheDisk() throws {
        var ledger = UsageLedger()
        ledger.record(entry("a", 1.5, hoursAgo: 1, context: 0.3), now: now)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(UsageLedger.self, from: data), ledger)
    }
}
