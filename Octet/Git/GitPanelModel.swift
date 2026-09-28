import Foundation

/// The git panel's data, for the agent in front: its tab, the tabs of the
/// subagents it launched, the checkouts they're all working in, and the
/// other worktrees of the same repository with whoever is working there.
@MainActor
final class GitPanelModel: ObservableObject {
    /// An agent (or a plain shell) working in a checkout.
    struct Worker: Equatable, Identifiable {
        let paneId: String
        let tabId: String
        let workspaceId: String
        /// The agent's id for its mark; nil for a shell.
        let agent: String?
        let name: String
        let isSubagent: Bool

        var id: String { paneId }
        /// A subagent's viewer only watches; prompts go to real sessions.
        var takesPrompts: Bool { agent != nil && !isSubagent }
    }

    struct Group: Equatable, Identifiable {
        var checkout: AgentGit.Checkout
        var workers: [Worker]

        var id: String { checkout.top }
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var worktrees: [AgentGit.Worktree] = []
    /// Who is working in each worktree, anywhere in the session.
    @Published private(set) var worktreeWorkers: [String: [Worker]] = [:]
    /// Whether anything in front is in a repository, for the tab bar button.
    @Published private(set) var hasRepository = false
    @Published private(set) var loading = false

    private weak var window: WindowContext?
    private var timer: Timer?
    private var generation = 0
    private var reading = false
    /// Folder → its checkout's top level, so a refresh doesn't ask git again.
    private var tops: [String: String?] = [:]
    static let interval: TimeInterval = 4

    /// Changed files across the checkouts, for the button.
    var changedFiles: Int { groups.reduce(0) { $0 + $1.checkout.files.count } }

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The panes in scope: the tab in front, its root agent's tab, and every
    /// subagent tab launched from that root.
    private func scope() -> [(worker: Worker, directory: String)] {
        guard let window, let tabId = window.displayedFocusedTabId,
              let workspaceId = window.focusedWorkspace?.workspaceId else { return [] }
        let snapshot = window.store.snapshot
        let root = snapshot.rootTabId(ofTab: tabId)
        let tabs = snapshot.tabs(inWorkspace: workspaceId).filter { snapshot.rootTabId(ofTab: $0.tabId) == root }
        return tabs.flatMap { tab in
            snapshot.panes.filter { $0.tabId == tab.tabId }.compactMap { pane in
                guard let directory = snapshot.workingDirectory(ofPane: pane.paneId) else { return nil }
                return (worker: worker(pane: pane, tab: tab, snapshot: snapshot), directory: directory)
            }
        }
    }

    private func worker(pane: EnginePane, tab: EngineTab, snapshot: EngineSnapshot) -> Worker {
        let agent = snapshot.agents.first { $0.paneId == pane.paneId && $0.agent != nil }
        let brand = AgentBrand.forAgent(agent?.agent)
        let tabName = TabAutoName.display(label: tab.label, number: tab.number)
        let isSubagent = agent?.isSubagentViewer == true
        return Worker(paneId: pane.paneId, tabId: tab.tabId, workspaceId: pane.workspaceId,
                      agent: brand?.id ?? agent?.agent,
                      name: isSubagent ? tabName : brand?.displayName ?? tabName,
                      isSubagent: isSubagent)
    }

    /// Everyone in the session, for the worktree map.
    private func everyone() -> [(worker: Worker, directory: String)] {
        guard let snapshot = window?.store.snapshot else { return [] }
        return snapshot.agents.compactMap { agent in
            guard agent.agent != nil,
                  let pane = snapshot.panes.first(where: { $0.paneId == agent.paneId }),
                  let tab = snapshot.tabs.first(where: { $0.tabId == pane.tabId }),
                  let directory = snapshot.workingDirectory(ofPane: pane.paneId) else { return nil }
            return (worker: worker(pane: pane, tab: tab, snapshot: snapshot), directory: directory)
        }
    }

    func refresh() {
        guard let window else { return }
        let scoped = scope()
        // Hidden, only whether there's a repository at all, from files.
        guard window.ui.gitPanelVisible else {
            let has = scoped.contains { GitBranch.location(for: $0.directory) != nil }
            if has != hasRepository { hasRepository = has }
            return
        }
        guard !reading else { return }
        reading = true
        if groups.isEmpty { loading = true }
        generation += 1
        let generation = self.generation
        let sessionWide = everyone()
        let known = tops
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Git()
            var tops = known
            func topLevel(of directory: String) -> String? {
                if let known = tops[directory] { return known }
                let found = git.topLevel(directory)
                tops[directory] = found
                return found
            }
            // One group per checkout, in the order its workers appear.
            var order: [String] = []
            var workers: [String: [Worker]] = [:]
            for (worker, directory) in scoped {
                guard let top = topLevel(of: directory) else { continue }
                if workers[top] == nil { order.append(top) }
                if !(workers[top]?.contains(where: { $0.paneId == worker.paneId }) ?? false) {
                    workers[top, default: []].append(worker)
                }
            }
            let groups = order.compactMap { top in
                AgentGit.read(top: top, git: git).map { Group(checkout: $0, workers: workers[top] ?? []) }
            }
            let worktrees = order.first.map { AgentGit.worktrees(top: $0, git: git) } ?? []
            // Each worker sits in the deepest worktree containing it.
            var byWorktree: [String: [Worker]] = [:]
            for (worker, directory) in sessionWide {
                let home = worktrees.filter { directory == $0.path || directory.hasPrefix($0.path + "/") }
                    .max { $0.path.count < $1.path.count }
                if let home { byWorktree[home.path, default: []].append(worker) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    self.loading = false
                    self.tops = tops
                    guard generation == self.generation else { return }
                    if groups != self.groups { self.groups = groups }
                    if worktrees != self.worktrees { self.worktrees = worktrees }
                    if byWorktree != self.worktreeWorkers { self.worktreeWorkers = byWorktree }
                    let has = !groups.isEmpty
                    if has != self.hasRepository { self.hasRepository = has }
                }
            }
        }
    }

