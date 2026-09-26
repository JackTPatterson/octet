import Foundation

/// A floating terminal over the pane in front, for a quick lazygit, a file
/// picker or a throwaway shell: a popup pane from a small session-server
/// plugin Octet keeps in its support folder and links once.
@MainActor
enum PopupTerminal {
    static let pluginId = "jpxsoftware.octet-popup"

    /// The script is named by its full path: the pane starts in the folder
    /// it opens on, not the plugin's (a bare `popup.sh` exited 127).
    static func manifest(scriptPath: String) -> String {
        """
    id = "\(pluginId)"
    name = "Octet Popup"
    version = "1.0.0"
    min_herdr_version = "0.9.0"
    description = "A floating terminal over the pane in front."
    platforms = ["macos", "linux"]

    [[panes]]
    id = "popup"
    title = "Popup"
    placement = "popup"
    width = "80%"
    height = "80%"
    command = ["sh", \(tomlString(scriptPath))]

    """
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let script = """
    #!/bin/sh
    # Runs what Octet asked for, or a shell. The popup closes when it exits.
    if [ -n "$OCTET_POPUP_COMMAND" ]; then exec "${SHELL:-/bin/zsh}" -lc "$OCTET_POPUP_COMMAND"; fi
    exec "${SHELL:-/bin/zsh}" -l

    """

    /// Opens `command` (a shell when nil) in a popup, in the pane's folder.
    static func open(_ command: String?, store: SessionStore) {
        let folder = EngineSession.supportDirectory.appendingPathComponent("engine-plugins/octet-popup", isDirectory: true)
        let cwd = store.keyPaneId.flatMap { store.snapshot.workingDirectory(ofPane: $0) } ?? NSHomeDirectory()
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let scriptURL = folder.appendingPathComponent("popup.sh")
                try manifest(scriptPath: scriptURL.path)
                    .write(to: folder.appendingPathComponent("herdr-plugin.toml"), atomically: true, encoding: .utf8)
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
                // Every time: linking again picks up a changed manifest.
                _ = try? client.call("plugin.link", ["path": folder.path])
                var params: [String: Any] = ["plugin_id": pluginId, "entrypoint": "popup", "cwd": cwd, "focus": true]
                if let command, !command.isEmpty { params["env"] = ["OCTET_POPUP_COMMAND": command] }
                _ = try client.call("plugin.pane.open", params)
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't open a popup", detail: String(describing: error))
                }
            }
        }
    }
}
