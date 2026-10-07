import AppKit
import Foundation

/// Lets agents read the sidebar terminal: listens on a socket while
/// Settings › Terminal › "Let agents read the sidebar terminal" is on, and
/// answers an agent's `read` with the end of what that terminal shows.
/// Read only: nothing an agent sends is ever typed into it.
@MainActor
final class TerminalAccessCenter {
    static let shared = TerminalAccessCenter()

    private weak var store: SessionStore?
    private var server: PermissionSocketServer?

    private var enabled: Bool { SettingsStore.shared.values.agentsReadSidebarTerminal }

    /// Starts or stops with the setting.
    func apply(store: SessionStore? = nil) {
        if let store { self.store = store }
        if enabled, server == nil { start() } else if !enabled, server != nil { stop() }
    }

    private var socketPath: String {
        EngineSession.supportDirectory.appendingPathComponent(TerminalControl.socketName).path
    }

    private func start() {
        try? FileManager.default.createDirectory(at: EngineSession.supportDirectory, withIntermediateDirectories: true)
        let server = PermissionSocketServer(path: socketPath)
        do {
            try server.start { [weak self] request, reply in
                MainActor.assumeIsolated { self?.handle(request, reply: reply) }
            }
            self.server = server
        } catch {
            ToastCenter.shared.fail(nil, "Agents can't read the sidebar terminal", detail: "\(error)")
        }
    }

    private func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - Requests

    private func handle(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let fail: (String) -> Void = { reply(["error": $0]) }
        guard enabled else { return fail("Letting agents read the sidebar terminal is off (Octet Settings › Terminal).") }
        guard (request["method"] as? String).flatMap(TerminalControl.Method.init(rawValue:)) == .read else {
            return fail("Unknown request.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let lines = TerminalControl.clampLines(params["lines"])

        // The window the agent works in: the one showing its pane's
        // workspace, else the one in front.
        let target = windowShowing(params)
        guard let entry = SidebarTerminals.shared.entry(for: target?.id), let view = entry.view else {
            return fail(SidebarTerminals.shared.hasAny
                ? "Couldn't tell which window's sidebar terminal you mean. Ask the person to bring that window forward."
                : "The sidebar terminal isn't open. Ask the person to open it: the Terminal tab in Octet's right-hand panel.")
        }
        guard let text = SidebarTerminals.shared.text(of: view) else {
            return fail("Couldn't read the sidebar terminal.")
        }
        let tail = TerminalControl.lastLines(text, count: lines)
        let shown = tail.text.isEmpty ? 0 : tail.text.components(separatedBy: "\n").count
        reply(["result": ["text": tail.text, "lines": shown, "total_lines": tail.total,
                          "title": entry.title, "shell_running": !entry.exited]])
    }

    private func windowShowing(_ params: [String: Any]) -> WindowContext? {
        let registry = WindowRegistry.shared
        var workspace = params["from_workspace"] as? String
        if workspace == nil, let pane = params["from_pane"] as? String {
            workspace = store?.snapshot.panes.first { $0.paneId == pane }?.workspaceId
        }
        return workspace.flatMap { registry.window(showing: $0) } ?? registry.key
    }
}
