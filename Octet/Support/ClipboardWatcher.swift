import AppKit
import Foundation

/// Copying is invisible — the text looks the same whether or not it landed on
/// the clipboard — so Octet confirms it in its own toast. The session server has no
/// clipboard event, so this watches the pasteboard instead, which catches
/// every route: the terminal's copy-on-select and ⌘C, the session server's copy mode, and
/// anything a plugin copies.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// Cheap enough to poll: `changeCount` is an integer read.
    private static let interval: TimeInterval = 0.4
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Takes the current clipboard as already reported, so Octet's own copy
    /// actions — which toast for themselves — don't toast twice.
    func acknowledge() {
        lastCount = NSPasteboard.general.changeCount
    }

    /// Whether the pane in front is running an agent, whose interface is
    /// what the copy came out of.
    private static func agentInFront() -> Bool {
        guard let window = WindowRegistry.shared.key, let pane = window.focusedPaneId else { return false }
        return window.store.snapshot.agents.contains { $0.paneId == pane && $0.agent != nil }
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        // Only copies made here: another app's clipboard is its own business.
        guard NSApp.isActive, var text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        var tidied = false
        if SettingsStore.shared.values.tidyAgentCopies, Self.agentInFront() {
            let tidy = CopyTidy.tidy(text)
            if tidy != text, !tidy.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(tidy, forType: .string)
                lastCount = pasteboard.changeCount
                text = tidy
                tidied = true
            }
        }
        guard SettingsStore.shared.values.clipboardToasts else { return }
        ToastCenter.shared.info(tidied ? "Copied, without the agent's layout" : "Copied to clipboard",
                                detail: ClipboardPreview.summary(text))
    }
}
