import AppKit
import SwiftUI

/// The Peer menu in the menu bar, beside Window, while Other Macs is on:
/// the Peer window, each paired Mac with its status and its agents and a
/// new task there, pairing, and the settings. Declared in SwiftUI, so it
/// stays put as the menu bar updates, rather than being put back after each
/// update.
struct PeerCommands: Commands {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: PeerCenter
    @ObservedObject var model = PeerPanelModel.shared

    var body: some Commands {
        // Only while Other Macs is on.
        if settings.values.peersEnabled {
            CommandMenu("Peer") {
                Button(OctetShortcut.openPeer.title) { PeerWindow.show() }
                    .keyboardShortcut(OctetShortcut.openPeer.keyboardShortcut)
                Divider()
                if center.paired.isEmpty {
                    Text("No Other Macs Paired")
                }
                ForEach(center.paired) { peer in
                    let state = PeerMachineState(peer, center: center, model: model)
                    // The status as the menu item's second line, as the
                    // Settings row and the Peer window say it.
                    Menu {
                        Button("Show Agents") {
                            PeerPanelModel.shared.focusMachine = peer.name
                            PeerWindow.show()
                        }
                        Button("New Task on \(peer.name)…") {
                            PeerPanelModel.shared.startTaskOn = peer.name
                            PeerWindow.show()
                        }
                        .disabled(!state.online)
                    } label: {
                        Text(peer.name)
                        Text(state.status().text)
                    }
                }
                Divider()
                Button("Pair a Mac…") { PeerPairingModel.shared.present() }
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
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "Peer"
            // The panel draws its own header under a clear title bar.
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: PeerPanel(folder: front)
                .background(Theme.chrome.ignoresSafeArea()))
            // The window keeps the size it's given (or was left at), rather
            // than shrinking to the panel's smallest.
            hosting.sizingOptions = []
            created.contentViewController = hosting
            created.setContentSize(NSSize(width: 460, height: 620))
            created.setFrameAutosaveName("OctetPeerWindow")
            if created.frame.origin == .zero { created.center() }
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
