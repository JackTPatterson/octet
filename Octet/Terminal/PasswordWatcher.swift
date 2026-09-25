import AppKit
import SwiftUI

/// Checks, while Octet is in front, whether the pane in front is asking for
/// a password, and turns Secure Keyboard Entry on for exactly that long.
@MainActor
final class PasswordWatcher {
    static let shared = PasswordWatcher()
    private var timer: Timer?
    private weak var store: SessionStore?

    func start(store: SessionStore) {
        self.store = store
        guard timer == nil else { return }
        // Cheap: one proc_pidinfo and one tcgetattr.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { PasswordWatcher.shared.check() }
        }
    }

    private func check() {
        guard NSApp.isActive, let shell = store?.keyProcess?.shellPid else {
            SecureInput.shared.passwordPrompt(false)
            return
        }
        SecureInput.shared.passwordPrompt(ShellPrompt.secretPrompt(shellPid: shell) == true)
    }
}

/// Says so while keys are going only to Octet.
struct SecureInputBadge: View {
    @ObservedObject var secure = SecureInput.shared

    var body: some View {
        if secure.enabled, secure.forPassword {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                Text("Secure input for this password")
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Theme.chrome))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .padding(8)
            .help("Other apps can't read your keystrokes while a password is asked for. It turns off when the prompt ends.")
            .allowsHitTesting(false)
        }
    }
}
