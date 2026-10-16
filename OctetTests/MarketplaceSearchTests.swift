import XCTest

final class MarketplaceSearchTests: XCTestCase {
    func testNamesRankAboveDescriptionsAndDescriptionsAreNotFuzzy() {
        let items = [
            (name: "notes", summary: "Keeps a log of what changed in git"),
            (name: "github", summary: "Pull requests and issues"),
            (name: "formatter", summary: "Rewrites files to a consistent style across the whole tree"),
        ]
        let found = MarketplaceCatalog.search(items, query: "git", names: { [$0.name] }, texts: { [$0.summary] })
        // The name match leads; the description that holds the word follows.
        XCTAssertEqual(found.map(\.name), ["github", "notes"])
        // "gt" spells nothing in any name, and descriptions are never
        // fuzzy-matched, though "formatter"'s spells "g…t" many times.
        XCTAssertTrue(MarketplaceCatalog.search(items, query: "gt", names: { [$0.name] }, texts: { [$0.summary] })
            .allSatisfy { $0.name != "formatter" })
    }

    func testSearchNeedsEveryWordAndKeepsOrderOtherwise() {
        XCTAssertEqual(MarketplaceCatalog.searchRank("", names: ["x"], texts: []), 0)
        XCTAssertEqual(MarketplaceCatalog.searchRank("pull issues", names: ["github"], texts: ["Pull requests and issues"]), 3)
        XCTAssertNil(MarketplaceCatalog.searchRank("pull merge", names: ["github"], texts: ["Pull requests and issues"]))
        XCTAssertEqual(MarketplaceCatalog.searchRank("Hub", names: ["github"], texts: []), 1)
        XCTAssertEqual(MarketplaceCatalog.searchRank("GIT", names: ["github"], texts: []), 0)
        let names = ["b-tool", "a-tool", "c-tool"]
        XCTAssertEqual(MarketplaceCatalog.search(names, query: "tool", names: { [$0] }, texts: { _ in [] }), names)
    }

    func testServerTargetDropsClaudesTransportLabel() {
        let http = MarketplaceCatalog.serverTarget("https://api.mobbin.com/mcp (HTTP)")
        XCTAssertEqual(http.value, "https://api.mobbin.com/mcp")
        XCTAssertTrue(http.isURL)
        XCTAssertEqual(http.transport, "http")

        let sse = MarketplaceCatalog.serverTarget("https://example.com/sse (SSE)")
        XCTAssertEqual(sse.value, "https://example.com/sse")
        XCTAssertEqual(sse.transport, "sse")

        let stdio = MarketplaceCatalog.serverTarget("  uvx blender-mcp ")
        XCTAssertEqual(stdio.value, "uvx blender-mcp")
        XCTAssertFalse(stdio.isURL)
    }
}
