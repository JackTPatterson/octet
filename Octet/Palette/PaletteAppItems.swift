import SwiftUI

/// Palette rows for what the menu bar offers and the palette didn't: the
/// app's own pages, a conversation with each engine, font size, updates and
/// the cheat sheet. Titles and keys come from `OctetShortcut`, so a row reads
/// exactly as its menu item does.
@MainActor
extension PaletteCatalog {
    static func appItems(window: WindowContext) -> [PaletteItem] {
        func action(_ shortcut: OctetShortcut, id: String? = nil, _ symbol: String,
                    keywords: [String] = [], _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: "action.\(id ?? shortcut.id)", kind: .action, title: shortcut.title, keywords: keywords,
                        shortcut: shortcut.keys, icon: .symbol(symbol), effect: .run(run))
        }
        func plain(_ id: String, _ title: String, _ symbol: String, keywords: [String] = [],
                   _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: "action.\(id)", kind: .action, title: title, keywords: keywords,
                        icon: .symbol(symbol), effect: .run(run))
        }

        var items: [PaletteItem] = [
            action(.settings, "gearshape", keywords: ["preferences", "options", "configure"]) { SettingsOpener.open() },
            action(.marketplace, "square.and.arrow.down", keywords: ["mcp", "plugins", "skills", "prompts", "install"]) {
                MarketplaceWindow.open()
            },
            action(.keyboardShortcuts, "keyboard", keywords: ["keys", "keybindings", "hotkeys", "cheat sheet", "help"]) {
                window.ui.shortcutsVisible = true
            },
            action(.searchWorkspaces, "magnifyingglass", keywords: ["find", "filter", "sidebar"]) {
                window.ui.sidebarVisible = true
                // After the sidebar is back, so the field exists to focus.
                DispatchQueue.main.async { window.ui.sidebarSearchRequest += 1 }
            },
            action(.increaseFontSize, "textformat.size.larger", keywords: ["font", "bigger", "zoom in", "text"]) {
                MainWindow.perform { SettingsStore.shared.adjustFontSize(by: 1) }
            },
            action(.decreaseFontSize, "textformat.size.smaller", keywords: ["font", "smaller", "zoom out", "text"]) {
                MainWindow.perform { SettingsStore.shared.adjustFontSize(by: -1) }
            },
            action(.resetFontSize, "textformat.size", keywords: ["font", "default", "actual size", "text"]) {
                MainWindow.perform { SettingsStore.shared.resetFontSize() }
            },
            plain("checkForUpdates", "Check for Updates…", "arrow.down.circle", keywords: ["update", "upgrade", "version", "sparkle"]) {
                AppUpdateStatus.shared.check?()
            },
        ]

        // One per engine, as File › New … Conversation lists them. The
        // shortcut's own row starts the default agent (Settings › Agents).
        let preferred = AgentSession.Engine.preferred
        items.append(PaletteItem(
            id: "action.newConversation", kind: .action, title: OctetShortcut.newConversation.title,
            subtitle: "With \(preferred.displayName), the default agent",
            keywords: ["chat", "agent", "new", preferred.rawValue],
            shortcut: OctetShortcut.newConversation.keys,
            icon: AgentBrand.forAgent(preferred.agent).map { .agent($0) } ?? .symbol("tool.agent"),
            effect: .run { window.newConversation() }
        ))
        for engine in AgentSession.Engine.offered {
            let brand = AgentBrand.forAgent(engine.agent)
            items.append(PaletteItem(
                id: "action.newConversation.\(engine.rawValue)", kind: .action,
                title: "New \(engine.displayName) Conversation",
                keywords: ["chat", "agent", "new", engine.rawValue],
                icon: brand.map { .agent($0) } ?? .symbol("tool.agent"),
                effect: .run { window.newConversation(engine: engine) }
            ))
        }

        let target = window.mode.other
        items.append(PaletteItem(
            id: "action.mode.\(target.rawValue)", kind: .action, title: "Switch to \(target.title) Mode",
            subtitle: target == .workspace ? "Show the terminal in this window" : "Chat with no terminal",
            keywords: ["chat", "workspace", "terminal", "mode", "splash", "default"],
            icon: .symbol(target == .workspace ? "terminal" : "bubble.left"),
            effect: .run { window.mode = target }
        ))

        // The menu's Broadcast: who it can reach right now, to pick from.
        items.append(PaletteItem(
            id: "action.broadcastMenu", kind: .action, title: OctetShortcut.broadcast.title,
            keywords: ["send", "all", "prompt", "agents", "multiple"],
            shortcut: OctetShortcut.broadcast.keys, icon: .symbol("tool.agent"),
            effect: .list(title: "Broadcast to") { deliver in
                let targets = actions(window: window).filter { $0.id.hasPrefix("action.broadcast.") }
                deliver(targets.isEmpty
                    ? [PaletteItem(id: "broadcast.none", kind: .action, title: "Nothing to broadcast to",
                                   subtitle: "Start an agent, or split the tab into panes.",
                                   icon: .symbol("tool.agent"), effect: .run {})]
                    : targets)
            }
        ))

        if SettingsStore.shared.values.peersEnabled {
            items.append(action(.openPeer, "desktopcomputer", keywords: ["other macs", "peer", "remote", "paired"]) {
                PeerWindow.show()
            })
        }
        return items
    }
}
