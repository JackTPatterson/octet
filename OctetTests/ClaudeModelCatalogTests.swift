import XCTest

final class ClaudeModelCatalogTests: XCTestCase {
    func testReadsModelsFromInitialize() {
        let initialize: [String: Any] = ["models": [
            ["value": "default", "resolvedModel": "claude-sonnet-5-5", "displayName": "Default (recommended)",
             "description": "Sonnet 5.5 · Efficient for routine tasks", "supportsEffort": true,
             "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
            ["value": "haiku", "resolvedModel": "claude-haiku-4-5", "displayName": "Haiku",
             "description": "Haiku 4.5 · Fastest", "supportsEffort": false],
            ["value": "", "displayName": "Broken"],
        ]]
        let entries = ClaudeModelCatalog.entries(fromInitialize: initialize)
        XCTAssertEqual(entries.map(\.id), ["claude-sonnet-5-5", "haiku"])
        XCTAssertEqual(entries[0].name, "Default (recommended)")
        XCTAssertEqual(entries[0].efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(entries[1].efforts, [])
    }

    func testNoModelsIsEmpty() {
        XCTAssertTrue(ClaudeModelCatalog.entries(fromInitialize: [:]).isEmpty)
    }
}
