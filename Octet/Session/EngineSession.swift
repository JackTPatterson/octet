import AppKit
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
        var env = TerminalEnvironment.colorCapability
        env[EngineProtocol.configPathVariable] = configPath
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

    /// Offers to restart a session server that was started with NO_COLOR.
    /// Octet's own launches never pass it on, but a server started earlier
    /// from an agent's or IDE's shell keeps it, and every pane it opens
    /// inherits it: Claude Code and every other program then print in the
    /// terminal's plain text colour. Restarting is the only way to clear a
    /// running server's environment, and it ends what runs in its panes.
    @MainActor
    func offerColorRestartIfNeeded() {
        let session = Self.name
        let enginePath = self.enginePath
        DispatchQueue.global(qos: .utility).async {
            guard let pid = TerminalEnvironment.colorlessServer(session: session) else { return }
            DispatchQueue.main.async {
                let declinedKey = "octet.colorlessServerDeclined"
                guard UserDefaults.standard.integer(forKey: declinedKey) != pid else { return }
                ConfirmCenter.shared.ask(ConfirmCenter.Request(
                    title: "Colour is off in this terminal session",
                    message: "The terminal server was started from a shell with NO_COLOR set, so Claude Code and other programs print everything in plain text colour. Restarting the server fixes it, but ends everything running in its panes. Octet reopens afterwards.",
                    confirmTitle: "Restart Terminal Server",
                    cancelTitle: "Not Now",
                    destructive: true,
                    onConfirm: { _ in Self.restartServer(enginePath: enginePath) },
                    // Asked once per server; a new colourless one asks again.
                    onCancel: { UserDefaults.standard.set(pid, forKey: declinedKey) }
                ))
            }
        }
    }

    /// Stops the session server, then relaunches Octet, which starts a fresh
    /// one with Octet's own environment.
    private static func restartServer(enginePath: String) {
        let app = Bundle.main.bundlePath
        let script = "\(shellQuote(enginePath)) --session \(shellQuote(name)) server stop; sleep 1; open -n \(shellQuote(app))"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; " + script]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NO_COLOR")
        relaunch.environment = environment
        try? relaunch.run()
        NSApp.terminate(nil)
    }

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
