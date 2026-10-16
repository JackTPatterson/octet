import XCTest

final class CompactUITests: XCTestCase {
    func testCountsStayNarrow() {
        XCTAssertEqual(CompactFormat.count(0), "0")
        XCTAssertEqual(CompactFormat.count(999), "999")
        XCTAssertEqual(CompactFormat.count(1_000), "1k")
        XCTAssertEqual(CompactFormat.count(1_234), "1.2k")
        XCTAssertEqual(CompactFormat.count(12_345), "12k")
        XCTAssertEqual(CompactFormat.count(3_400_000), "3.4m")
        XCTAssertEqual(CompactFormat.count(-5), "0")
    }

    func testElapsedKeepsItsWidth() {
        XCTAssertEqual(CompactFormat.elapsed(0), "0s")
        XCTAssertEqual(CompactFormat.elapsed(42.9), "42s")
        XCTAssertEqual(CompactFormat.elapsed(187), "3m 07s")
        XCTAssertEqual(CompactFormat.elapsed(3_900), "1h 05m")
    }

    func testStashKeepsTheNewestFirstWithoutRepeats() {
        var stash = PromptStash()
        XCTAssertNil(stash.stash("   "))
        stash.stash("first idea")
        stash.stash("second\nwith more")
        stash.stash("first idea")
        XCTAssertEqual(stash.entries.map(\.text), ["first idea", "second\nwith more"])
        XCTAssertEqual(stash.entries[1].title, "second")
        for n in 0..<30 { stash.stash("p\(n)") }
        XCTAssertEqual(stash.entries.count, PromptStash.limit)
        XCTAssertEqual(stash.entries.first?.text, "p29")
    }

    func testTakingBackSwapsWithWhatWasBeingTyped() throws {
        var stash = PromptStash()
        let saved = try XCTUnwrap(stash.stash("fix the login"))
        let taken = stash.take(saved.id, replacing: "half-written thought")
        XCTAssertEqual(taken?.text, "fix the login")
        XCTAssertEqual(stash.entries.map(\.text), ["half-written thought"])
        XCTAssertNil(stash.take(UUID()))
        stash.remove(stash.entries[0].id)
        XCTAssertTrue(stash.entries.isEmpty)
    }
}
