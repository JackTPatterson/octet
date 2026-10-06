import AppKit
import SwiftUI

/// The Peer menu in the menu bar, beside Window, while Other Macs is on:
/// the Peer window, each paired Mac's agents and a new task there, pairing,
/// and the settings. Declared in SwiftUI, so it stays put as the menu bar
/// updates, rather than being put back after each update.
struct PeerCommands: Commands {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: PeerCenter

    var body: some Commands {
        // Only while Other Macs is on.
        if settings.values.peersEnabled {
            CommandMenu("Peer") {
                Button("Open Peer") { PeerWindow.show() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                if center.paired.isEmpty {
                    Text("No Macs Paired")
                }
                ForEach(center.paired) { peer in
                    let online = center.online.contains(peer.device)
                    Menu(online ? peer.name : "\(peer.name) (not connected)") {
                        Button("Show Agents") {
                            PeerPanelModel.shared.focusMachine = peer.name
                            PeerWindow.show()
                        }
                        Button("New Task…") {
                            PeerPanelModel.shared.startTaskOn = peer.name
                            PeerWindow.show()
                        }
                        .disabled(!online)
                    }
                }
                Divider()
                Button("Pair a Mac…") { PeerWindow.show() }
                Button("Other Macs Settings…") { PluginSettingsOpener.show(pluginId: "other-macs") }
            }
        }
    }
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
