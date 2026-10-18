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
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()
    @State private var dontPreview = false

    var body: some View {
        ZStack {
            if let request = center.request, host.owns(request.window) {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { center.cancel() }
                card(request)
                    .transition(motion.animates(.palette) ? .opacity.combined(with: .scale(scale: 0.97)) : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.request?.id)
        .background(HostWindowReader(host: host))
    }

    private func card(_ request: PastePreviewCenter.Request) -> some View {
        let lines = request.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OctetIcon("doc.on.clipboard", size: 18)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.cardSelected))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Paste into \(request.target)?")
                        .font(Theme.interfaceFont(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Agents fold a long paste into a one-line note you can't read or change, so check it first.")
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            OctetTextEditor(placeholder: "Pasted text",
                            text: Binding(get: { center.request?.text ?? "" }, set: { center.request?.text = $0 }),
                            minHeight: 340, maxHeight: 340, font: Theme.monoFont)
            HStack(spacing: 6) {
                stat("\(lines.formatted()) \(lines == 1 ? "line" : "lines")")
                stat("\(request.text.count.formatted()) characters")
                Spacer()
            }
            Toggle("Don't preview long pastes", isOn: $dontPreview)
                .toggleStyle(OctetCheckboxStyle())
            HStack(spacing: 8) {
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, compact: true) { center.cancel() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Paste", kind: .primary, compact: true) {
                    if dontPreview { SettingsStore.shared.values.previewLongPastes = false }
                    center.send(store: store)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Paste (⌘↩)")
            }
        }
        .padding(18)
        .frame(width: 680)
        .octetGlass(cornerRadius: 18, fill: Theme.card)
        .onChange(of: request.id) { _, _ in dontPreview = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paste \(lines) lines into \(request.target)?")
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(Theme.interfaceFont(11.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.hover))
    }
}
