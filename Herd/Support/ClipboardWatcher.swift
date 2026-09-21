import AppKit
import Foundation

/// Copying is invisible — the text looks the same whether or not it landed on
/// the clipboard — so Herd confirms it in its own toast. The session server has no
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

    /// Takes the current clipboard as already reported, so Herd's own copy
    /// actions — which toast for themselves — don't toast twice.
    func acknowledge() {
        lastCount = NSPasteboard.general.changeCount
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        // Only copies made here: another app's clipboard is its own business.
        guard NSApp.isActive, SettingsStore.shared.values.clipboardToasts else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        ToastCenter.shared.info("Copied to clipboard", detail: ClipboardPreview.summary(text))
    }
}
