import Foundation

/// Codex's sessions for the Codex agents board, from its state database
/// and rollout logs, with the actions its CLI offers: queue a message,
/// resume, archive, delete, and start a new task.
@MainActor
final class CodexAgentsStore: ObservableObject {
    static let shared = CodexAgentsStore()

    @Published private(set) var agents: [BackgroundAgent] = []
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var loaded = false
    @Published var lastError: String?
    private(set) var rolloutPaths: [String: String] = [:]
    var watching = false { didSet { if watching { refresh() } } }
    private var timer: Timer?
    private var refreshing = false

    var needsInput: [BackgroundAgent] { agents.filter { $0.state == .needsInput } }
    var working: [BackgroundAgent] { agents.filter { $0.state == .working } }
    var finished: [BackgroundAgent] { agents.filter { $0.state == .done || $0.state == .idle } }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = CodexAgentsStore.shared
                if store.watching || Int(Date().timeIntervalSince1970) % 30 < 3 { store.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        guard !refreshing, let database = CodexThreads.databasePath() else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-readonly", "-json", database, CodexThreads.query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            var threads: [CodexThreads.Thread] = []
            var failure: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                threads = CodexThreads.parse(data)
                if process.terminationStatus != 0 { failure = "Couldn't read Codex's sessions" }
            } catch {
                failure = error.localizedDescription
            }
            let agents = threads.map { thread -> BackgroundAgent in
                let modified = (try? FileManager.default.attributesOfItem(atPath: thread.rolloutPath))?[.modificationDate] as? Date
                let state = CodexThreads.state(tail: CodexThreads.tail(path: thread.rolloutPath, bytes: 60_000), modified: modified)
                return BackgroundAgent(id: thread.id, sessionId: thread.id, name: thread.name, cwd: thread.cwd,
                                       kind: .background, state: state, startedAt: modified ?? thread.updatedAt, pid: nil)
            }
            let previews = Dictionary(threads.map { ($0.id, plainPreview($0.preview)) }, uniquingKeysWith: { first, _ in first })
            let paths = Dictionary(threads.map { ($0.id, $0.rolloutPath) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = CodexAgentsStore.shared
                    store.refreshing = false
                    store.loaded = true
                    store.lastError = failure
                    if store.agents != agents { store.agents = agents }
                    store.previews = previews
                    store.rolloutPaths = paths
                }
            }
        }
    }

    /// Sends a message to a session; Codex delivers it when the session
    /// next takes input.
    func reply(_ agent: BackgroundAgent, message: String) {
        run(["codex", "queue", "--thread", agent.id, "--message", message], failure: "Couldn't queue the message")
    }

    func archive(_ agent: BackgroundAgent) {
        run(["codex", "archive", agent.id], failure: "Couldn't archive \(agent.name)")
    }

    func delete(_ agent: BackgroundAgent) {
        run(["codex", "delete", agent.id], failure: "Couldn't delete \(agent.name)")
    }

    /// Runs a new task non-interactively in `cwd`; it shows up as a session.
    func start(task: String, cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["codex", "exec", "--skip-git-repo-check", task], in: cwd)
            DispatchQueue.main.async {
                if result.status != 0 { ToastCenter.shared.fail(nil, "The Codex task didn't finish", detail: String(result.output.suffix(400))) }
                MainActor.assumeIsolated { CodexAgentsStore.shared.refresh() }
            }
        }
        // It appears in the list as soon as Codex records it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { CodexAgentsStore.shared.refresh() } }
    }

    /// Continues the session in Codex's own interface, in a new tab.
    func resume(_ agent: BackgroundAgent, client: EngineClient, workspaceId: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var params: [String: Any] = [
            "focus": true, "tab_label": agent.name,
            "root": ["type": "pane", "label": agent.name, "cwd": agent.cwd,
                     "command": [shell, "-lic", "codex resume \(agent.id); exec \(shell) -l"]] as [String: Any],
        ]
        if let workspaceId { params["workspace_id"] = workspaceId }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.call("layout.apply", params)
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentCenter.shared.board = nil } }
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't open \(agent.name) in a terminal", detail: String(describing: error))
                }
            }
        }
    }

    private func run(_ arguments: [String], failure: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(arguments)
            DispatchQueue.main.async {
                if result.status != 0 { ToastCenter.shared.fail(nil, failure, detail: result.output) }
                MainActor.assumeIsolated { CodexAgentsStore.shared.refresh() }
            }
        }
    }
}
