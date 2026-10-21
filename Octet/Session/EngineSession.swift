import AppKit
import Foundation

/// How Octet launches and addresses its own session on the session server.
struct EngineSession {
    /// Octet's named session, separate from a standalone session in any terminal.
    /// `OCTET_SESSION` runs an isolated session (used to test restarts).
    /// A Debug build has its own unless told otherwise: two apps on one
    /// session fight over the panes' size, and a pane drawn for the other
    /// app's window only comes right when you click into this one.
    static let name = ProcessInfo.processInfo.environment["OCTET_SESSION"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultName

    #if DEBUG
    static let defaultName = "octet-debug"
    #else
    static let defaultName = "octet"
    #endif

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
        env[PeerControl.socketVariable] = Self.supportDirectory.appendingPathComponent(PeerControl.socketName).path
        env[TerminalControl.socketVariable] = Self.supportDirectory.appendingPathComponent(TerminalControl.socketName).path
        env[WaitControl.socketVariable] = Self.supportDirectory.appendingPathComponent(WaitControl.socketName).path
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
            let title = "Colour is off in this terminal session"
            let message = "The terminal server was started from a shell with NO_COLOR set, so Claude Code and other programs print everything in plain text colour. Restarting the server fixes it, but ends everything running in its panes. Octet reopens afterwards."
            DispatchQueue.main.async {
                let declinedKey = "octet.colorlessServerDeclined"
                guard UserDefaults.standard.integer(forKey: declinedKey) != pid else { return }
                ConfirmCenter.shared.ask(ConfirmCenter.Request(
                    title: title,
                    message: message,
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

    /// The running server is older than this Octet and couldn't hand its
    /// panes to the new engine: until it restarts, panes draw empty.
    @MainActor
    static func offerRestartAfterFailedUpgrade(enginePath: String, reason: String) {
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Restart the terminal server?",
            message: "The terminal server still running is from an earlier version of Octet, and it couldn't hand its panes to the new one (\(reason)). Until it restarts, panes stay empty. Restarting ends everything running in them. Octet reopens afterwards.",
            confirmTitle: "Restart Terminal Server",
            cancelTitle: "Not Now",
            destructive: true,
            onConfirm: { _ in restartServer(enginePath: enginePath) },
            onCancel: {}
        ))
    }

    /// Stops the session server, then relaunches Octet, which starts a fresh
    /// one with Octet's own environment.
    private static func restartServer(enginePath: String) {
        let app = Bundle.main.bundlePath
        let script = "\(shellQuote(enginePath)) --session \(shellQuote(name)) server stop; sleep 1; open -n \(shellQuote(app))"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; " + script]
        relaunch.environment = TerminalEnvironment.sanitized(ProcessInfo.processInfo.environment)
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// Starting the server, one request at a time.
    private static let launching = DispatchQueue(label: "octet.engine-launch", qos: .userInitiated)
    nonisolated(unsafe) private static var lastLaunch = Date.distantPast

    /// Starts the session server when none answers. It runs detached, so it
    /// and everything in its panes outlive Octet.
    func ensureServer() {
        let socketPath = self.socketPath, enginePath = self.enginePath
        var environment = TerminalEnvironment.sanitized(ProcessInfo.processInfo.environment)
            .merging(self.environment) { $1 }
        environment["HERDR_STARTUP_CWD"] = NSHomeDirectory()
        Self.launching.async {
            if (try? EngineSocketConnection(path: socketPath)) != nil { return }
            // Asked again (at launch, then by the window) before the first
            // server is listening: one server, not two.
            if Date().timeIntervalSince(Self.lastLaunch) < 5 { return }
            Self.lastLaunch = Date()
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/bin/sh")
            // The shell backgrounds the server and exits, so launchd adopts it.
            // Only the server goes in the background: a whole `cd && …` list
            // would leave a subshell behind, waiting on it.
            launch.arguments = ["-c", #"cd "$HOME"; "$0" --session "$1" server </dev/null >/dev/null 2>&1 &"#,
                                enginePath, Self.name]
            launch.environment = environment
            try? launch.run()
            launch.waitUntilExit()
        }
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
