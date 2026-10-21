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
        XCTAssertEqual(fixed, ["settings", "quit", "tabNumber", "copy", "paste",
                               "drawerSplitRight", "drawerSplitDown", "drawerNewTerminal", "drawerClose"])
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

    /// Keys a part of the window handles itself (the browser's ⌘R, the
    /// drawer's ⌘D) are listed, but never handed to the terminal's
    /// pass-through, and their echoes of menu keys don't count as conflicts.
    func testScopedKeysShareMenuKeysWithoutConflict() {
        XCTAssertEqual(Octet.OctetShortcut.browserHardReload.defaultBinding, Octet.OctetShortcut.review.defaultBinding)
        XCTAssertNil(Octet.OctetShortcut.table.conflicts(overrides: [:])["browserHardReload"])
        // Rebinding the menu's Review to ⌘R leaves the browser's Reload alone.
        guard case .assigned(let overrides, let displaced) = Octet.OctetShortcut.table.assign(
            Octet.ShortcutBinding(key: "r"), to: "review", overrides: [:]) else { return XCTFail() }
        XCTAssertEqual(displaced, [])
        XCTAssertEqual(Octet.OctetShortcut.table.effective("browserReload", overrides: overrides), Octet.ShortcutBinding(key: "r"))
        // Nothing in the pass-through is a key only a scope uses.
        let passThrough = triggers(Octet.OctetShortcut.table.terminalPassThrough(overrides: [:]))
        XCTAssertFalse(passThrough.contains(normalized("super+period")))
        XCTAssertFalse(passThrough.contains(normalized("super+r")))
    }

    func testEveryGroupIsFoundBySearch() {
        XCTAssertEqual(Octet.OctetShortcut.groups(matching: "").count, Octet.OctetShortcut.groups.count)
        XCTAssertEqual(Octet.OctetShortcut.groups(matching: "browser").first?.shortcuts.count, 6)
        for spelling in ["⇧⌘P", "⌘⇧P", "⌘⇧p"] {
            let byKeys = Octet.OctetShortcut.groups(matching: spelling).flatMap(\.shortcuts).map(\.id)
            XCTAssertEqual(byKeys, ["paletteAll"], spelling)
        }
        XCTAssertTrue(Octet.OctetShortcut.groups(matching: "⌘⇧").flatMap(\.shortcuts).contains { $0.id == "review" })
    }

    func testTabNumbersStopAtEightAndNineIsTheLast() {
        XCTAssertEqual((0..<3).map { Octet.TabJump.number(index: $0, count: 3) }, [1, 2, 3])
        XCTAssertEqual(Octet.TabJump.number(index: 7, count: 12), 8)
        XCTAssertNil(Octet.TabJump.number(index: 8, count: 12))
        XCTAssertEqual(Octet.TabJump.number(index: 11, count: 12), 9)
        XCTAssertEqual(Octet.TabJump.number(index: 8, count: 9), 9)
        XCTAssertNil(Octet.TabJump.number(index: 3, count: 3))
        // The ninth is Last Tab, so its label follows a rebind of that.
        XCTAssertEqual(Octet.TabJump.shortcut(index: 11, count: 12)?.id, "lastTab")
    }

    func testKeyCombosSplitIntoCapsAndReadAloud() {
        XCTAssertEqual(Octet.KeyCombo.caps("⌃⌘↓"), ["⌃", "⌘", "↓"])
        XCTAssertEqual(Octet.KeyCombo.caps("⌘1…⌘8"), ["⌘1…⌘8"])
        XCTAssertEqual(Octet.KeyCombo.caps("esc"), ["esc"])
        XCTAssertEqual(Octet.KeyCombo.spoken("⇧⌘P"), "Shift Command P")
    }

    @MainActor
    func testPaletteDuplicateIdsAreFound() {
        XCTAssertEqual(Octet.PaletteModel.duplicateIds(["a", "b", "a", "c", "b", "a"]), ["a", "b"])
        XCTAssertEqual(Octet.PaletteModel.duplicateIds(["a", "b"]), [])
    }

    /// A repeated id is shown once, the first row kept, in the main list
    /// and in a sub-list; results are there without a redraw asking.
    @MainActor
    func testPaletteShowsEachIdOnce() {
        func item(_ id: String, _ title: String) -> Octet.PaletteItem {
            Octet.PaletteItem(id: id, kind: Octet.PaletteKind.plugin, title: title, icon: .symbol("x"), effect: .run {})
        }
        let model = Octet.PaletteModel()
        model.reload(items: [item("test.dup", "First"), item("test.other", "Other"), item("test.dup", "Second")])
        let dups = model.results.filter { $0.item.id == "test.dup" }
        XCTAssertEqual(dups.count, 1)
        XCTAssertEqual(dups.first?.item.title, "First")
        model.query = "oth"
        XCTAssertEqual(model.results.map(\.item.id), ["test.other"])
        model.subList = ("Logs", [item("log.1", "One"), item("log.1", "Again"), item("log.2", "Two")])
        model.query = ""
        XCTAssertEqual(model.results.map(\.item.title), ["One", "Two"])
    }

    /// Every fixed palette action has an id of its own: a second row with
    /// the same id is silently dropped by the palette.
    @MainActor
    func testPaletteActionIdsAreUnique() {
        let store = SessionStore(client: Octet.EngineClient(socketPath: "/tmp/octet-unused-palette-test.sock"))
        let window = WindowContext(spec: OctetWindowSpec(), store: store)
        let ids = Octet.PaletteCatalog.actions(window: window).map(\.id)
        XCTAssertEqual(Octet.PaletteModel.duplicateIds(ids), [])
        XCTAssertTrue(ids.contains("action.pullRequests"))
        XCTAssertTrue(ids.contains("action.pullRequestsPlane"))
        XCTAssertTrue(ids.contains("action.keyboardShortcuts"))
    }

    func testTipsFillInTheirKeys() {
        let tip = Octet.Tip(id: "t", title: "T", body: "{splitRight} splits; {gone} doesn't; {open")
        XCTAssertEqual(tip.text { $0 == "splitRight" ? "⌘D" : nil }, "⌘D splits; its shortcut doesn't; {open")
        // Every placeholder in the real deck names a shortcut that exists.
        for tip in Octet.Tips.all {
            XCTAssertFalse(tip.text { Octet.OctetShortcut.named($0)?.keys }.contains("its shortcut"), tip.id)
            if !tip.shortcut.isEmpty { XCTAssertNotNil(Octet.OctetShortcut.named(tip.shortcut), tip.id) }
        }
    }
}
