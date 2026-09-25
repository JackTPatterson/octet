import AppKit
import SwiftUI

/// Typing into every pane of a tab at once, as iTerm2's broadcast input
/// does: keys go to the focused pane as usual and are mirrored into the
/// others. A banner says so the whole time; ⌥⌘I or leaving the tab stops it.
@MainActor
final class BroadcastMode: ObservableObject {
    static let shared = BroadcastMode()

    @Published private(set) var tabId: String?
    @Published private(set) var paneCount = 0
    private weak var store: SessionStore?

    var isOn: Bool { tabId != nil }

    func toggle(window: WindowContext) {
        if isOn { return stop() }
        let store = window.store
        guard let tab = window.displayedFocusedTabId else { return }
        let panes = store.snapshot.panes.filter { $0.tabId == tab }
        guard panes.count > 1 else {
            ToastCenter.shared.info("Nothing to type into besides this pane", detail: "Split the tab first (⌘D).")
            return
        }
        self.store = store
        tabId = tab
        paneCount = panes.count
    }

    func stop() {
        tabId = nil
        paneCount = 0
    }

    /// Mirrors a key into the tab's other panes; the focused one gets it the
    /// usual way.
    func mirror(_ event: NSEvent) {
        guard let tabId, let store else { return }
        let focused = store.keyPaneId
        guard store.snapshot.panes.first(where: { $0.paneId == focused })?.tabId == tabId else { return stop() }
        var modifiers: KeyBytes.Modifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        guard let bytes = KeyBytes.encode(keyCode: event.keyCode, characters: event.characters, modifiers: modifiers) else { return }
        let others = store.snapshot.panes.filter { $0.tabId == tabId && $0.paneId != focused }.map(\.paneId)
        paneCount = others.count + 1
        let client = store.client
        EngineClient.inputQueue.async {
            for pane in others { _ = try? client.call("pane.send_text", ["pane_id": pane, "text": bytes]) }
        }
    }
}

/// The banner over the terminal while typing is mirrored.
struct BroadcastBanner: View {
    @ObservedObject var mode: BroadcastMode
    let tabId: String?

    var body: some View {
        if mode.isOn, mode.tabId == tabId {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                Text("Typing into all \(mode.paneCount) panes").font(Theme.uiFontMedium)
                Text("⌥⌘I to stop").font(Theme.captionFont).opacity(0.75)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(.top, 8)
            .onTapGesture { mode.stop() }
            .onAppear { DebugSnapshot.overlay("broadcast-mode", true) }
            .onDisappear { DebugSnapshot.overlay("broadcast-mode", false) }
        }
    }
}
