import AppKit
import SwiftUI

/// One menu shortcut. OctetCommands binds its menu items from these, and the
/// Settings Keyboard page lists the same values, so the two can't drift.
/// The values here are the defaults; `binding` is what applies right now,
/// after the person's own choices in Settings › Keyboard.
struct OctetShortcut: Identifiable {
    /// Stored with an override, so it stays the same when a title changes.
    let id: String
    let title: String
    let defaultBinding: ShortcutBinding
    /// Replaces the generated key label, for a row that stands for a range.
    var label: String?
    /// Why it can't be rebound, for a row the system or the terminal owns;
    /// nil for one that can.
    var fixedReason: String?

    init(_ id: String, _ title: String, key: String, modifiers: ShortcutBinding.Modifiers = .command,
         label: String? = nil, fixedReason: String? = nil) {
        self.id = id
        self.title = title
        self.defaultBinding = ShortcutBinding(key: key, modifiers: modifiers)
        self.label = label
        self.fixedReason = fixedReason
    }

    var customizable: Bool { fixedReason == nil }

    /// What the key is now: the person's override, else the default; nil
    /// when they've unassigned it.
    var binding: ShortcutBinding? {
        customizable ? Self.table.effective(id, overrides: ShortcutOverrides.values) : defaultBinding
    }

    var isCustom: Bool { customizable && Self.table.isCustom(id, overrides: ShortcutOverrides.values) }

    /// nil when unassigned, which takes the key off the menu item.
    var keyboardShortcut: KeyboardShortcut? {
        binding.map { KeyboardShortcut(Self.keyEquivalent($0.key), modifiers: Self.eventModifiers($0.modifiers)) }
    }

    /// The keys as a menu shows them, e.g. ⌃⌘↓; empty when unassigned.
    var display: String { label ?? binding?.display ?? "" }

    /// `display`, or nil when unassigned, for a label that hides its keycap then.
    var keys: String? { display.isEmpty ? nil : display }

    /// "Toggle details (⌘⇧B)", or just the text when it has no key.
    func help(_ text: String) -> String {
        display.isEmpty ? text : "\(text) (\(display))"
    }

    static func keyEquivalent(_ key: String) -> KeyEquivalent {
        switch key {
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "delete": return .delete
        case "forwarddelete": return .deleteForward
        case "escape": return .escape
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()),
               let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
                return KeyEquivalent(Character(scalar))
            }
            return KeyEquivalent(key.first ?? " ")
        }
    }

    static func eventModifiers(_ modifiers: ShortcutBinding.Modifiers) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// The overrides the menus and labels read. Mirrors
/// `OctetSettings.shortcutOverrides` so the menu bar only rebuilds when a
/// shortcut changes, not on every settings change (a slider drag).
@MainActor
final class ShortcutOverrides: ObservableObject {
    static let shared = ShortcutOverrides()
    /// Read off the main actor by `OctetShortcut.binding`; only ever
    /// written on it, by SettingsStore.
    nonisolated(unsafe) private static var current: [String: String] = [:]

    @Published private(set) var revision = 0

    nonisolated static var values: [String: String] { current }

    func update(_ overrides: [String: String]) {
        guard overrides != Self.current else { return }
        Self.current = overrides
        revision += 1
    }
}

extension OctetShortcut {
    private static let systemOwned = "Set by macOS"
    private static let terminalOwned = "Handled by the terminal"

    // Octet menu (Settings and Quit are the system's own items).
    static let settings = OctetShortcut("settings", "Settings…", key: ",", fixedReason: systemOwned)
    static let marketplace = OctetShortcut("marketplace", "Marketplace…", key: "m", modifiers: [.command, .shift])
    static let quit = OctetShortcut("quit", "Quit Octet", key: "q", fixedReason: systemOwned)

