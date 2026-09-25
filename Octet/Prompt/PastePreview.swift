import AppKit
import SwiftUI

/// A long paste into an agent is shown before it goes, and can be edited:
/// agents fold it into "[Pasted text +142 lines]" where it can't be read or
/// changed. Short pastes go straight through.
@MainActor
final class PastePreviewCenter: ObservableObject {
    static let shared = PastePreviewCenter()

    struct Request: Identifiable {
        let id = UUID()
        let paneId: String
        let target: String
        var text: String
        weak var window: NSWindow?
    }

    @Published var request: Request? {
        didSet { DebugSnapshot.overlay("paste-preview", request != nil) }
    }

    /// Lines or characters past which a paste into an agent is previewed.
    static let lineLimit = 25
    static let characterLimit = 3_000

    static func needsPreview(_ text: String) -> Bool {
        text.count > characterLimit || text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } >= lineLimit
    }

    /// Takes the paste when it's long and the pane in front runs an agent.
    func intercept(_ text: String, store: SessionStore) -> Bool {
        guard SettingsStore.shared.values.previewLongPastes, Self.needsPreview(text),
              let paneId = store.keyPaneId,
              let agent = store.snapshot.agents.first(where: { $0.paneId == paneId && $0.agent != nil }) else { return false }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "the agent"
        request = Request(paneId: paneId, target: name, text: text, window: NSApp.keyWindow)
        return true
    }

    func send(store: SessionStore) {
        guard let request else { return }
        self.request = nil
        let client = store.client
        // Bracketed, so the agent takes it as a paste and not as typing
        // (a newline would otherwise submit halfway through).
        let text = "\u{1b}[200~" + request.text + "\u{1b}[201~"
        EngineClient.inputQueue.async {
            _ = try? client.call("pane.send_text", ["pane_id": request.paneId, "text": text])
        }
        OctetTerminalRuntime.focusTerminal()
    }

    func cancel() {
        request = nil
        OctetTerminalRuntime.focusTerminal()
    }
}

struct PastePreviewDialog: View {
    @ObservedObject var center: PastePreviewCenter
    let store: SessionStore
    @StateObject private var host = HostWindow()

    var body: some View {
        ZStack {
            if let request = center.request, host.owns(request.window) {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { center.cancel() }
                card(request)
            }
        }
        .background(HostWindowReader(host: host))
    }

    private func card(_ request: PastePreviewCenter.Request) -> some View {
        let lines = request.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Paste \(lines) lines into \(request.target)?")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("Edit it here first if you like. \(request.text.count.formatted()) characters.")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            TextEditor(text: Binding(get: { center.request?.text ?? "" }, set: { center.request?.text = $0 }))
                .font(Theme.monoFont)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                .frame(height: 360)
            HStack {
                Spacer()
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { center.cancel() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Paste", kind: .primary, compact: true) { center.send(store: store) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Paste (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 680)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}
