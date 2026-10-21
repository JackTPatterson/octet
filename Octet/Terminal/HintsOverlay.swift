import AppKit
import SwiftUI

/// ⌘⇧H: labels on every link, `file:line` and commit hash in the pane in
/// front. Type a label to open it (a hash is copied; an image or PDF
/// shows in Quick Look); hold ⇧ to copy instead, ⌥ to Quick Look any
/// file; Esc leaves.
@MainActor
final class HintsSession: ObservableObject, Identifiable {
    let id = UUID()
    let paneId: String
    let cwd: String?
    let hints: [Hints.Hint]
    @Published var typed = ""

    init(paneId: String, cwd: String?, hints: [Hints.Hint]) {
        self.paneId = paneId
        self.cwd = cwd
        self.hints = hints
    }

    var showing: [Hints.Hint] { hints.filter { $0.label.hasPrefix(typed) } }

    /// Reads the pane's screen and starts hints on it.
    static func start(window: WindowContext) {
        let store = window.store
        guard let paneId = store.keyPaneId else { return }
        let cwd = store.snapshot.workingDirectory(ofPane: paneId)
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "visible"]))?["read"] as? [String: Any]
            let lines = (read?["text"] as? String ?? "").components(separatedBy: "\n")
            let hints = Hints.find(in: lines)
            DispatchQueue.main.async {
                guard !hints.isEmpty else {
                    ToastCenter.shared.info("Nothing to open on screen", detail: "Hints finds links, file:line references and commit hashes.")
                    return
                }
                window.ui.hints = HintsSession(paneId: paneId, cwd: cwd, hints: hints)
            }
        }
    }

    /// A typed letter: narrows the labels, and acts once one is whole.
    func type(_ letter: String, copy: Bool, preview: Bool = false, window: WindowContext) {
        typed += letter.lowercased()
        let matches = showing
        if let hint = matches.first(where: { $0.label == typed }) {
            window.ui.hints = nil
            act(on: hint, copy: copy, preview: preview, window: window)
        } else if matches.isEmpty {
            window.ui.hints = nil
        }
    }

    private func act(on hint: Hints.Hint, copy: Bool, preview: Bool, window: WindowContext) {
        if copy || hint.kind == .hash {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hint.text, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            ToastCenter.shared.info("Copied", detail: hint.text)
            OctetTerminalRuntime.focusTerminal()
            return
        }
        switch hint.kind {
        case .url:
            if let url = URL(string: hint.text) { NSWorkspace.shared.open(url) }
            OctetTerminalRuntime.focusTerminal()
        case .path:
            let path = Hints.file(of: hint, cwd: cwd)
            guard FileManager.default.fileExists(atPath: path) else {
                ToastCenter.shared.fail(nil, "There's no \((path as NSString).lastPathComponent) here", detail: path)
                return
            }
            if preview || Hints.prefersPreview(path) {
                QuickLook.shared.show(URL(fileURLWithPath: path))
                return
            }
            window.openFile(URL(fileURLWithPath: path), presentation: .split)
            if let line = hint.line { window.editor.reveal(line: line) }
        case .hash:
            break
        }
    }
}

struct HintsOverlay: View {
    @ObservedObject var session: HintsSession
    @ObservedObject var geometry: PaneGeometry
    let window: WindowContext
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                if let pane = geometry.panes[session.paneId] {
                    ForEach(session.showing, id: \.label) { hint in
                        let origin = pane.origin(row: hint.row, column: hint.column)
                        label(hint).offset(x: origin.x, y: origin.y)
                    }
                }
            }
            .overlay(alignment: .bottom) { legend.padding(.bottom, Theme.Space.lg) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            DebugSnapshot.overlay("hints", true)
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { DebugSnapshot.overlay("hints", false) }
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                window.ui.hints = nil
                OctetTerminalRuntime.focusTerminal()
                return .handled
            }
            // ⌥ turns letters into symbols (⌥A is å): use the key itself.
            let letter = press.modifiers.contains(.option) ? String(press.key.character).lowercased() : press.characters.lowercased()
            guard letter.count == 1, letter.first?.isLetter == true else { return .ignored }
            session.type(letter, copy: press.modifiers.contains(.shift), preview: press.modifiers.contains(.option), window: window)
            return .handled
        }
        .onTapGesture { window.ui.hints = nil }
    }

    /// What the keys do, under the labels: the modifiers aren't guessable.
    private var legend: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("Type a label to open it").foregroundStyle(Theme.textSecondary)
            Keycap(text: "⇧").padding(.leading, Theme.Space.sm)
            Text("copies").foregroundStyle(Theme.textTertiary)
            Keycap(text: "⌥").padding(.leading, Theme.Space.sm)
            Text("previews").foregroundStyle(Theme.textTertiary)
            Keycap(text: "esc").padding(.leading, Theme.Space.sm)
            Text("leaves").foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Text.caption)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .octetGlass(cornerRadius: Theme.Radius.xl, fill: Theme.terminalBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Type a label to open it. Hold Shift to copy, Option to preview. Escape leaves.")
    }

    private func label(_ hint: Hints.Hint) -> some View {
        HStack(spacing: 0) {
            Text(String(hint.label.prefix(session.typed.count))).foregroundStyle(Theme.onAccent.opacity(0.5))
            Text(String(hint.label.dropFirst(session.typed.count))).foregroundStyle(Theme.onAccent)
        }
        .font(TerminalLook.font(size: 11, weight: .bold))
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(hint.kind == .url ? Theme.accent : Theme.warning))
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}
