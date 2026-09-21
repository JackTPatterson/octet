import AppKit
import Foundation

/// Claude Code's agent view, natively: every background and interactive
/// session from `claude agents`, each one's latest message read from its
/// log, and the actions the CLI offers (dispatch, attach, stop, remove),
/// plus moving a Herd conversation into the background and back.
@MainActor
final class AgentsStore: ObservableObject {
    static let shared = AgentsStore()

    @Published private(set) var agents: [BackgroundAgent] = []
    @Published private(set) var lastLines: [String: String] = [:]
    @Published private(set) var loaded = false
    @Published var lastError: String?
    /// Faster polling while the board is on screen.
    var watching = false { didSet { if watching { refresh() } } }

    private var timer: Timer?
    private var refreshing = false
    private var lineStamps: [String: Date] = [:]

    var needsInput: [BackgroundAgent] { agents.filter { $0.kind == .background && $0.state == .needsInput } }
    var working: [BackgroundAgent] { agents.filter { $0.kind == .background && $0.state == .working } }
    var finished: [BackgroundAgent] { agents.filter { $0.kind == .background && ($0.state == .done || $0.state == .idle) } }
    var interactive: [BackgroundAgent] { agents.filter { $0.kind == .interactive } }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = AgentsStore.shared
                // Every 3s on the board; every 30s otherwise, for the badge.
                if store.watching || Int(Date().timeIntervalSince1970) % 30 < 3 { store.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let stamps = lineStamps
        DispatchQueue.global(qos: .utility).async {
            let result = LoginShell.run(["claude", "agents", "--json", "--all"])
            let agents = result.status == 0 ? BackgroundAgent.parse(Data(result.output.utf8)) : []
            // Latest message per session, re-read only when its log changed.
            var lines: [String: (String, Date)] = [:]
            for agent in agents {
                // A background job says what it's doing in its own state file.
                if agent.kind == .background, let job = BackgroundJob.load(id: agent.id),
                   let line = agent.state == .needsInput ? (job.needs ?? job.detail) : (job.detail ?? job.needs) {
                    lines[agent.sessionId] = (plainPreview(line), Date())
                    continue
                }
                guard let path = Self.logPath(for: agent),
                      let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      stamps[agent.sessionId] != modified,
                      let line = Self.lastLine(path: path) else { continue }
                lines[agent.sessionId] = (plainPreview(line), modified)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = AgentsStore.shared
                    store.refreshing = false
                    store.loaded = true
                    if result.status != 0 {
                        store.lastError = result.output.isEmpty ? "claude agents failed" : String(result.output.prefix(300))
                        return
                    }
                    store.lastError = nil
                    if store.agents != agents { store.agents = agents }
                    for (session, entry) in lines {
                        store.lastLines[session] = entry.0
                        store.lineStamps[session] = entry.1
                    }
                }
            }
        }
    }

    /// The session's conversation log; a background job's may be under its
    /// resume session.
    nonisolated static func logPath(for agent: BackgroundAgent) -> String? {
        var ids = [agent.sessionId]
        if agent.kind == .background, let resume = BackgroundJob.load(id: agent.id)?.logSessionId, resume != agent.sessionId {
            ids.append(resume)
        }
        return AgentConversation.findLog(sessionIds: ids, cwd: agent.cwd)
    }

    /// The last thing Claude said, as one line, from the tail of the log.
    nonisolated static func lastLine(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let conversation = AgentConversation.replay(lines: text.components(separatedBy: "\n"))
        for item in conversation.items.reversed() {
            if case .text(let body) = item.kind,
               let line = body.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return String(line.prefix(200))
            }
        }
        return nil
    }

    // MARK: - Actions

    /// Starts a new background session on `task` in `cwd`.
    func dispatch(task: String, cwd: String, model: String, effort: String?, mode: String) {
        var arguments = ["claude", "--bg", "--model", model, "--permission-mode", mode]
        if let effort, AgentSession.supportsEffort(model: model) { arguments += ["--effort", effort] }
        arguments.append(task)
        run(arguments, in: cwd, failure: "Couldn't start the background session")
    }

    func stop(_ agent: BackgroundAgent) {
        run(["claude", "stop", agent.id], failure: "Couldn't stop \(agent.name)")
    }

    func remove(_ agent: BackgroundAgent) {
        run(["claude", "rm", agent.id], failure: "Couldn't remove \(agent.name)")
    }

    /// Continues a background session in Claude Code's own interface, in a
    /// new tab of the workspace for its folder.
    func attach(_ agent: BackgroundAgent, client: EngineClient, workspaceId: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var params: [String: Any] = [
            "focus": true,
            "tab_label": agent.name,
            "root": ["type": "pane", "label": agent.name, "cwd": agent.cwd,
                     "command": [shell, "-lic", "claude attach \(agent.id); exec \(shell) -l"]] as [String: Any],
        ]
        if let workspaceId { params["workspace_id"] = workspaceId }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.call("layout.apply", params)
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentCenter.shared.showingBoard = false; AgentCenter.shared.activeId = nil } }
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't open \(agent.name) in a terminal", detail: String(describing: error))
                }
            }
        }
    }

    /// Stops the background run and continues the session here, natively.
    func bringBack(_ agent: BackgroundAgent, workspaceId: String) {
        // Resume the session whose log actually holds the conversation.
        let logId = Self.logPath(for: agent).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? agent.sessionId
        let saved = AgentSession.Saved(sessionId: logId, cwd: agent.cwd, title: agent.name,
                                       model: "claude-sonnet-5", effort: nil, permissionMode: AgentSession.PermissionMode.auto.rawValue,
                                       hasTurns: true)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LoginShell.run(["claude", "stop", agent.id])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentCenter.shared.adopt(AgentSession.restore(saved, workspaceId: workspaceId))
                    AgentsStore.shared.refresh()
                }
            }
        }
    }

    private func run(_ arguments: [String], in directory: String? = nil, failure: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(arguments, in: directory)
            DispatchQueue.main.async {
                if result.status != 0 { ToastCenter.shared.fail(nil, failure, detail: result.output) }
                MainActor.assumeIsolated { AgentsStore.shared.refresh() }
            }
        }
    }
}
