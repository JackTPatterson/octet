import AppKit
import SwiftUI

/// What a program in a pane asks of the person: the bell (BEL) and desktop
/// notifications (OSC 9 and 777), as other terminals honour them.
@MainActor
enum TerminalAttention {
    /// The Dock icon bounces once when Octet isn't in front; in front, the
    /// system alert sound for the pane you're in, a notice for another.
    static func bell(from paneId: String? = nil, store: SessionStore? = nil) {
        guard NSApp.isActive else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        if let paneId, let store, paneId != store.keyPaneId {
            ToastCenter.shared.info("Bell in \(tabName(of: paneId, store: store))")
        } else if SettingsStore.shared.values.agentSounds {
            NSSound.beep()
        }
    }

    static func tabName(of paneId: String, store: SessionStore) -> String {
        guard let pane = store.snapshot.panes.first(where: { $0.paneId == paneId }),
              let tab = store.snapshot.tabs.first(where: { $0.tabId == pane.tabId }) else { return "another pane" }
        return TabAutoName.display(label: tab.label, number: tab.number)
    }

    /// Shown as Octet's own banner when that's how notices are delivered.
    static func notify(title: String, body: String) {
        let heading = title.isEmpty ? "Terminal" : title
        // With system notifications on, the session server delivers them itself.
        guard SettingsStore.shared.values.notifications == .banner else { return }
        // Behind other apps it waits longer, to be there when you come back.
        ToastCenter.shared.info(heading, detail: body.isEmpty ? nil : body, after: NSApp.isActive ? 6 : 30)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

/// The link under the pointer, for the preview in the terminal's corner.
@MainActor
final class HoverLink: ObservableObject {
    static let shared = HoverLink()
    @Published var url: String?
}

/// Where a link goes, before you ⌘-click it.
struct HoverLinkPreview: View {
    @ObservedObject var link = HoverLink.shared

    var body: some View {
        if let url = link.url {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                Text(url).lineLimit(1).truncationMode(.middle)
                Text("⌘-click to open").foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
            .padding(8)
            .allowsHitTesting(false)
            .onAppear { DebugSnapshot.overlay("hover-link", true) }
            .onDisappear { DebugSnapshot.overlay("hover-link", false) }
        }
    }
}

/// The session server's bell and notification events for every pane: a
/// program in a pane rang the bell (BEL) or asked for a desktop
/// notification (OSC 9, OSC 777).
@MainActor
final class AttentionWatcher {
    static let shared = AttentionWatcher()
    private var started = false

    func start(store: SessionStore) {
        guard !started else { return }
        started = true
        let socketPath = store.client.socketPath
        let thread = Thread { [weak store] in
            while true {
                do {
                    let connection = try EngineSocketConnection(path: socketPath)
                    try connection.send(["id": "octet-attention", "method": "events.subscribe",
                                         "params": ["subscriptions": [["type": "pane.bell"], ["type": "pane.notification"]]]])
                    _ = try EngineClient.parseResponse(try connection.readLine())
                    while true {
                        let line = try connection.readLine()
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let event = object["event"] as? String,
                              let data = object["data"] as? [String: Any] else { continue }
                        let paneId = data["pane_id"] as? String
                        let title = data["title"] as? String ?? ""
                        let body = data["body"] as? String ?? ""
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let store else { return }
                                if event == "pane.bell" {
                                    TerminalAttention.bell(from: paneId, store: store)
                                } else if event == "pane.notification" {
                                    let from = paneId.map { TerminalAttention.tabName(of: $0, store: store) }
                                    TerminalAttention.notify(title: title.isEmpty ? (from ?? "") : title, body: body)
                                }
                            }
                        }
                    }
                } catch {
                    // The session server restarting, or an engine without
                    // these events: try again shortly.
                    Thread.sleep(forTimeInterval: 3)
                }
            }
        }
        thread.name = "octet.attention-events"
        thread.start()
    }
}
