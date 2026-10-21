import XCTest

final class ShortcutBindingsTests: XCTestCase {
    private let cmdT = ShortcutBinding(key: "t")
    private let cmdShiftT = ShortcutBinding(key: "t", modifiers: [.command, .shift])

    private var table: ShortcutTable {
        ShortcutTable(
            entries: [
                .init(id: "newTab", title: "New Tab", defaultBinding: cmdT),
                .init(id: "reopen", title: "Reopen Closed Tab", defaultBinding: cmdShiftT),
                .init(id: "split", title: "Split Right", defaultBinding: ShortcutBinding(key: "d")),
            ],
            reserved: [
                .init(binding: ShortcutBinding(key: "q"), title: "Quit Octet", menu: false),
                .init(binding: ShortcutBinding(key: "f"), title: "Find…"),
            ]
        )
    }

    // MARK: Encoding

    func testEncodesModifiersInAFixedOrder() {
        XCTAssertEqual(ShortcutBinding(key: "T", modifiers: [.command, .shift, .control, .option]).encoded,
                       "ctrl+alt+shift+cmd+t")
        XCTAssertEqual(ShortcutBinding(key: "f5", modifiers: []).encoded, "f5")
    }

    func testParsesWhatItEncodesAndHandWrittenSpellings() {
        for binding in [cmdT, cmdShiftT, ShortcutBinding(key: "left", modifiers: [.command, .option]),
                        ShortcutBinding(key: "=", modifiers: .command), ShortcutBinding(key: "f12", modifiers: [])] {
            XCTAssertEqual(ShortcutBinding(encoded: binding.encoded), binding)
        }
        XCTAssertEqual(ShortcutBinding(encoded: "Command+Shift+T"), cmdShiftT)
        XCTAssertEqual(ShortcutBinding(encoded: "super+opt+return"), ShortcutBinding(key: "return", modifiers: [.command, .option]))
        XCTAssertEqual(ShortcutBinding(encoded: "cmd++"), ShortcutBinding(key: "+"))
    }

    func testRejectsDamagedValues() {
        XCTAssertNil(ShortcutBinding(encoded: ""))
        XCTAssertNil(ShortcutBinding(encoded: "cmd+"))
        XCTAssertNil(ShortcutBinding(encoded: "hyper+t"))
        XCTAssertNil(ShortcutBinding(encoded: "cmd+banana"))
    }

    func testDisplaysInMenuOrder() {
        XCTAssertEqual(ShortcutBinding(key: "down", modifiers: [.command, .control]).display, "⌃⌘↓")
        XCTAssertEqual(cmdShiftT.display, "⇧⌘T")
        XCTAssertEqual(ShortcutBinding(key: "return", modifiers: [.command, .shift]).display, "⇧⌘↩")
        XCTAssertEqual(ShortcutBinding(key: "f5", modifiers: []).display, "F5")
    }

    func testNeedsCommandControlOrOptionUnlessAFunctionKey() {
        XCTAssertTrue(cmdT.isAllowed)
        XCTAssertTrue(ShortcutBinding(key: "t", modifiers: .control).isAllowed)
        XCTAssertTrue(ShortcutBinding(key: "t", modifiers: .option).isAllowed)
        XCTAssertFalse(ShortcutBinding(key: "t", modifiers: []).isAllowed)
        XCTAssertFalse(ShortcutBinding(key: "t", modifiers: .shift).isAllowed)
        XCTAssertTrue(ShortcutBinding(key: "f5", modifiers: []).isAllowed)
        XCTAssertTrue(ShortcutBinding(key: "f19", modifiers: .shift).isAllowed)
        XCTAssertFalse(ShortcutBinding(key: "f", modifiers: []).isAllowed)
    }

    func testRecordsKeysByCodeOrUnmodifiedCharacter() {
        XCTAssertEqual(ShortcutBinding.key(keyCode: 36, unmodifiedCharacters: "\r"), "return")
        XCTAssertEqual(ShortcutBinding.key(keyCode: 96, unmodifiedCharacters: "\u{F708}"), "f5")
        XCTAssertEqual(ShortcutBinding.key(keyCode: 17, unmodifiedCharacters: "T"), "t")
        XCTAssertEqual(ShortcutBinding.key(keyCode: 24, unmodifiedCharacters: "="), "=")
        XCTAssertNil(ShortcutBinding.key(keyCode: 200, unmodifiedCharacters: "\u{F72C}"))
        XCTAssertNil(ShortcutBinding.key(keyCode: 200, unmodifiedCharacters: ""))
    }

    // MARK: Effective values

    func testOverrideElseDefaultAndEmptyIsUnassigned() {
        XCTAssertEqual(table.effective("newTab", overrides: [:]), cmdT)
        XCTAssertEqual(table.effective("newTab", overrides: ["newTab": "ctrl+cmd+t"]),
                       ShortcutBinding(key: "t", modifiers: [.command, .control]))
        XCTAssertNil(table.effective("newTab", overrides: ["newTab": ""]))
        // A damaged value falls back to the default rather than nothing.
        XCTAssertEqual(table.effective("newTab", overrides: ["newTab": "nonsense+"]), cmdT)
        XCTAssertTrue(table.isCustom("newTab", overrides: ["newTab": ""]))
        XCTAssertFalse(table.isCustom("newTab", overrides: ["newTab": "cmd+t"]))
    }