    // MARK: - Actions

    /// Opens the changes review over the terminal, at `path` when given.
    func review(_ top: String, path: String? = nil, since commit: AgentGit.Commit? = nil) {
        guard let window else { return }
        let model = commit.map {
            DiffReviewModel(directory: top, since: .since(commit: $0.sha + "^", name: "before \($0.shortSha)"))
        } ?? DiffReviewModel(directory: top)
        model.selectedPath = path
        window.ui.review = model
    }

    /// Hands a git chore to the checkout's agent as a prompt.
    func handoff(_ handoff: AgentGitHandoff, in group: Group) {
        guard let target = promptTarget(in: group.workers) else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in this tab, then try again.")
            return
        }
        send(handoff.prompt(checkout: group.checkout), to: target)
    }

    /// Asks the agent in front to merge another worktree's branch.
    func merge(_ worktree: AgentGit.Worktree) {
        let workers = groups.first?.workers ?? []
        guard let target = promptTarget(in: workers) ?? promptTarget(in: worktreeWorkers[worktree.path] ?? []) else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in this tab, then try again.")
            return
        }
        send(AgentGitHandoff.mergePrompt(worktree: worktree, base: groups.first?.checkout.base), to: target)
    }

    private func promptTarget(in workers: [Worker]) -> Worker? {
        workers.first(where: \.takesPrompts)
    }

    private func send(_ prompt: String, to worker: Worker) {
        window?.store.broadcast(prompt, to: [Broadcast.Target(paneId: worker.paneId, name: worker.name, isAgent: true)])
    }

    func toggleStaged(_ file: AgentGit.FileChange, in top: String) {
        runGit(failure: "Couldn't \(file.staged ? "unstage" : "stage") \(file.path)") {
            if file.staged { try ReviewDiff.unstage(path: file.path, in: top) } else { try ReviewDiff.stage(path: file.path, in: top) }
        }
    }

    /// Throws a file's changes away, after a checkpoint so it can be undone.
    func discard(_ file: AgentGit.FileChange, in top: String) {
        ConfirmCenter.shared.ask(
            title: "Discard the changes to \((file.path as NSString).lastPathComponent)?",
            message: file.kind == .untracked
                ? "The file is deleted. A checkpoint is taken first, so this can be undone."
                : "It goes back to the last commit. A checkpoint is taken first, so this can be undone.",
            items: [file.path],
            confirmTitle: "Discard",
            destructive: true
        ) { [weak self] _ in
            self?.runGit(failure: "Couldn't discard \(file.path)") { () throws -> Checkpoint? in
                let git = Git()
                let checkpoint = Checkpoints.create(in: top, label: "Before discarding \(file.path)", force: true, git: git)
                if file.kind == .untracked {
                    try FileManager.default.removeItem(atPath: (top as NSString).appendingPathComponent(file.path))
                } else if file.kind == .added {
                    try git.run(["rm", "-q", "-f", "--", file.path], in: top)
                } else {
                    try git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", file.path], in: top)
                }
                return checkpoint
            } done: { checkpoint in
                guard let checkpoint else { return }
                ToastCenter.shared.info("Discarded \(file.path)", after: 8,
                                        action: .init(title: "Undo") { CheckpointActions.restore(checkpoint, in: top) })
            }
        }
    }

    func restore(_ checkpoint: Checkpoint, in top: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let changed = Checkpoints.changes(since: checkpoint, in: top)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CheckpointActions.confirmRestore(checkpoint, changed: changed, in: top) }
            }
        }
    }

    func cleanUp(_ worktree: AgentGit.Worktree, from top: String) {
        guard let window else { return }
        let listed = WorktreeCleanup.Worktree(path: worktree.path, branch: worktree.branch, isMain: worktree.isMain,
                                              merged: worktree.merged, dirty: worktree.dirty)
        WorktreeCleanupActions.confirm([listed], directory: top, window: window)
    }

    /// Brings a worker's tab forward.
    func show(_ worker: Worker) {
        guard let window, let tab = window.store.snapshot.tabs.first(where: { $0.tabId == worker.tabId }) else { return }
        window.focusTabAnywhere(tab)
    }

    private func runGit(failure: String, _ work: @escaping () throws -> Void) {
        runGit(failure: failure, { try work(); return () }, done: { _ in })
    }

    private func runGit<T>(failure: String, _ work: @escaping () throws -> T, done: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch outcome {
                    case .success(let value): done(value)
                    case .failure(let error): ToastCenter.shared.fail(nil, failure, detail: String(describing: error))
                    }
                    self.refresh()
                }
            }
        }
    }
}
