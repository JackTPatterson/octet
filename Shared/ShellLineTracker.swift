import Foundation

/// Whether a pane's shell already holds part of the command line: text that
/// reached the shell before Octet's command line took the keyboard, or that
/// Octet handed back to it. Octet's line starts empty, so taking over then
/// would edit a line that doesn't begin where it thinks.
struct ShellLineTracker {
    enum Key {
        /// Return: the line runs and the next prompt starts empty.
        case submit
        /// ⌃C or ⌃U: the shell drops its line.
        case clear
        /// Printable text, a paste, or history recall with ↑.
        case text
        case other
    }

    /// Shells holding a line, by key. Kept across Octet restarts: the
    /// terminal server, and its shells' half-typed lines, outlive the app.
    private(set) var holding: Set<String>
    /// Panes last seen with a program in front of the shell.
    private var programInFront: Set<String> = []

    init(holding: Set<String> = []) { self.holding = holding }

    /// A key naming one shell rather than one pane: a pane id can come back
    /// after the server restarts, but a shell's process id can't be alive
    /// twice. nil pid falls back to the pane alone.
    static func key(pane: String, shellPid: Int?) -> String {
        shellPid.map { "\(pane)#\($0)" } ?? pane
    }

    /// The pid in a key, for dropping keys whose shell has exited.
    static func shellPid(inKey key: String) -> Int? {
        key.split(separator: "#").last.flatMap { Int($0) }
    }

    /// The keys of shells still alive, by `isAlive`.
    func pruned(isAlive: (Int) -> Bool) -> ShellLineTracker {
        ShellLineTracker(holding: holding.filter { key in Self.shellPid(inKey: key).map(isAlive) ?? false })
    }

    func holdsLine(_ pane: String) -> Bool { holding.contains(pane) }

    /// A key Octet let through to the pane. Text counts even when Octet
    /// isn't sure the shell is in front: that's exactly when a line starts
    /// without it.
    mutating func keyReachedPane(_ pane: String, _ key: Key) {
        switch key {
        case .submit, .clear: holding.remove(pane)
        case .text: holding.insert(pane)
        case .other: break
        }
    }

    /// What's in front of the pane's shell, when known. A program that exits
    /// leaves a fresh prompt, so text typed into it no longer counts.
    mutating func observe(_ pane: String, programInFront running: Bool?) {
        guard let running else { return }
        if running {
            programInFront.insert(pane)
        } else if programInFront.remove(pane) != nil {
            holding.remove(pane)
        }
    }

    /// Octet gave its line to the shell. Unless that ran it, the shell holds it.
    mutating func handedLine(_ pane: String, submitted: Bool) {
        if submitted { holding.remove(pane) } else { holding.insert(pane) }
    }
}