    // MARK: Assigning

    func testMostRecentBindingWinsAndTheEarlierHolderIsUnassigned() {
        let result = table.assign(cmdT, to: "split", overrides: [:])
        XCTAssertEqual(result, .assigned(overrides: ["split": "cmd+t", "newTab": ""], displaced: ["New Tab"]))
    }

    func testAssigningTheDefaultDropsTheOverride() {
        XCTAssertEqual(table.assign(cmdT, to: "newTab", overrides: ["newTab": "ctrl+cmd+t"]),
                       .assigned(overrides: [:], displaced: []))
    }

    func testUnassigning() {
        XCTAssertEqual(table.assign(nil, to: "newTab", overrides: [:]),
                       .assigned(overrides: ["newTab": ""], displaced: []))
    }

    func testRefusesReservedAndBareKeys() {
        XCTAssertEqual(table.assign(ShortcutBinding(key: "q"), to: "newTab", overrides: [:]), .reserved("Quit Octet"))
        XCTAssertEqual(table.assign(ShortcutBinding(key: "x", modifiers: .shift), to: "newTab", overrides: [:]), .notAllowed)
    }

    func testResetDropsOneOverride() {
        XCTAssertEqual(table.reset("newTab", overrides: ["newTab": "", "split": "cmd+k"]), ["split": "cmd+k"])
    }

    // MARK: Conflicts

    func testNoConflictsByDefault() {
        XCTAssertEqual(table.conflicts(overrides: [:]), [:])
    }

    func testConflictsNameTheOtherHolder() {
        // As a stored value written before a default moved onto the key would leave it.
        let conflicts = table.conflicts(overrides: ["split": "cmd+t"])
        XCTAssertEqual(conflicts, ["split": "New Tab", "newTab": "Split Right"])
        XCTAssertEqual(table.conflicts(overrides: ["split": "cmd+f"]), ["split": "Find…"])
    }

    // MARK: Terminal pass-through

    func testTriggersUseTheTerminalsNames() {
        XCTAssertEqual(cmdShiftT.terminalTriggers, ["super+shift+t"])
        XCTAssertEqual(ShortcutBinding(key: "1").terminalTriggers, ["super+1", "super+digit_1"])
        XCTAssertEqual(ShortcutBinding(key: "=").terminalTriggers, ["super+=", "super+equal", "super+plus"])
        XCTAssertEqual(ShortcutBinding(key: "[", modifiers: [.command, .shift]).terminalTriggers, ["super+shift+left_bracket"])
        XCTAssertEqual(ShortcutBinding(key: "down", modifiers: [.command, .control]).terminalTriggers, ["super+ctrl+down"])
        XCTAssertEqual(ShortcutBinding(key: "return", modifiers: [.command, .shift]).terminalTriggers, ["super+shift+enter"])
    }

    func testPassThroughFollowsTheEffectiveKeys() {
        let defaults = table.terminalPassThrough(overrides: [:])
        XCTAssertTrue(defaults.contains("keybind = super+t=unbind"))
        XCTAssertTrue(defaults.contains("keybind = super+f=unbind"))
        // Quit is the system's, not something the terminal must let through.
        XCTAssertFalse(defaults.contains("super+q"))

        let rebound = table.terminalPassThrough(overrides: ["newTab": "ctrl+cmd+y"])
        // The new key reaches the menu, and the freed one goes back to the terminal.
        XCTAssertTrue(rebound.contains("keybind = super+ctrl+y=unbind"))
        XCTAssertFalse(rebound.contains("keybind = super+t=unbind"))

        let unassigned = table.terminalPassThrough(overrides: ["newTab": ""])
        XCTAssertFalse(unassigned.contains("keybind = super+t=unbind"))
    }

    func testPassThroughListsEachTriggerOnce() {
        let lines = table.terminalPassThrough(overrides: [:], extra: ["super+t", "super+shift+w"])
            .split(separator: "\n")
        XCTAssertEqual(lines.count, Set(lines).count)
        XCTAssertTrue(lines.contains("keybind = super+shift+w=unbind"))
    }

    /// A scoped key only competes with keys in its own scope.
    func testScopesKeepTheirKeysApart() {
        let scoped = ShortcutTable(
            entries: [
                .init(id: "review", title: "Review", defaultBinding: cmdShiftT),
                .init(id: "hardReload", title: "Hard Reload", defaultBinding: cmdShiftT, scope: "browser"),
                .init(id: "reload", title: "Reload", defaultBinding: cmdT, scope: "browser"),
            ],
            reserved: [.init(binding: ShortcutBinding(key: "q"), title: "Quit Octet", menu: false)]
        )
        XCTAssertEqual(scoped.conflicts(overrides: [:]), [:])
        // Within the browser, the most recent binding still wins.
        XCTAssertEqual(scoped.assign(cmdT, to: "hardReload", overrides: [:]),
                       .assigned(overrides: ["hardReload": cmdT.encoded, "reload": ""], displaced: ["Reload"]))
        // A reserved key is refused in a scope too: it would beat the menu to it.
        XCTAssertEqual(scoped.assign(ShortcutBinding(key: "q"), to: "reload", overrides: [:]), .reserved("Quit Octet"))
        XCTAssertEqual(scoped.terminalPassThrough(overrides: [:]), "keybind = super+shift+t=unbind")
    }
}
