// Only the global switch (no per-surface scopes), remembered across launches.

import Carbon
import Cocoa
import OSLog

/// Secure Keyboard Entry: while on, keystrokes go only to Octet and can't be
/// read by other apps' event taps. The system setting is global, so Octet
/// yields it whenever it isn't the active app, and every enable is balanced
/// with a disable.
@MainActor
final class SecureInput: ObservableObject {
    static let shared = SecureInput()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Octet", category: "SecureInput")
    private static let defaultsKey = "octet.secureKeyboardEntry"

    /// What the user asked for.
    @Published var global: Bool {
        didSet {
            UserDefaults.standard.set(global, forKey: Self.defaultsKey)
            apply()
        }
    }

    /// True once EnableSecureEventInput has succeeded.
    @Published private(set) var enabled = false
    /// On for a password prompt in the pane in front, not by choice.
    @Published private(set) var forPassword = false

    private init() {
        global = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecureInput.shared.resign() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecureInput.shared.apply() }
        }
        apply()
    }

    private var wanted: Bool { global || forPassword }

    private func apply() {
        // Inactive: the activation notification applies it later.
        guard NSApp?.isActive == true, enabled != wanted else { return }
        let err = enabled ? DisableSecureEventInput() : EnableSecureEventInput()
        if err == noErr {
            enabled = wanted
        } else {
            Self.logger.warning("secure input apply failed err=\(err, privacy: .public)")
        }
    }

    /// Follows the pane in front: on while it asks for a password, off as
    /// soon as it stops, so other apps' global shortcuts (which secure
    /// input blocks) come back straight away.
    func passwordPrompt(_ asking: Bool) {
        let asking = asking && SettingsStore.shared.values.secureInputAtPasswords
        guard asking != forPassword else { return }
        forPassword = asking
        apply()
    }

    private func resign() {
        guard enabled else { return }
        if DisableSecureEventInput() == noErr { enabled = false }
    }
}
