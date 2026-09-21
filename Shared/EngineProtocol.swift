import Foundation

/// Names the session server defines for itself: the environment variables it
/// reads and sets, its on-disk paths, and its executable and process names.
/// They are part of its interface, so they keep the server's own spelling;
/// everything else in Herd refers to them through this one adapter.
enum EngineProtocol {
    // MARK: Environment

    /// Read by the server: the config file to load.
    static let configPathVariable = "HERDR_CONFIG_PATH"
    /// Set by the server in every pane: its control socket.
    static let socketPathVariable = "HERDR_SOCKET_PATH"
    /// Set by the server in every pane: the pane's workspace id.
    static let workspaceIdVariable = "HERDR_WORKSPACE_ID"
    /// Set by the server in every pane: the pane's own id.
    static let paneIdVariable = "HERDR_PANE_ID"

    // MARK: On-disk paths

    /// The server's state folder, relative to the home folder.
    static let stateDirectory = ".config/herdr"
    /// The control socket's file name inside a session folder.
    static let socketFileName = "herdr.sock"
    /// Where the server put worktrees by default.
    static let legacyWorktreesDirectory = "~/.herdr/worktrees"
    /// Herd's own session config, under the name earlier versions used.
    static let legacyConfigFileName = "herdr-config.toml"

    // MARK: Executable

    /// Name of the server executable inside Herd.app (Contents/MacOS).
    static let bundledExecutable = "herd-engine"
    /// Where a standalone install lives, checked when the bundled copy is missing.
    static func standaloneInstallPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            home + "/.cargo/bin/herdr",
        ]
    }
    /// Process names the server runs under; never a meaningful tab name.
    static let processNames = ["herdr", bundledExecutable]
}
