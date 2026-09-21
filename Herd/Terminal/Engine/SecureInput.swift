// Only the global switch (no per-surface scopes), remembered across launches.

import Carbon
import Cocoa
import OSLog

/// Secure Keyboard Entry: while on, keystrokes go only to Herd and can't be
/// read by other apps' event taps. The system setting is global, so Herd
/// yields it whenever it isn't the active app, and every enable is balanced
/// with a disable.
@MainActor
final class SecureInput: ObservableObject {
    static let shared = SecureInput()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Herd", category: "SecureInput")
    private static let defaultsKey = "herd.secureKeyboardEntry"

    /// What the user asked for.
    @Published var global: Bool {
        didSet {
            UserDefaults.standard.set(global, forKey: Self.defaultsKey)
            apply()
        }
    }

    /// True once EnableSecureEventInput has succeeded.
    @Published private(set) var enabled = false

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

    private func apply() {
        // Inactive: the activation notification applies it later.
        guard NSApp?.isActive == true, enabled != global else { return }
        let err = enabled ? DisableSecureEventInput() : EnableSecureEventInput()
        if err == noErr {
            enabled = global
        } else {
            Self.logger.warning("secure input apply failed err=\(err, privacy: .public)")
        }
    }

    private func resign() {
        guard enabled else { return }
        if DisableSecureEventInput() == noErr { enabled = false }
    }
}
