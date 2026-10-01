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

    /// Variables another terminal set for the programs in it. Inherited by
    /// Octet when it's started from that terminal's shell, they'd tell every
    /// program in Octet's panes it's running there.
    static func isInheritedTerminalVariable(_ name: String) -> Bool {
        name == "NO_COLOR" || name.hasPrefix("WARP_") || inheritedTerminalVariables.contains(name)
    }

    private static let inheritedTerminalVariables: Set<String> = [
        "TERM_SESSION_ID", "TERM_PROGRAM_VERSION", "TERMINAL_EMULATOR",
        "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION",
        "KITTY_WINDOW_ID", "KITTY_PID", "KITTY_PUBLIC_KEY",
        "WEZTERM_PANE", "WEZTERM_EXECUTABLE", "WEZTERM_UNIX_SOCKET",
        "ALACRITTY_WINDOW_ID", "ALACRITTY_SOCKET", "ALACRITTY_LOG",
    ]

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { !isInheritedTerminalVariable($0.key) }
    }

    /// Run before any terminal engine or session process is created: what
    /// Octet starts inherits its environment.
    static func clearInheritedTerminalVariables() {
        for name in ProcessInfo.processInfo.environment.keys where isInheritedTerminalVariable(name) {
            unsetenv(name)
        }
    }

    /// The pid of `session`'s server when it was started with NO_COLOR, from
    /// `ps -axwwE -o pid=,command=` output. The server outlives Octet and its
    /// panes inherit its environment, so one started from an agent's or an
    /// IDE's shell keeps every program in every new pane colourless, however
    /// Octet launches later.
    static func colorlessServer(session: String, processList: String) -> Int? {
        for line in processList.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count > 2, let pid = Int(fields[0]),
                  EngineProtocol.processNames.contains((fields[1] as NSString).lastPathComponent),
                  fields[2] == "server",
                  fields.contains("HERDR_SESSION=\(session)") else { continue }
            if fields.contains(where: { $0.hasPrefix("NO_COLOR=") }) { return pid }
        }
        return nil
    }

    static func colorlessServer(session: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axwwE", "-o", "pid=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return colorlessServer(session: session, processList: String(decoding: data, as: UTF8.self))
    }
}

/// Desktop notifications (OSC 9, OSC 777) a program in a pane sends.
enum TerminalNotice {
    /// Meant for software, not a person: titled with an address, or a body
    /// that is a JSON message. Warp's Claude Code integration, for one, sends
    /// `warp://cli-agent` with each hook event from whatever terminal Claude
    /// runs in. Never shown.
    static func isForSoftware(title: String, body: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        if title.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil { return true }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) is [String: Any]
    }
}
