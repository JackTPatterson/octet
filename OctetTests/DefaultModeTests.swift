import XCTest
@testable import Octet

/// Settings › Default mode: what it starts as, what's stored, and what each
/// mode shows.
final class DefaultModeTests: XCTestCase {
    private func stored(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let data = try JSONEncoder().encode(OctetSettings())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testChatIsTheDefault() {
        XCTAssertEqual(OctetSettings().defaultMode, .chat)
        XCTAssertEqual(OctetSettings.defaults.defaultMode, .chat)
    }

    func testSettingsFromBeforeTheModeExistedOpenInChat() throws {
        // Someone who updates without ever having chosen.
        let data = try stored { $0.removeValue(forKey: "defaultMode") }
        let loaded = SettingsStore.load(data)
        XCTAssertEqual(loaded.values.defaultMode, .chat)
        XCTAssertFalse(loaded.unreadable)
    }

    func testAChoiceSurvivesASaveAndLoad() throws {
        var values = OctetSettings()
        values.defaultMode = .workspace
        let loaded = SettingsStore.load(try JSONEncoder().encode(values))
        XCTAssertEqual(loaded.values.defaultMode, .workspace)
        values.defaultMode = .chat
        XCTAssertEqual(SettingsStore.load(try JSONEncoder().encode(values)).values.defaultMode, .chat)
    }

    func testAnUnknownModeFallsBackToChatWithoutBeingSavedOver() throws {
        let data = try stored { $0["defaultMode"] = "zen" }
        let loaded = SettingsStore.load(data)
        XCTAssertEqual(loaded.values.defaultMode, .chat)
        XCTAssertTrue(loaded.unreadable)
    }

    func testOnlyWorkspaceShowsTheTerminal() {
        XCTAssertTrue(OctetSettings.DefaultMode.workspace.showsTerminal)
        XCTAssertFalse(OctetSettings.DefaultMode.chat.showsTerminal)
        XCTAssertEqual(OctetSettings.DefaultMode.chat.other, .workspace)
        XCTAssertEqual(OctetSettings.DefaultMode.workspace.other, .chat)
    }

    func testRestoreDefaultsPutsChatBack() {
        var values = OctetSettings()
        values.defaultMode = .workspace
        XCTAssertTrue(SettingsDefaults.all.contains { $0.label == "Default mode" && !$0.isDefault(values) })
        XCTAssertEqual(SettingsDefaults.restored(values).defaultMode, .chat)
    }

    func testTheSettingCanBeFound() {
        XCTAssertEqual(SettingsSearchIndex.search("terminal splash").first { $0.title == "Default mode" }?.section, .general)
    }

    @MainActor func testStartersFillTheComposerWithSomethingToSend() {
        XCTAssertGreaterThanOrEqual(ChatHomeView.starters.count, 3)
        XCTAssertEqual(Set(ChatHomeView.starters.map(\.id)).count, ChatHomeView.starters.count)
        XCTAssertTrue(ChatHomeView.starters.allSatisfy { !$0.prompt.isEmpty })
    }
}
