import Foundation

/// Keeps the host application's environment from muting programs running in
/// Octet's PTY. A terminal advertises color capability; launch-time variables
/// from an IDE or parent agent must not silently opt every child program out.
enum TerminalEnvironment {
    static let colorCapability = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "TERM_PROGRAM": "Octet",
        // Some color libraries let FORCE_COLOR override an inherited
        // NO_COLOR. Level 3 means the truecolor capability advertised above.
        "FORCE_COLOR": "3",
    ]

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: "NO_COLOR")
        return environment
    }

    /// Run before any terminal engine or session process is created.
    static func clearInheritedColorSuppression() {
        unsetenv("NO_COLOR")
    }
}
