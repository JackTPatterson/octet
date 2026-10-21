import XCTest
@testable import Octet

/// Loading stored settings: what survives a bad entry, and when the store
/// rewrites what's saved.
final class SettingsLoadTests: XCTestCase {
    /// Today's defaults as stored JSON, edited by `change`.
    private func stored(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let data = try JSONEncoder().encode(OctetSettings())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testCurrentSettingsLoadWithoutASave() throws {
        let loaded = SettingsStore.load(try stored())
        XCTAssertFalse(loaded.shouldSave)
        XCTAssertFalse(loaded.unreadable)
        XCTAssertFalse(SettingsStore.load(nil).shouldSave)
    }

    func testOneBadAccountKeepsTheOthersAndIsNotSavedOver() throws {
        let data = try stored { object in
            object["accountProfiles"] = [
                ["id": "a", "name": "Work", "agent": "claude", "home": "~/.claude-work"],
                ["id": 7, "name": "Broken"],
                ["id": "b", "name": "Old", "home": "~/.claude-old"],
            ]
            object["accountAssignments"] = [["folder": "/work", "profileId": "a"], "nonsense"]
        }
        let loaded = SettingsStore.load(data)
        XCTAssertEqual(loaded.values.accountProfiles.map(\.id), ["a", "b"])
        // Saved without an agent: taken as Claude's.
        XCTAssertEqual(loaded.values.accountProfiles.last?.agent, "claude")
        XCTAssertEqual(loaded.values.accountAssignments.map(\.folder), ["/work"])
        XCTAssertTrue(loaded.unreadable)
        XCTAssertFalse(loaded.shouldSave)
    }

    func testUnreadableValueKeepsItsDefaultAndBlocksTheSave() throws {
        // A migration that would otherwise save, plus a value from the future.
        let data = try stored { object in
            object["version"] = 1
            object["cursorStyle"] = "hexagon"
        }
        let loaded = SettingsStore.load(data)
        XCTAssertEqual(loaded.values.cursorStyle, OctetSettings().cursorStyle)
        XCTAssertTrue(loaded.unreadable)
        XCTAssertFalse(loaded.shouldSave)
        XCTAssertTrue(SettingsStore.load(Data("not json".utf8)).unreadable)
        XCTAssertFalse(SettingsStore.load(Data("not json".utf8)).shouldSave)
    }

    func testOlderSettingsKeepAChosenSystemNotificationAndSave() throws {
        let data = try stored { object in
            object["version"] = 1
            object["notifications"] = "system"
        }
        let loaded = SettingsStore.load(data)
        XCTAssertEqual(loaded.values.notifications, .system)
        XCTAssertEqual(loaded.values.version, OctetSettings.currentVersion)
        XCTAssertTrue(loaded.shouldSave)
    }

    func testLegacyKeyIsReadAndRewritten() throws {
        let data = try stored { object in
            object.removeValue(forKey: "allowNestedSessions")
            object["allowNestedHerdr"] = true
        }
        let loaded = SettingsStore.load(data)
        XCTAssertTrue(loaded.values.allowNestedSessions)
        XCTAssertTrue(loaded.shouldSave)
    }

    func testImportedThemeMissingFieldsIsFilledIn() throws {
        let data = try stored { object in
            object["importedTheme"] = ["name": "Mine", "background": "ffffff", "foreground": "111111", "ansi": ["000000"]]
        }
        let loaded = SettingsStore.load(data)
        let theme = try XCTUnwrap(loaded.values.importedTheme)
        XCTAssertEqual(theme.accent, "111111")
        XCTAssertTrue(theme.isLight)
        XCTAssertEqual(theme.ansi.count, 16)
        XCTAssertFalse(loaded.unreadable)
    }

    func testResetKeepsWhatThePersonMade() {
        var values = OctetSettings()
        values.accountProfiles = [Octet.AccountProfile(id: "a", name: "Work", agent: "claude", home: "~/.claude-work")]
        values.peersEnabled = !values.peersEnabled
        values.phoneTopic = "my-topic"
        values.fontSize = 20
        let restored = SettingsDefaults.restored(values)
        XCTAssertEqual(restored.fontSize, OctetSettings().fontSize)
        XCTAssertEqual(restored.accountProfiles, values.accountProfiles)
        XCTAssertEqual(restored.peersEnabled, values.peersEnabled)
        XCTAssertEqual(restored.phoneTopic, "my-topic")
    }

    @MainActor func testFirstRunPreselectsAnInstalledAgent() {
        XCTAssertEqual(FirstRunCenter.agentChoice(defaultAgent: "codex", installed: [.claude, .codex]), .codex)
        XCTAssertEqual(FirstRunCenter.agentChoice(defaultAgent: "codex", installed: [.claude]), .claude)
        XCTAssertEqual(FirstRunCenter.agentChoice(defaultAgent: "", installed: [.codex]), .codex)
        XCTAssertNil(FirstRunCenter.agentChoice(defaultAgent: "claude", installed: []))
    }
}
