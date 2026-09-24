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
