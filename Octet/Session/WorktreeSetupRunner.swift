import Foundation

/// Readies a worktree Octet just created, as `WorktreeSetup` describes: env
/// files copied from the main checkout, a port block, and the project's
/// setup script typed into the new pane. A project's script runs only once
/// you've said so for that repository.
@MainActor
final class WorktreeSetupRunner {
    static let shared = WorktreeSetupRunner()

    private static let portsKey = "octet.worktreeSetup.ports"
    private static let trustedKey = "octet.worktreeSetup.trustedRepos"

    func run(after result: [String: Any], store: SessionStore) {
        guard SettingsStore.shared.values.worktreeSetup, let created = WorktreeSetup.parse(result) else { return }
        AgentWorktreeWatcher.shared.markHandled(created.checkoutPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let copied = WorktreeSetup.copyEnvFiles(from: created.repoRoot, to: created.checkoutPath)
            let script = WorktreeSetup.script(
                in: created.checkoutPath,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                read: { FileManager.default.contents(atPath: $0) }
            )
            DispatchQueue.main.async {
                let name = URL(fileURLWithPath: created.checkoutPath).lastPathComponent
                if !copied.isEmpty {
                    ToastCenter.shared.succeed(nil, "Copied \(Self.list(copied)) into \(name)")
                }
                guard let script, let paneId = created.paneId else { return }
                self.runWhenTrusted(script, created: created, paneId: paneId, store: store)
            }
        }
    }

    /// Runs a worktree's setup script in a new tab of its own: for a
    /// worktree an agent made, whose pane the agent is using.
    func runInNewTab(_ script: WorktreeSetup.Script, repoRoot: String, checkout: String, store: SessionStore) {
        var params: [String: Any] = ["cwd": checkout, "focus": true, "label": "Setup"]
        if let workspace = store.focusedWorkspace { params["workspace_id"] = workspace.workspaceId }
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let paneId = (try? client.call("tab.create", params))
                .flatMap { ($0["root_pane"] as? [String: Any])?["pane_id"] as? String }
            DispatchQueue.main.async {
                guard let paneId else {
                    ToastCenter.shared.fail(nil, "Couldn't open a tab for the setup")
                    return
                }
                self.runWhenTrusted(script, created: .init(repoRoot: repoRoot, checkoutPath: checkout, paneId: paneId),
                                    paneId: paneId, store: store)
            }
        }
    }

    private func runWhenTrusted(_ script: WorktreeSetup.Script, created: WorktreeSetup.Created,
                                paneId: String, store: SessionStore) {
        let start = { [weak self] in
            guard let self else { return }
            let line = WorktreeSetup.commandLine(script, created: created,
                                                 port: self.assignPort(to: created.checkoutPath), quote: shellQuote)
            store.runInPane(paneId, line: line)
        }
        if trusted.contains(created.repoRoot) { return start() }
        let repo = URL(fileURLWithPath: created.repoRoot).lastPathComponent
        let what: String
        switch script {
        case .file(let path): what = path
        case .command(let command): what = command
        }
        ConfirmCenter.shared.ask(
            title: "Run \(repo)'s worktree setup?",
            message: "The new worktree asks to run this in its terminal. Run it only if you trust this repository.",
            detail: what,
            confirmTitle: "Run",
            suppressTitle: "Always run setup for \(repo)"
        ) { [weak self] always in
            if always { self?.trust(created.repoRoot) }
            start()
        }
    }

    // MARK: - Env files

    static func list(_ files: [String]) -> String {
        files.count <= 3 ? files.joined(separator: ", ") : "\(files.count) env files"
    }

    // MARK: - Ports and trust

    /// The worktree's port block, kept while the worktree exists.
    private func assignPort(to checkout: String) -> Int? {
        let defaults = UserDefaults.standard
        var assigned = (defaults.dictionary(forKey: Self.portsKey) as? [String: Int] ?? [:])
            .filter { FileManager.default.fileExists(atPath: $0.key) }
        let port = WorktreeSetup.port(for: checkout, assigned: assigned)
        if let port { assigned[checkout] = port }
        defaults.set(assigned, forKey: Self.portsKey)
        return port
    }

    private var trusted: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? [])
    }

    private func trust(_ repoRoot: String) {
        UserDefaults.standard.set(Array(trusted.union([repoRoot])).sorted(), forKey: Self.trustedKey)
    }
}
