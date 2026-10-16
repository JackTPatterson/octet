import XCTest
@testable import Octet

/// Octet's own shortcut table, against the terminal engine it configures.
/// Shared types are qualified with `Octet.` because this bundle also
/// compiles Shared for itself.
final class OctetShortcutsTests: XCTestCase {
    /// What the terminal was told to let through before shortcuts could be
    /// rebound. With nothing rebound, every one of these must still be.
    private let legacyUnbinds = [
        "super+t", "super+w", "super+n", "super+b", "super+alt+b", "super+shift+b", "super+j", "super+p",
        "super+f", "super+g", "super+shift+g", "super+shift+p", "super+shift+r", "super+shift+i",
        "super+shift+h", "super+alt+i", "super+o", "super+shift+o", "super+s", "super+alt+s", "super+d",
        "super+shift+d", "super+shift+enter", "super+alt+left", "super+alt+right", "super+alt+up",
        "super+alt+down", "super+shift+left_bracket", "super+shift+right_bracket", "ctrl+super+up",
        "ctrl+super+down", "super+shift+w", "super+shift+t", "super+digit_1", "super+digit_2",
        "super+digit_3", "super+digit_4", "super+digit_5", "super+digit_6", "super+digit_7",
        "super+digit_8", "super+digit_9", "super+=", "super+equal", "super+plus", "super+-",
        "super+minus", "super+0", "super+digit_0",
    ]

    /// "ctrl+super+up" and "super+ctrl+up" are the same trigger.
    private func normalized(_ trigger: String) -> String {
        var parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = parts.removeLast()
        return (parts.sorted() + [key]).joined(separator: "+")
    }

    private func triggers(_ config: String) -> Set<String> {
        Set(config.split(separator: "\n").map { line in
            normalized(String(line.dropFirst("keybind = ".count).dropLast("=unbind".count)))
        })
    }

    func testDefaultsStillLetThroughEveryKeyTheyUsedTo() {
        let derived = triggers(Octet.OctetShortcut.table.terminalPassThrough(overrides: [:], extra: ["super+shift+w"]))
        let missing = legacyUnbinds.map(normalized).filter { !derived.contains($0) }
        XCTAssertEqual(missing, [])
    }

    func testIdsAreUniqueAndDefaultsDontConflict() {
        let ids = Octet.OctetShortcut.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Octet.OctetShortcut.table.conflicts(overrides: [:]), [:])
        for shortcut in Octet.OctetShortcut.all where shortcut.customizable {
            XCTAssertTrue(shortcut.defaultBinding.isAllowed, shortcut.title)
        }
    }

    func testRebindableRowsExcludeTheSystemsAndTheTerminals() {
        let fixed = Set(Octet.OctetShortcut.all.filter { !$0.customizable }.map(\.id))
        XCTAssertEqual(fixed, ["settings", "quit", "tabNumber", "copy", "paste", "terminalPrefix"])
        // ⌘1 can't be taken from Tab 1 by a recording.
        XCTAssertEqual(Octet.OctetShortcut.table.assign(Octet.ShortcutBinding(key: "1"), to: "newTab", overrides: [:]),
                       .reserved("Tab 1"))
    }

    /// Every key name the pass-through can produce is one the terminal
    /// engine accepts; a rejected line would show as a settings problem.
    func testTerminalAcceptsEveryTriggerForm() {
        let keys = ["a", "1", "0", "=", "-", "[", "]", ",", ".", "/", ";", "'", "`", "\\"]
            + Array(Octet.ShortcutBinding.namedKeys)
        let entries = keys.enumerated().map { index, key in
            Octet.ShortcutTable.Entry(id: "k\(index)", title: key,
                                      defaultBinding: Octet.ShortcutBinding(key: key, modifiers: [.command, .control, .option, .shift]))
        }
        let config = Octet.ShortcutTable(entries: entries, reserved: []).terminalPassThrough(overrides: [:])
        let parsed = TerminalEngine.Config(overrides: config)
        XCTAssertNotNil(parsed.config)
        XCTAssertEqual(parsed.errors, [])
        // The check can fail: a name the engine doesn't know is reported.
        XCTAssertFalse(TerminalEngine.Config(overrides: "keybind = super+no_such_key=unbind").errors.isEmpty)
    }
}
