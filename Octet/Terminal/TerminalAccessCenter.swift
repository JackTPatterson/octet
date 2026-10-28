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
        case .open:
            guard canSuggest else { return fail("Letting agents open and stage commands in terminals is off (Octet Settings › Terminal › Let agents suggest commands).") }
            open(params, reply: reply, fail: fail)
        case .queue:
            guard canSuggest else { return fail("Letting agents open and stage commands in terminals is off (Octet Settings › Terminal › Let agents suggest commands).") }
            queue(params, reply: reply, fail: fail)
        case nil:
            fail("Unknown request.")
        }
    }

    private func read(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void, fail: @escaping (String) -> Void) {
        let lines = TerminalControl.clampLines(params["lines"])
        if let pane = params["pane_id"] as? String, !pane.isEmpty {
            return readPane(pane, lines: lines, params: params, reply: reply, fail: fail)
        }

        // The agent's own workspace's terminal, else the one in front.
        let workspace = agentWorkspace(params) ?? WindowRegistry.shared.key?.focusedWorkspace?.workspaceId
        guard let entry = SidebarTerminals.shared.entry(for: SidebarTerminals.key(workspace)), let view = entry.view else {
            return fail(SidebarTerminals.shared.hasAny
                ? "This workspace's sidebar terminal isn't open. Ask the person to open it: the Terminal tab in Octet's right-hand panel."
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
        // Each workspace has its own terminal: bring the agent's forward, so
        // the command lands where the person will look.
        let workspace = agentWorkspace(params) ?? target.focusedWorkspace?.workspaceId
        if let workspace, target.focusedWorkspace?.workspaceId != workspace {
            target.steer(toWorkspace: workspace, tab: nil)
        }
        let key = SidebarTerminals.key(workspace)
        target.ui.terminalDrawerVisible = true
        NSApp.requestUserAttention(.informationalRequest)
        Task { @MainActor in
            var view: TerminalEngine.SurfaceView?
            for _ in 0..<30 {
                view = SidebarTerminals.shared.view(for: key)
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
            SidebarSuggestions.shared.set(command, workspace: key)
            reply(["result": ["command": command]])
        }
    }

    // MARK: - Panes in the agent's workspace

    /// A shell pane in the asking agent's workspace that isn't an agent's
    /// (its own prompt is not somewhere to type), or why not.
    private func shellPane(_ paneId: String, params: [String: Any]) -> (pane: EnginePane?, error: String?) {
        guard let store, let pane = store.snapshot.panes.first(where: { $0.paneId == paneId }) else {
            return (nil, "There's no pane \(paneId). Use the id open_terminal returned.")
        }
        guard let workspace = agentWorkspace(params), pane.workspaceId == workspace else {
            return (nil, "Pane \(paneId) isn't in your workspace.")
        }
        if paneId == params["from_pane"] as? String || store.snapshot.agents.contains(where: { $0.paneId == paneId }) {
            return (nil, "Pane \(paneId) is an agent's, not a terminal to type in.")
        }
        return (pane, nil)
    }

    private func readPane(_ paneId: String, lines: Int, params: [String: Any],
                          reply: @escaping ([String: Any]) -> Void, fail: @escaping (String) -> Void) {
        let found = shellPane(paneId, params: params)
        guard found.pane != nil, let client = store?.client else { return fail(found.error ?? "Octet isn't ready.") }
        DispatchQueue.global(qos: .userInitiated).async {
            let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "recent", "lines": lines]))?["read"] as? [String: Any]
            DispatchQueue.main.async {
                guard let text = read?["text"] as? String else { return fail("Couldn't read pane \(paneId).") }
                let tail = TerminalControl.lastLines(text, count: lines)
                let shown = tail.text.isEmpty ? 0 : tail.text.components(separatedBy: "\n").count
                reply(["result": ["text": tail.text, "lines": shown, "total_lines": tail.total,
                                  "title": "pane \(paneId)", "shell_running": true]])
            }
        }
    }

    /// A new shell beside the agent's pane, or in a tab of its own, and
    /// optionally a command typed at its prompt but not run.
    private func open(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void, fail: @escaping (String) -> Void) {
        guard let store else { return fail("Octet isn't ready.") }
        let command = (params["command"] as? String).flatMap(TerminalControl.stagedCommand)
        if params["command"] != nil, command == nil { return fail("That isn't a single plain line of text.") }
        guard let workspace = agentWorkspace(params) ?? WindowRegistry.shared.key?.focusedWorkspace?.workspaceId else {
            return fail("Octet has no workspace open.")
        }
        let snapshot = store.snapshot
        let origin = (params["from_pane"] as? String).flatMap { id in snapshot.panes.first { $0.paneId == id && $0.workspaceId == workspace } }
        var cwd = (params["cwd"] as? String) ?? origin?.effectiveCwd ?? snapshot.directory(ofWorkspace: workspace)
        if let folder = cwd {
            var isFolder: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) || !isFolder.boolValue {
                if params["cwd"] != nil { return fail("There's no folder \(folder).") }
                cwd = nil
            }
        }
        var layout = params["layout"] as? String ?? "right"
        // A conversation has no pane to split beside.
        if origin == nil, layout != "tab" { layout = "tab" }
        let edges: [String: SplitEdge] = ["right": .right, "down": .bottom, "left": .left, "up": .top]
        let sides = store.hasOctetEngine
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var created: EngineCreated?
            var failure: String?
            do {
                if layout == "tab" || origin == nil {
                    var request: [String: Any] = ["workspace_id": workspace, "focus": false]
                    if let cwd { request["cwd"] = cwd }
                    created = EngineCreated(result: try client.call("tab.create", request))
                } else if let origin, let edge = edges[layout] {
                    var request: [String: Any] = ["target_pane_id": origin.paneId, "direction": sides ? edge.rawDirection : edge.split, "focus": false]
                    if let cwd { request["cwd"] = cwd }
                    let split = EngineCreated(result: try client.call("pane.split", request))
                    if !sides, edge.swaps, let pane = split.paneId {
                        try client.call("pane.swap", ["source_pane_id": pane, "target_pane_id": origin.paneId])
                    }
                    created = split
                }
            } catch {
                failure = String(describing: error)
            }
            DispatchQueue.main.async {
                self?.store?.scheduleRefresh()
                guard let paneId = created?.paneId else {
                    return fail("Couldn't open a terminal" + (failure.map { ": \($0)" } ?? "."))
                }
                var answer: [String: Any] = ["pane_id": paneId, "layout": layout == "tab" || origin == nil ? "tab" : layout]
                guard let command else { return reply(["result": answer]) }
                // The shell needs a moment to start reading; typed sooner, the
                // line waits in the terminal's input all the same.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                    let outcome = Result { try client.call("pane.send_text", ["pane_id": paneId, "text": "\u{15}" + command]) }
                    DispatchQueue.main.async {
                        switch outcome {
                        case .success:
                            answer["command"] = command
                            NSApp.requestUserAttention(.informationalRequest)
                            reply(["result": answer])
                        case .failure(let error):
                            reply(["result": answer])
                            ToastCenter.shared.fail(nil, "Couldn't put the command in the new terminal", detail: String(describing: error))
                        }
                    }
                }
            }
        }
    }

    /// Types `command` at a shell pane's prompt, only when a shell is in
    /// front of it, and never presses Return.
    private func queue(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void, fail: @escaping (String) -> Void) {
        guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else { return fail("Give the pane's id.") }
        guard let command = TerminalControl.stagedCommand(params["command"] as? String ?? "") else {
            return fail("That isn't a single plain line of text.")
        }
        let found = shellPane(paneId, params: params)
        guard found.pane != nil, let client = store?.client else { return fail(found.error ?? "Octet isn't ready.") }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<Void, Error> = Result {
                let info = ShellPrompt.parse(try client.call("pane.process_info", ["pane_id": paneId]))
                guard ShellPrompt.isAtPrompt(info) else {
                    let running = info?.foreground.first?.name ?? "something"
                    throw TerminalControl.Failure(message: "Pane \(paneId) is busy running \(running); wait for it to finish or open another terminal.")
                }
                _ = try client.call("pane.send_text", ["pane_id": paneId, "text": "\u{15}" + command])
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    NSApp.requestUserAttention(.informationalRequest)
                    reply(["result": ["command": command]])
                case .failure(let error):
                    fail(String(describing: error))
                }
            }
        }
    }

    /// The workspace the asking agent runs in, from its pane or workspace.
    private func agentWorkspace(_ params: [String: Any]) -> String? {
        if let workspace = params["from_workspace"] as? String, !workspace.isEmpty { return workspace }
        guard let pane = params["from_pane"] as? String else { return nil }
        return store?.snapshot.panes.first { $0.paneId == pane }?.workspaceId
    }

    private func windowShowing(_ params: [String: Any]) -> WindowContext? {
        let registry = WindowRegistry.shared
        return agentWorkspace(params).flatMap { registry.window(showing: $0) } ?? registry.key
    }
}
