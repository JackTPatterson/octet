import Foundation

/// A floating terminal over the pane in front, for a quick lazygit, a file
/// picker or a throwaway shell: a popup pane from a small session-server
/// plugin Octet keeps in its support folder and links once.
@MainActor
enum PopupTerminal {
    static let pluginId = "jpxsoftware.octet-popup"

    static let manifest = """
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
    command = ["sh", "popup.sh"]

    """

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
        let linked = store.plugins.contains { $0.pluginId == pluginId }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try manifest.write(to: folder.appendingPathComponent("herdr-plugin.toml"), atomically: true, encoding: .utf8)
                let scriptURL = folder.appendingPathComponent("popup.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
                if !linked { _ = try? client.call("plugin.link", ["path": folder.path]) }
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
