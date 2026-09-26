import AppKit

/// Carries out `octet://` links. Anything a web page could open is fair
/// game, so the two that act in your terminal ask first: typing text, and
/// starting an agent with instructions.
@MainActor
enum OctetURLHandler {
    static func handle(_ command: OctetURL) {
        guard let window = WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first else { return }
        window.bringForward()
        switch command {
        case .open(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                ToastCenter.shared.fail(nil, "There's no folder at \((path as NSString).abbreviatingWithTildeInPath)")
                return
            }
            window.openProject(path: path)
        case .run(let agent, let path, let prompt):
            guard let found = AgentDiscoveryStore.shared.agents.first(where: { $0.id == agent }),
                  let executable = found.executablePath else {
                ToastCenter.shared.fail(nil, "\(agent) isn't installed")
                return
            }
            let start = { run(found, executable: executable, in: path, prompt: prompt, window: window) }
            guard let prompt else { return start() }
            ConfirmCenter.shared.ask(
                title: "Start \(found.displayName) with these instructions?",
                message: "A link asked Octet to start it\(path.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""). Only go ahead if you opened it.",
                detail: prompt, confirmTitle: "Start"
            ) { _ in start() }
        case .send(let text):
            guard let pane = window.store.keyPaneId else { return }
            ConfirmCenter.shared.ask(
                title: "Type this into the terminal and run it?",
                message: "A link asked Octet to. Only go ahead if you opened it.",
                detail: text, confirmTitle: "Run", destructive: true
            ) { _ in window.store.runInPane(pane, line: text) }
        }
    }

    /// A new tab running the agent (with its first message) in `path`, or in
    /// the workspace in front.
    private static func run(_ agent: DiscoveredAgent, executable: String, in path: String?, prompt: String?,
                            window: WindowContext) {
        let store = window.store
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = shellQuote(executable) + (prompt.map { " " + shellQuote($0) } ?? "")
        let cwd = path ?? window.focusedWorkspace.flatMap { store.snapshot.directory(ofWorkspace: $0.workspaceId) } ?? NSHomeDirectory()
        var params: [String: Any] = [
            "tab_label": agent.displayName, "focus": true,
            "root": ["type": "pane", "label": agent.displayName, "cwd": cwd,
                     "command": [shell, "-lic", "\(command); exec \(shell) -l"]] as [String: Any],
        ]
        // A folder with a workspace already open goes there.
        if let path, let existing = store.snapshot.workspaces.first(where: { store.snapshot.directory(ofWorkspace: $0.workspaceId) == path }) {
            params["workspace_id"] = existing.workspaceId
        } else if path == nil, let workspace = window.focusedWorkspace {
            params["workspace_id"] = workspace.workspaceId
        } else if let path {
            store.call("workspace.create", ["cwd": path, "label": URL(fileURLWithPath: path).lastPathComponent, "focus": true],
                       failure: "Couldn't open \(path)") { created in
                var params = params
                params["workspace_id"] = created.workspaceId
                store.call("layout.apply", params, failure: "Couldn't start \(agent.displayName)") { _ in }
            }
            return
        }
        store.call("layout.apply", params, failure: "Couldn't start \(agent.displayName)") { _ in }
    }
}
