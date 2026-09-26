import Foundation

/// Starts a best-of-N task and keeps its attempts for comparing: one
/// worktree per agent from the same commit, the main checkout's env files
/// copied in, and the agent started on the task. See `BestOfN`.
@MainActor
final class BestOfNCenter: ObservableObject {
    static let shared = BestOfNCenter()
    private static let key = "octet.bestOfN.attempts"

    @Published private(set) var attempts: [BestOfN.Attempt] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([BestOfN.Attempt].self, from: data) {
            attempts = saved.filter { FileManager.default.fileExists(atPath: $0.checkout) }
        }
    }

    /// The agents that can take part, as discovery found them.
    var runners: [BestOfN.Runner] {
        #if DEBUG
        // Testing: stand-in agents, "claude=/path/to/script,codex=/path".
        if let stubs = ProcessInfo.processInfo.environment["OCTET_BEST_OF_N_RUNNERS"] {
            return BestOfN.plan(stubs.split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? BestOfN.Runner(id: parts[0], name: parts[0], executable: parts[1]) : nil
            })
        }
        #endif
        return BestOfN.plan(AgentDiscoveryStore.shared.agents.compactMap { agent in
            agent.executablePath.map { BestOfN.Runner(id: agent.id, name: agent.displayName, executable: $0) }
        })
    }

    func start(task: String, in workspaceId: String, store: SessionStore) {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let runners = self.runners
        guard !task.isEmpty else { return }
        guard !runners.isEmpty else {
            ToastCenter.shared.info("No agent to try it", detail: "Best of N runs Claude Code and Codex; neither was found.")
            return
        }
        guard let directory = store.snapshot.directory(ofWorkspace: workspaceId) else { return }
        let toast = ToastCenter.shared.progress("Starting \(runners.count) attempts…")
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Git()
            // The main checkout, even from inside one of its worktrees.
            let common = try? git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
            let top = common.flatMap { $0.hasSuffix("/.git") ? String($0.dropLast(5)) : nil } ?? git.topLevel(directory)
            // Worktrees start from the main checkout's HEAD.
            let base = top.flatMap { try? git.run(["rev-parse", "HEAD"], in: $0) }
            let existing = top.flatMap { try? git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/try/"], in: $0) }
            DispatchQueue.main.async {
                guard let top, let base, !base.isEmpty else {
                    ToastCenter.shared.fail(toast, "Best of N needs a git repository with a commit",
                                            detail: "Each attempt is a worktree from the current commit.")
                    return
                }
                ToastCenter.shared.dismiss(handleId: toast)
                let taken = Set((existing ?? "").split(separator: "\n").map(String.init))
                let branches = BestOfN.branches(task: task, runners: runners, existing: taken)
                for (runner, branch) in zip(runners, branches) {
                    self.startAttempt(runner, branch: branch, task: task, base: base, root: top, store: store)
                }
                ToastCenter.shared.info("\(runners.count) agents are trying it",
                                        detail: "Each in a worktree of its own. Palette › Compare Attempts when they're done.",
                                        after: 8)
            }
        }
    }

    private func startAttempt(_ runner: BestOfN.Runner, branch: String, task: String, base: String, root: String,
                              store: SessionStore) {
        // By the repository's folder: the session server makes worktrees
        // only from the main checkout, and the workspace in front may be a
        // worktree itself.
        let params: [String: Any] = ["branch": branch, "cwd": root, "focus": false]
        store.call("worktree.create", params, failure: "Couldn't make a worktree for \(runner.name)", result: { [weak self] result in
            guard let self, let created = WorktreeSetup.parse(result) else { return }
            AgentWorktreeWatcher.shared.markHandled(created.checkoutPath)
            let attempt = BestOfN.Attempt(task: task, agent: runner.name, branch: branch, checkout: created.checkoutPath,
                                          base: base, started: Date())
            self.attempts.append(attempt)
            self.save()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = WorktreeSetup.copyEnvFiles(from: root, to: created.checkoutPath)
                DispatchQueue.main.async {
                    guard let pane = created.paneId else { return }
                    store.runInPane(pane, line: BestOfN.command(for: runner, task: task, quote: shellQuote))
                }
            }
        }, then: { _ in })
    }

    /// The attempts at the latest task first, each task's in the order started.
    var byTask: [(task: String, attempts: [BestOfN.Attempt])] {
        let live = attempts.filter { FileManager.default.fileExists(atPath: $0.checkout) }
        var order: [String] = []
        for attempt in live.sorted(by: { $0.started > $1.started }) where !order.contains(attempt.task) {
            order.append(attempt.task)
        }
        return order.map { task in (task, live.filter { $0.task == task }.sorted { $0.started < $1.started }) }
    }

    func forget(task: String) {
        attempts.removeAll { $0.task == task }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(attempts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
