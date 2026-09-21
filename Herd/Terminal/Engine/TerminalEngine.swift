import Foundation
import os

// This defines the minimal information required so all other files can do
// `extension TerminalEngine` to add more to it. This purposely has minimal
// dependencies so things like our dock tile plugin can use it.
enum TerminalEngine {
    // The primary logger used by the terminal engine.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "terminal-engine"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}
}
