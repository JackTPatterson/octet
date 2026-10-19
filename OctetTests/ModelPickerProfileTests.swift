import XCTest

final class ModelPickerProfileTests: XCTestCase {
    func testUnknownAndRoutedModelsDoNotInventRatings() {
        XCTAssertNil(ModelPickerProfile.resolve(id: "future-model", title: "New Model"))
        XCTAssertNil(ModelPickerProfile.resolve(id: "claude-sonnet-5", title: "Default (recommended)"))
        XCTAssertNil(ModelPickerProfile.resolve(id: "auto", title: "Auto"))
    }
    func testRecognizedFamilyHasBoundedRelativeScores() throws {
        for family in ["opus", "sonnet", "haiku"] {
            let profile = try XCTUnwrap(ModelPickerProfile.resolve(id: "claude-\(family)-5", title: family))
            XCTAssertTrue([profile.speed, profile.quality, profile.cost].allSatisfy { (1...5).contains($0) })
        }
    }
    func testBillingOnlyUsesExplicitCatalogPrices() {
        XCTAssertNil(ModelPickerProfile.billing(in: "Fastest for quick answers"))
        XCTAssertNil(ModelPickerProfile.billing(in: nil))
        XCTAssertEqual(ModelPickerProfile.billing(in: "1M context · $3/$15"), "$3 in · $15 out / M tokens")
        XCTAssertEqual(ModelPickerProfile.billing(in: "$0.25/$1.25"), "$0.25 in · $1.25 out / M tokens")
    }
    func testEffortFallsBackToSupportedValues() {
        XCTAssertEqual(ModelPickerProfile.effectiveEffort(explicit: "ultra", fallback: "high", levels: ["low", "high"]), "high")
        XCTAssertEqual(ModelPickerProfile.effectiveEffort(explicit: "low", fallback: "high", levels: ["low", "high"]), "low")
        XCTAssertNil(ModelPickerProfile.effectiveEffort(explicit: "high", fallback: "high", levels: []))
    }
}