    // File
    static let newTab = OctetShortcut("newTab", "New Tab", key: "t")
    static let newConversation = OctetShortcut("newConversation", "New Claude Conversation", key: "n", modifiers: [.command, .shift])
    static let agents = OctetShortcut("agents", "Agents", key: "a", modifiers: [.command, .shift])
    static let newWorkspace = OctetShortcut("newWorkspace", "New Workspace", key: "n")
    static let newWindow = OctetShortcut("newWindow", "New Window", key: "n", modifiers: [.command, .option])
    static let openFile = OctetShortcut("openFile", "Open File…", key: "o")
    static let openFolder = OctetShortcut("openFolder", "Open Folder as Workspace…", key: "o", modifiers: [.command, .shift])
    static let saveFile = OctetShortcut("saveFile", "Save", key: "s")
    static let closeTab = OctetShortcut("closeTab", "Close Tab", key: "w")
    static let reopenClosedTab = OctetShortcut("reopenClosedTab", "Reopen Closed Tab", key: "t", modifiers: [.command, .shift])

    // View
    static let palette = OctetShortcut("palette", "Command Palette", key: "p")
    static let paletteAll = OctetShortcut("paletteAll", "Command Palette (All Commands)", key: "p", modifiers: [.command, .shift])
    static let toggleSidebar = OctetShortcut("toggleSidebar", "Toggle Sidebar", key: "b")
    static let togglePanel = OctetShortcut("togglePanel", "Toggle Panel", key: "b", modifiers: [.command, .option])
    static let terminalDrawer = OctetShortcut("terminalDrawer", "Toggle Terminal Drawer", key: "j")
    static let details = OctetShortcut("details", "Toggle Details", key: "b", modifiers: [.command, .shift])
    static let searchWorkspaces = OctetShortcut("searchWorkspaces", "Search Workspaces", key: "f", modifiers: [.command, .shift])
    /// ⌥⌘F: ⌘⇧F, T3 Code's key for it, is Search Workspaces here.
    static let searchInProject = OctetShortcut("searchInProject", "Search in Project…", key: "f", modifiers: [.command, .option])
    static let visualTwin = OctetShortcut("visualTwin", "Visual Twin / Terminal", key: "v", modifiers: [.command, .shift])
    static let review = OctetShortcut("review", "Review Changes", key: "r", modifiers: [.command, .shift])
    static let broadcast = OctetShortcut("broadcast", "Broadcast to Agents…", key: "i", modifiers: [.command, .shift])
    static let broadcastTyping = OctetShortcut("broadcastTyping", "Type into All Panes in Tab", key: "i", modifiers: [.command, .option])
    static let hints = OctetShortcut("hints", "Open Link or File on Screen", key: "h", modifiers: [.command, .shift])
    static let increaseFontSize = OctetShortcut("increaseFontSize", "Increase Font Size", key: "=")
    static let decreaseFontSize = OctetShortcut("decreaseFontSize", "Decrease Font Size", key: "-")
    static let resetFontSize = OctetShortcut("resetFontSize", "Reset Font Size", key: "0")

    // Pane
    static let splitRight = OctetShortcut("splitRight", "Split Right", key: "d")
    static let splitDown = OctetShortcut("splitDown", "Split Down", key: "d", modifiers: [.command, .shift])
    static let toggleZoom = OctetShortcut("toggleZoom", "Toggle Zoom", key: "return", modifiers: [.command, .shift])
    static let focusLeft = OctetShortcut("focusLeft", "Focus Left", key: "left", modifiers: [.command, .option])
    static let focusRight = OctetShortcut("focusRight", "Focus Right", key: "right", modifiers: [.command, .option])
    static let focusUp = OctetShortcut("focusUp", "Focus Up", key: "up", modifiers: [.command, .option])
    static let focusDown = OctetShortcut("focusDown", "Focus Down", key: "down", modifiers: [.command, .option])

