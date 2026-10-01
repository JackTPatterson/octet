import AppKit
import Combine
import SwiftUI

/// The Peer menu in the menu bar, beside Window, while Other Macs is on:
/// the Peer window, each paired Mac's agents and a new task there, pairing,
/// and the settings. Built in AppKit because SwiftUI's menus can't come and
/// go with a setting.
@MainActor
final class PeerMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = PeerMenu()

    private let item = NSMenuItem(title: "Peer", action: nil, keyEquivalent: "")
    private let menu = NSMenu(title: "Peer")
    private var observers: [Any] = []

    func start() {
        guard observers.isEmpty else { return }
        menu.delegate = self
        item.submenu = menu
        // SwiftUI rebuilds the main menu now and then; put the item back.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { PeerMenu.shared.place() } })
        observers.append(SettingsStore.shared.$values.map(\.peersEnabled).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { _ in PeerMenu.shared.place() })
        place()
    }

    /// In the menu bar just before Window while Other Macs is on; gone otherwise.
    private func place() {
        guard let main = NSApp.mainMenu else { return }
        let wanted = SettingsStore.shared.values.peersEnabled
        let index = main.items.firstIndex(of: item)
        if !wanted {
            if let index { main.removeItem(at: index) }
            return
        }
        guard index == nil else { return }
        let window = main.items.firstIndex { $0.submenu == NSApp.windowsMenu || $0.title == "Window" }
        main.insertItem(item, at: window ?? max(main.items.count - 1, 0))
    }

    /// Rebuilt each time it opens, from the Macs paired now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let center = PeerCenter.shared
        let open = NSMenuItem(title: "Open Peer", action: #selector(openPeer), keyEquivalent: "e")
        open.keyEquivalentModifierMask = [.command, .shift]
        add(open, to: menu)
        menu.addItem(.separator())
        if center.paired.isEmpty {
            let none = NSMenuItem(title: "No Macs Paired", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for peer in center.paired {
            let online = center.online.contains(peer.device)
            let machine = NSMenuItem(title: peer.name, action: nil, keyEquivalent: "")
            machine.image = NSImage(systemSymbolName: online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
                                    accessibilityDescription: online ? "Connected" : "Not connected")
            let submenu = NSMenu(title: peer.name)
            let agents = NSMenuItem(title: "Show Agents", action: #selector(showMachine(_:)), keyEquivalent: "")
            agents.representedObject = peer.name
            add(agents, to: submenu)
            let task = NSMenuItem(title: "New Task…", action: #selector(newTask(_:)), keyEquivalent: "")
            task.representedObject = peer.name
            task.isEnabled = online
            add(task, to: submenu)
            if !online {
                submenu.addItem(.separator())
                let note = NSMenuItem(title: "Not connected", action: nil, keyEquivalent: "")
                note.isEnabled = false
                submenu.addItem(note)
            }
            machine.submenu = submenu
            menu.addItem(machine)
        }
        menu.addItem(.separator())
        add(NSMenuItem(title: "Pair a Mac…", action: #selector(openPeer), keyEquivalent: ""), to: menu)
        add(NSMenuItem(title: "Other Macs Settings…", action: #selector(openSettings), keyEquivalent: ""), to: menu)
    }

    private func add(_ item: NSMenuItem, to menu: NSMenu) {
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPeer() { PeerWindow.show() }

    @objc private func showMachine(_ sender: NSMenuItem) {
        PeerPanelModel.shared.focusMachine = sender.representedObject as? String
        PeerWindow.show()
    }

    @objc private func newTask(_ sender: NSMenuItem) {
        PeerPanelModel.shared.startTaskOn = sender.representedObject as? String
        PeerWindow.show()
    }

    @objc private func openSettings() { PluginSettingsOpener.show(pluginId: "other-macs") }

    // Only items with a target and no explicit disabling stay enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.isEnabled }
}

/// The window the Peer menu opens: the panel of paired Macs, their agents,
/// tasks and pairing.
@MainActor
enum PeerWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            // The folder in front, offered as where a new task runs.
            let front = WindowRegistry.shared.key.flatMap { context in
                context.focusedWorkspace.flatMap { context.store.snapshot.directory(ofWorkspace: $0.workspaceId) }
            }
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                   backing: .buffered, defer: false)
            created.title = "Peer"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: PeerPanel(folder: front))
            created.setFrameAutosaveName("OctetPeerWindow")
            if created.frame.origin == .zero { created.center() }
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
