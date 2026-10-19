import Foundation
import Combine

/// One setup lifecycle per checkout. Agent continuations are released once,
/// after preparation and (by default) a successful setup process exit.
@MainActor
final class WorktreeSetupRunner: ObservableObject {
    static let shared = WorktreeSetupRunner()
    private static let portsKey = "octet.worktreeSetup.ports"
    private static let trustedKey = "octet.worktreeSetup.trustedRepos"
    private static let statesKey = "octet.worktreeSetup.states"
    private let defaults: UserDefaults
    private let enabled: @MainActor () -> Bool
    private let logsDirectory: URL?
    @Published private(set) var states: [String: WorkspaceSetupState] = [:]
    private var continuations: [String: () -> Void] = [:]
    private var retries: [String: () -> Void] = [:]
    private var processes: [String: Process] = [:]

    init(defaults: UserDefaults = .standard, logsDirectory: URL? = nil,
         enabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.values.worktreeSetup }) {
        self.defaults = defaults; self.logsDirectory = logsDirectory; self.enabled = enabled
        if let data = defaults.data(forKey: Self.statesKey),
           let saved = try? JSONDecoder().decode([String: WorkspaceSetupState].self, from: data) {
            states = saved.filter { FileManager.default.fileExists(atPath: $0.key) }
            for key in Array(states.keys) where states[key]?.active == true {
                states[key]?.phase = .failed
                states[key]?.detail = "Octet closed before setup completion was observed. Inspect the log before retrying."
            }
        }
    }

    func state(for directory: String?) -> WorkspaceSetupState? {
        guard let directory else { return nil }
        return states.values.filter { directory == $0.checkout || directory.hasPrefix($0.checkout + "/") }
            .max { $0.checkout.count < $1.checkout.count }
    }

    func retry(_ checkout: String, store: SessionStore) {
        guard states[checkout]?.active != true else { return }
        if let retry = retries[checkout] { retry(); return }
        guard let linked = WorktreeSetup.linkedWorktree(containing: checkout,
            exists: { FileManager.default.fileExists(atPath: $0) },
            read: { try? String(contentsOfFile: $0, encoding: .utf8) }) else { return }
        prepare(.init(repoRoot: linked.repoRoot, checkoutPath: linked.checkout, paneId: nil), store: store)
    }

    func run(after result: [String: Any], store: SessionStore, whenReady: (() -> Void)? = nil) {
        guard let created = WorktreeSetup.parse(result) else { whenReady?(); return }
        if let whenReady { continuations[created.checkoutPath] = whenReady }
        if states[created.checkoutPath]?.active != true {
            let previous = defaults.stringArray(forKey: "octet.worktreeSetup.defaultTabs") ?? []
            defaults.set(previous.filter { $0 != created.checkoutPath }, forKey: "octet.worktreeSetup.defaultTabs")
        }
        let workspace = EngineCreated(result: result).workspaceId
            ?? store.snapshot.workspaces.first(where: { store.snapshot.directory(ofWorkspace: $0.workspaceId) == created.checkoutPath })?.workspaceId
        prepare(created, workspaceId: workspace, store: store)
    }

    func runInNewTab(_ script: WorktreeSetup.Script, repoRoot: String, checkout: String, store: SessionStore) {
        prepare(.init(repoRoot: repoRoot, checkoutPath: checkout, paneId: nil), store: store, override: script)
    }

    private func update(_ state: WorkspaceSetupState) {
        states[state.checkout] = state
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Self.statesKey) }
    }

    private func release(_ checkout: String) { continuations.removeValue(forKey: checkout)?() }

    private func prepare(_ created: WorktreeSetup.Created, workspaceId: String? = nil, store: SessionStore,
                         override: WorktreeSetup.Script? = nil) {
        let checkout = created.checkoutPath
        guard states[checkout]?.active != true else { return }
        retries[checkout] = { [weak self, weak store] in
            guard let self, let store else { return }
            self.prepare(created, workspaceId: workspaceId, store: store, override: override)
        }
        AgentWorktreeWatcher.shared.markHandled(checkout)
        guard enabled() else {
            update(.init(checkout: checkout, phase: .skipped, detail: "Worktree setup is disabled in Settings."))
            release(checkout); return
        }
        update(.init(checkout: checkout, phase: .preparing))
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let config = try ProjectConfiguration.load(checkout: checkout, root: created.repoRoot)
                    _ = try ProjectWorkspaceFiles.materialize(config, root: created.repoRoot, checkout: checkout)
                    try WorktreeSetup.copyEnvFilesChecked(from: created.repoRoot, to: checkout)
                    let script: WorktreeSetup.Script?
                    if let setup = config.setup {
                        script = setup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .command(setup)
                    } else {
                        script = override ?? WorktreeSetup.script(in: checkout,
                            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                            read: { FileManager.default.contents(atPath: $0) })
                    }
                    return (config, script)
                }.value
                let (config, script) = prepared
                let tabs = config.defaultTabs ?? []
                let ready = { [weak self, weak store] in
                    guard let self else { return }
                    let opened = Set(self.defaults.stringArray(forKey: "octet.worktreeSetup.defaultTabs") ?? [])
                    if let store, let workspaceId, !opened.contains(checkout), !tabs.isEmpty {
                        self.defaults.set(Array(opened.union([checkout])), forKey: "octet.worktreeSetup.defaultTabs")
                        for tab in tabs {
                            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                            let params: [String: Any] = ["workspace_id": workspaceId, "focus": false,
                                "tab_label": tab.title, "root": ["type": "pane", "cwd": checkout,
                                "command": [shell, "-l", "-c", tab.command]]]
                            store.call("layout.apply", params, failure: "Couldn't open \(tab.title)", then: { _ in })
                        }
                    }
                    self.release(checkout)
                }
                guard script != nil || !tabs.isEmpty else {
                    update(.init(checkout: checkout, phase: .ready)); ready(); return
                }
                let start = { [weak self] in
                    guard let self else { return }
                    if let script { self.execute(script, created: created, wait: config.waitForSetup ?? true, ready: ready) }
                    else { self.update(.init(checkout: checkout, phase: .ready)); ready() }
                }
                if trusted.contains(created.repoRoot) { start(); return }
                update(.init(checkout: checkout, phase: .awaitingApproval))
                var commands = tabs.map { "\($0.title): \($0.command)" }
                if let script { commands.insert(String(describing: script), at: 0) }
                ConfirmCenter.shared.ask(.init(title: "Run this project's setup?",
                    message: "Setup and default tabs from \(URL(fileURLWithPath: checkout).lastPathComponent).",
                    detail: commands.joined(separator: "\n"), confirmTitle: "Run", cancelTitle: "Keep waiting",
                    suppressTitle: "Always allow this repository",
                    onConfirm: { [weak self] always in
                        if always { self?.trust(created.repoRoot) }; start()
                    }, onCancel: { [weak self] in
                        self?.update(.init(checkout: checkout, phase: .failed, detail: "Setup was not approved. Retry when ready."))
                    }))
            } catch { failed(checkout, error.localizedDescription) }
        }
    }

    private func execute(_ script: WorktreeSetup.Script, created: WorktreeSetup.Created,
                         wait: Bool, ready: @escaping () -> Void) {
        let checkout = created.checkoutPath
        do {
            let logs = logsDirectory ?? EngineSession.supportDirectory.appendingPathComponent("setup-logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent(UUID().uuidString + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-l", "-c", WorktreeSetup.commandLine(script, created: created,
                port: assignPort(to: checkout), quote: shellQuote)]
            process.currentDirectoryURL = URL(fileURLWithPath: checkout)
            process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                try? output.close()
                Task { @MainActor in
                    guard let self else { return }
                    self.processes[checkout] = nil
                    if process.terminationStatus == 0 {
                        self.update(.init(checkout: checkout, phase: .ready, logPath: log.path))
                        ToastCenter.shared.succeed(nil, "Workspace ready", detail: URL(fileURLWithPath: checkout).lastPathComponent)
                        ready()
                    } else {
                        self.failed(checkout, "Setup exited with status \(process.terminationStatus).", logPath: log.path)
                    }
                }
            }
            update(.init(checkout: checkout, phase: .running, logPath: log.path))
            do { try process.run() } catch { try? output.close(); throw error }
            processes[checkout] = process
            if !wait { release(checkout) }
        } catch { failed(checkout, error.localizedDescription) }
    }

    private func failed(_ checkout: String, _ detail: String, logPath: String? = nil) {
        update(.init(checkout: checkout, phase: .failed, detail: detail, logPath: logPath))
        ToastCenter.shared.fail(nil, "Workspace setup failed", detail: detail,
            action: .init(title: "Retry") { [weak self] in self?.retries[checkout]?() })
    }

    // MARK: - Env files

    static func list(_ files: [String]) -> String {
        files.count <= 3 ? files.joined(separator: ", ") : "\(files.count) env files"
    }

    // MARK: - Ports and trust

    /// The worktree's port block, kept while the worktree exists.
    private func assignPort(to checkout: String) -> Int? {
        var assigned = (defaults.dictionary(forKey: Self.portsKey) as? [String: Int] ?? [:])
            .filter { FileManager.default.fileExists(atPath: $0.key) }
        let port = WorktreeSetup.port(for: checkout, assigned: assigned)
        if let port { assigned[checkout] = port }
        defaults.set(assigned, forKey: Self.portsKey)
        return port
    }

    private var trusted: Set<String> {
        Set(defaults.stringArray(forKey: Self.trustedKey) ?? [])
    }

    private func trust(_ repoRoot: String) {
        defaults.set(Array(trusted.union([repoRoot])).sorted(), forKey: Self.trustedKey)
    }
}