    // Navigate
    static let nextTab = OctetShortcut("nextTab", "Next Tab", key: "]", modifiers: [.command, .shift])
    static let previousTab = OctetShortcut("previousTab", "Previous Tab", key: "[", modifiers: [.command, .shift])
    static let nextWorkspace = OctetShortcut("nextWorkspace", "Next Workspace", key: "down", modifiers: [.command, .control])
    static let previousWorkspace = OctetShortcut("previousWorkspace", "Previous Workspace", key: "up", modifiers: [.command, .control])
    /// ⌘1 to ⌘8; the menu builds one item per number from `tab(_:)`. One
    /// row stands for eight keys, so it isn't rebound from a single recording.
    static let tabNumber = OctetShortcut("tabNumber", "Tab 1–8", key: "1", label: "⌘1…⌘8",
                                         fixedReason: "⌘1 to ⌘8 go to that tab")
    static let lastTab = OctetShortcut("lastTab", "Last Tab", key: "9")

    /// Navigate › Tab N for 1 to 8, and Last Tab for 9.
    static func tab(_ number: Int) -> OctetShortcut {
        number == 9 ? lastTab : OctetShortcut("tab\(number)", "Tab \(number)", key: "\(number)", fixedReason: tabNumber.fixedReason)
    }

    // Edit, and keys the terminal handles itself
    static let copy = OctetShortcut("copy", "Copy", key: "c", fixedReason: terminalOwned)
    static let paste = OctetShortcut("paste", "Paste", key: "v", fixedReason: terminalOwned)
    static let terminalPrefix = OctetShortcut("terminalPrefix", "Terminal prefix", key: "b", modifiers: .control,
                                              fixedReason: terminalOwned)

    /// The Keyboard page, in menu order.
    static let groups: [(title: String, shortcuts: [OctetShortcut])] = [
        ("Octet", [settings, marketplace, quit]),
        ("File", [newTab, newConversation, agents, newWorkspace, newWindow, openFile, openFolder, saveFile, closeTab, reopenClosedTab]),
        ("View", [palette, paletteAll, toggleSidebar, togglePanel, terminalDrawer, details, searchWorkspaces, searchInProject, visualTwin, review, broadcast, broadcastTyping, hints, increaseFontSize, decreaseFontSize, resetFontSize]),
        ("Pane", [splitRight, splitDown, toggleZoom, focusLeft, focusRight, focusUp, focusDown]),
        ("Navigate", [nextTab, previousTab, nextWorkspace, previousWorkspace, tabNumber, lastTab]),
        ("Terminal", [copy, paste, terminalPrefix]),
    ]

    static let all: [OctetShortcut] = groups.flatMap(\.shortcuts)

    static func named(_ id: String) -> OctetShortcut? { all.first { $0.id == id } }

    /// Menu items with fixed keys that aren't on the Keyboard page; a
    /// recording can't take their keys, and the terminal lets them through.
    private static let fixedMenuKeys: [ShortcutTable.Reserved] = [
        .init(binding: ShortcutBinding(key: "f"), title: "Find…"),
        .init(binding: ShortcutBinding(key: "g"), title: "Find Next"),
        .init(binding: ShortcutBinding(key: "g", modifiers: [.command, .shift]), title: "Find Previous"),
        .init(binding: ShortcutBinding(key: "s", modifiers: [.command, .option]), title: "Save All"),
    ]

    /// Every rebindable row, plus what holds the keys that aren't.
    static let table = ShortcutTable(
        entries: all.filter(\.customizable).map { .init(id: $0.id, title: $0.title, defaultBinding: $0.defaultBinding) },
        reserved: all.filter { !$0.customizable && $0.id != tabNumber.id }.map {
            // Settings and Quit reach the system's menu items anyway, and
            // Copy, Paste and the prefix are the terminal's own keys.
            .init(binding: $0.defaultBinding, title: $0.title, menu: false)
        }
        + (1...8).map { .init(binding: tab($0).defaultBinding, title: tab($0).title) }
        + fixedMenuKeys
    )

    /// Keys the terminal has always been told to leave alone that no menu
    /// item here binds: its close-window key.
    private static let otherUnbinds = ["super+shift+w"]

    /// The terminal config lines that hand Octet's current menu keys to the
    /// menus: see `ShortcutTable.terminalPassThrough`.
    static var terminalPassThrough: String {
        table.terminalPassThrough(overrides: ShortcutOverrides.values, extra: otherUnbinds)
    }
}
