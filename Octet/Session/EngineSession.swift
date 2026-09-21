import Foundation

/// How Octet launches and addresses its own session on the session server.
struct EngineSession {
    /// Octet's named session, separate from a standalone session in any terminal.
    /// `OCTET_SESSION` runs an isolated session (used to test restarts).
    static let name = ProcessInfo.processInfo.environment["OCTET_SESSION"].flatMap { $0.isEmpty ? nil : $0 } ?? "octet"

    /// Octet's support folder; isolated sessions get their own subfolder.
    static var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Octet", isDirectory: true)
        return name == "octet" ? base : base.appendingPathComponent("sessions/\(name)", isDirectory: true)
    }

    let enginePath: String
    let configPath: String
    let socketPath: String

    static func make() -> EngineSession? {
        guard let engine = locateEngine() else { return nil }
        let support = supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = support.appendingPathComponent("terminal.toml").path
        // Earlier versions wrote the config under another name.
        try? FileManager.default.removeItem(at: support.appendingPathComponent(EngineProtocol.legacyConfigFileName))
        return EngineSession(
            enginePath: engine,
            configPath: config,
            socketPath: EngineClient.socketPath(session: name)
        )
    }

    /// The session server always draws one tab row at the top; Octet clips it
    /// and shows native tabs instead.
    static let hiddenTopRows = 1

    /// Shell command the terminal surface runs.
    var command: String {
        "\(shellQuote(enginePath)) --session \(Self.name)"
    }

    var environment: [String: String] {
        var env = [
            EngineProtocol.configPathVariable: configPath,
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Octet",
        ]
        // The session server spawns every pane with its own $SHELL, and it
        // outlives Octet, so hand it the login shell rather than whatever
        // environment launched us (a stripped one falls back to /bin/sh).
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            env["SHELL"] = String(cString: shell)
        }
        if let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path {
            env["OCTET_CLI"] = cli
        }
        return env
    }

    var client: EngineClient { EngineClient(socketPath: socketPath) }

    /// The engine bundled in Octet.app, or a standalone install when the
    /// bundled copy is missing (a development build without it, for example).
    static func locateEngine() -> String? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: EngineProtocol.bundledExecutable)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return EngineProtocol.standaloneInstallPaths().first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

func shellQuote(_ value: String) -> String {
    if value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
