import SwiftUI

/// One menu shortcut. OctetCommands binds its menu items from these, and the
/// Settings Keyboard page lists the same values, so the two can't drift.
struct OctetShortcut: Identifiable {
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

extension OctetShortcut {
    // Octet menu (Settings and Quit are the system's own items).
    static let settings = OctetShortcut(title: "Settings…", key: ",")
    static let marketplace = OctetShortcut(title: "Marketplace…", key: "m", modifiers: [.command, .shift])
    static let quit = OctetShortcut(title: "Quit Octet", key: "q")

    // File
    static let newTab = OctetShortcut(title: "New Tab", key: "t")
    static let newConversation = OctetShortcut(title: "New Claude Conversation", key: "n", modifiers: [.command, .shift])
    static let agents = OctetShortcut(title: "Agents Board", key: "a", modifiers: [.command, .shift])
    static let newWorkspace = OctetShortcut(title: "New Workspace", key: "n")
    static let newWindow = OctetShortcut(title: "New Window", key: "n", modifiers: [.command, .option])
    static let openFile = OctetShortcut(title: "Open File…", key: "o")
    static let openFolder = OctetShortcut(title: "Open Folder as Workspace…", key: "o", modifiers: [.command, .shift])
    static let saveFile = OctetShortcut(title: "Save", key: "s")
    static let closeTab = OctetShortcut(title: "Close Tab", key: "w")
    static let reopenClosedTab = OctetShortcut(title: "Reopen Closed Tab", key: "t", modifiers: [.command, .shift])

    // View
    static let palette = OctetShortcut(title: "Command Palette", key: "p")
    static let paletteAll = OctetShortcut(title: "Command Palette (All Commands)", key: "p", modifiers: [.command, .shift])
    static let toggleSidebar = OctetShortcut(title: "Toggle Sidebar", key: "b")
    static let visualTwin = OctetShortcut(title: "Visual Twin / Terminal", key: "v", modifiers: [.command, .shift])
    static let review = OctetShortcut(title: "Review Changes", key: "r", modifiers: [.command, .shift])
    static let broadcast = OctetShortcut(title: "Broadcast to Agents…", key: "i", modifiers: [.command, .shift])
    static let broadcastTyping = OctetShortcut(title: "Type into All Panes in Tab", key: "i", modifiers: [.command, .option])
    static let hints = OctetShortcut(title: "Open Link or File on Screen", key: "h", modifiers: [.command, .shift])
    static let increaseFontSize = OctetShortcut(title: "Increase Font Size", key: "=")
    static let decreaseFontSize = OctetShortcut(title: "Decrease Font Size", key: "-")
    static let resetFontSize = OctetShortcut(title: "Reset Font Size", key: "0")

    // Pane
    static let splitRight = OctetShortcut(title: "Split Right", key: "d")
    static let splitDown = OctetShortcut(title: "Split Down", key: "d", modifiers: [.command, .shift])
    static let toggleZoom = OctetShortcut(title: "Toggle Zoom", key: .return, modifiers: [.command, .shift])
    static let focusLeft = OctetShortcut(title: "Focus Left", key: .leftArrow, modifiers: [.command, .option])
    static let focusRight = OctetShortcut(title: "Focus Right", key: .rightArrow, modifiers: [.command, .option])
    static let focusUp = OctetShortcut(title: "Focus Up", key: .upArrow, modifiers: [.command, .option])
    static let focusDown = OctetShortcut(title: "Focus Down", key: .downArrow, modifiers: [.command, .option])

    // Navigate
    static let nextTab = OctetShortcut(title: "Next Tab", key: "]", modifiers: [.command, .shift])
    static let previousTab = OctetShortcut(title: "Previous Tab", key: "[", modifiers: [.command, .shift])
    static let nextWorkspace = OctetShortcut(title: "Next Workspace", key: .downArrow, modifiers: [.command, .control])
    static let previousWorkspace = OctetShortcut(title: "Previous Workspace", key: .upArrow, modifiers: [.command, .control])
    /// ⌘1 to ⌘8; the menu builds one item per number from `tab(_:)`.
    static let tabNumber = OctetShortcut(title: "Tab 1–8", key: "1", label: "⌘1…⌘8")
    static let lastTab = OctetShortcut(title: "Last Tab", key: "9")

    /// Navigate › Tab N for 1 to 8, and Last Tab for 9.
    static func tab(_ number: Int) -> OctetShortcut {
        number == 9 ? lastTab : OctetShortcut(title: "Tab \(number)", key: KeyEquivalent(Character("\(number)")))
    }

    // Edit, and keys the terminal handles itself
    static let copy = OctetShortcut(title: "Copy", key: "c")
    static let paste = OctetShortcut(title: "Paste", key: "v")
    static let terminalPrefix = OctetShortcut(title: "Terminal prefix", key: "b", modifiers: .control)

    /// The Keyboard page, in menu order.
    static let groups: [(title: String, shortcuts: [OctetShortcut])] = [
        ("Octet", [settings, marketplace, quit]),
        ("File", [newTab, newConversation, agents, newWorkspace, newWindow, openFile, openFolder, saveFile, closeTab, reopenClosedTab]),
        ("View", [palette, paletteAll, toggleSidebar, visualTwin, review, broadcast, broadcastTyping, hints, increaseFontSize, decreaseFontSize, resetFontSize]),
        ("Pane", [splitRight, splitDown, toggleZoom, focusLeft, focusRight, focusUp, focusDown]),
        ("Navigate", [nextTab, previousTab, nextWorkspace, previousWorkspace, tabNumber, lastTab]),
        ("Terminal", [copy, paste, terminalPrefix]),
    ]
}
