import SwiftUI

/// One menu shortcut. HerdCommands binds its menu items from these, and the
/// Settings Keyboard page lists the same values, so the two can't drift.
struct HerdShortcut: Identifiable {
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    /// Replaces the generated key label, for a row that stands for a range.
    var label: String?

    var id: String { title }
    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    /// The keys as a menu shows them, e.g. ⌃⌘↓.
    var display: String { label ?? Self.symbols(modifiers) + Self.symbol(key) }

    private static func symbols(_ modifiers: EventModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    private static func symbol(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: return "↩"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .space: return "Space"
        case .delete: return "⌫"
        default: return String(key.character).uppercased()
        }
    }
}

extension HerdShortcut {
    // Herd menu (Settings and Quit are the system's own items).
    static let settings = HerdShortcut(title: "Settings…", key: ",")
    static let marketplace = HerdShortcut(title: "Marketplace…", key: "m", modifiers: [.command, .shift])
    static let quit = HerdShortcut(title: "Quit Herd", key: "q")

    // File
    static let newTab = HerdShortcut(title: "New Tab", key: "t")
    static let newConversation = HerdShortcut(title: "New Claude Conversation", key: "n", modifiers: [.command, .shift])
    static let agents = HerdShortcut(title: "Agents Board", key: "a", modifiers: [.command, .shift])
    static let newWorkspace = HerdShortcut(title: "New Workspace", key: "n")
    static let newWindow = HerdShortcut(title: "New Window", key: "n", modifiers: [.command, .option])
    static let openFolder = HerdShortcut(title: "Open Folder as Workspace…", key: "o")
    static let closeTab = HerdShortcut(title: "Close Tab", key: "w")

    // View
    static let palette = HerdShortcut(title: "Command Palette", key: "p")
    static let paletteAll = HerdShortcut(title: "Command Palette (All Commands)", key: "p", modifiers: [.command, .shift])
    static let toggleSidebar = HerdShortcut(title: "Toggle Sidebar", key: "b")
    static let increaseFontSize = HerdShortcut(title: "Increase Font Size", key: "=")
    static let decreaseFontSize = HerdShortcut(title: "Decrease Font Size", key: "-")
    static let resetFontSize = HerdShortcut(title: "Reset Font Size", key: "0")

    // Pane
    static let splitRight = HerdShortcut(title: "Split Right", key: "d")
    static let splitDown = HerdShortcut(title: "Split Down", key: "d", modifiers: [.command, .shift])
    static let toggleZoom = HerdShortcut(title: "Toggle Zoom", key: .return, modifiers: [.command, .shift])
    static let focusLeft = HerdShortcut(title: "Focus Left", key: .leftArrow, modifiers: [.command, .option])
    static let focusRight = HerdShortcut(title: "Focus Right", key: .rightArrow, modifiers: [.command, .option])
    static let focusUp = HerdShortcut(title: "Focus Up", key: .upArrow, modifiers: [.command, .option])
    static let focusDown = HerdShortcut(title: "Focus Down", key: .downArrow, modifiers: [.command, .option])

    // Navigate
    static let nextTab = HerdShortcut(title: "Next Tab", key: "]", modifiers: [.command, .shift])
    static let previousTab = HerdShortcut(title: "Previous Tab", key: "[", modifiers: [.command, .shift])
    static let nextWorkspace = HerdShortcut(title: "Next Workspace", key: .downArrow, modifiers: [.command, .control])
    static let previousWorkspace = HerdShortcut(title: "Previous Workspace", key: .upArrow, modifiers: [.command, .control])
    /// ⌘1 to ⌘8; the menu builds one item per number from `tab(_:)`.
    static let tabNumber = HerdShortcut(title: "Tab 1–8", key: "1", label: "⌘1…⌘8")
    static let lastTab = HerdShortcut(title: "Last Tab", key: "9")

    /// Navigate › Tab N for 1 to 8, and Last Tab for 9.
    static func tab(_ number: Int) -> HerdShortcut {
        number == 9 ? lastTab : HerdShortcut(title: "Tab \(number)", key: KeyEquivalent(Character("\(number)")))
    }

    // Edit, and keys the terminal handles itself
    static let copy = HerdShortcut(title: "Copy", key: "c")
    static let paste = HerdShortcut(title: "Paste", key: "v")
    static let terminalPrefix = HerdShortcut(title: "Terminal prefix", key: "b", modifiers: .control)

    /// The Keyboard page, in menu order.
    static let groups: [(title: String, shortcuts: [HerdShortcut])] = [
        ("Herd", [settings, marketplace, quit]),
        ("File", [newTab, newConversation, agents, newWorkspace, newWindow, openFolder, closeTab]),
        ("View", [palette, paletteAll, toggleSidebar, increaseFontSize, decreaseFontSize, resetFontSize]),
        ("Pane", [splitRight, splitDown, toggleZoom, focusLeft, focusRight, focusUp, focusDown]),
        ("Navigate", [nextTab, previousTab, nextWorkspace, previousWorkspace, tabNumber, lastTab]),
        ("Terminal", [copy, paste, terminalPrefix]),
    ]
}
