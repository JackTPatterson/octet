import AppKit
import Foundation

/// Lets agents use the sidebar terminal: listens on a socket while either
/// Settings › Terminal toggle is on. `read` answers with the end of what the
/// terminal shows; `suggest` opens the panel and types a command at the
/// prompt for the person to run. Nothing is ever run for them.
@MainActor
final class TerminalAccessCenter {
    static let shared = TerminalAccessCenter()

    private weak var store: SessionStore?
    private var server: PermissionSocketServer?

    private var canRead: Bool { SettingsStore.shared.values.agentsReadSidebarTerminal }
    private var canSuggest: Bool { SettingsStore.shared.values.agentsSuggestSidebarCommands }
    private var enabled: Bool { canRead || canSuggest }

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
        let params = request["params"] as? [String: Any] ?? [:]
        switch (request["method"] as? String).flatMap(TerminalControl.Method.init(rawValue:)) {
        case .read:
            guard canRead else { return fail("Letting agents read the sidebar terminal is off (Octet Settings › Terminal).") }
            read(params, reply: reply, fail: fail)
        case .suggest:
            guard canSuggest else { return fail("Letting agents suggest commands in the sidebar terminal is off (Octet Settings › Terminal).") }
            suggest(params, reply: reply, fail: fail)
        case nil:
            fail("Unknown request.")
        }
    }

    private func read(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void, fail: (String) -> Void) {
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

    /// Opens the panel on its Terminal page, waits for the shell to start if
    /// it hadn't, and types the command at its prompt.
    private func suggest(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void, fail: @escaping (String) -> Void) {
        guard let command = TerminalControl.stagedCommand(params["command"] as? String ?? "") else {
            return fail("That isn't a single plain line of text.")
        }
        guard let target = windowShowing(params) else {
            return fail("Octet has no window open.")
        }
        target.ui.showSidePanel(tab: .terminal)
        NSApp.requestUserAttention(.informationalRequest)
        Task { @MainActor in
            var view: TerminalEngine.SurfaceView?
            for _ in 0..<30 {
                view = SidebarTerminals.shared.view(for: target.id)
                if view?.surfaceModel != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let view, view.surfaceModel != nil else {
                return fail("The sidebar terminal didn't start. Ask the person to open its Terminal tab.")
            }
            do {
                try SidebarTerminals.shared.stage(command, in: view)
            } catch {
                return fail(String(describing: error))
            }
            SidebarSuggestions.shared.set(command, window: target.id)
            reply(["result": ["command": command]])
        }
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
