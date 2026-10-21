import AppKit
import SwiftUI
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
        /// Who edited each changed file (by its path in the checkout), from
        /// the agents' transcripts. A file no one's edit tool touched has none.
        var editors: [String: [Worker]] = [:]

        var id: String { checkout.top }

        /// Everyone who edited something here, in the order they appear.
        var allEditors: [Worker] {
            var seen = Set<String>()
            return checkout.files.flatMap { editors[$0.path] ?? [] }.filter { seen.insert($0.paneId).inserted }
        }
    }

    /// Where a worker's own record of its edits is.
    private struct Records {
        var claudeSession: String?
        var codexSession: String?
        var cwds: [String] = []
        /// For a subagent's viewer: the tool call that started it.
        var toolUseId: String?
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var worktrees: [AgentGit.Worktree] = []
    /// Who is working in each worktree, anywhere in the session.
    @Published private(set) var worktreeWorkers: [String: [Worker]] = [:]
    /// Whether anything in front is in a repository, for the tab bar button.
    @Published private(set) var hasRepository = false
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// Checkouts git failed to read, by top level, with what it said: shown
    /// with Retry, not as "Not in a repository".
    @Published private(set) var failures: [String: String] = [:]
    private var loadedScope: [String] = []
    /// What's running in each checkout from the panel itself (Pushing…),
    /// by its top level.
    @Published private(set) var busy: [String: String] = [:]
    /// The commit message being written for each checkout.
    @Published var drafts: [String: String] = [:]
    /// The panel's folded sections that are open ("history", "worktrees",
    /// "handoff"), kept for as long as the window lives.
    @Published var openSections: Set<String> = []

    func sectionBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.openSections.contains(key) },
                set: {
                    if $0 { self.openSections.insert(key) } else { self.openSections.remove(key) }
                    // Worktree details are only read while the section is open.
                    if $0, key == "worktrees" { self.refresh() }
                })
    }

    private weak var window: WindowContext?
    private var timer: Timer?
    private var reading = false
    /// A refresh asked for while one was reading: run again when it's done,
    /// rather than drop it (a commit's own refresh would be lost).
    private var rerun = false
    /// Folder → its checkout's top level and when that was found, so a
    /// refresh doesn't ask git again. "Not a repository" is asked again
    /// after a while: `git init`, or git failing once, shouldn't stick.
    private var tops: [String: (top: String?, at: Date)] = [:]
    static let notARepositoryLifetime: TimeInterval = 20
    private let editLog = AgentEditLog()
    private let cache = AgentGitCache()
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
    private func scope() -> [(worker: Worker, directory: String, records: Records)] {
        guard let window, let tabId = window.displayedFocusedTabId,
              let workspaceId = window.focusedWorkspace?.workspaceId else { return [] }
        let snapshot = window.store.snapshot
        let root = snapshot.rootTabId(ofTab: tabId)
        let tabs = snapshot.tabs(inWorkspace: workspaceId).filter { snapshot.rootTabId(ofTab: $0.tabId) == root }
        return tabs.flatMap { tab in
            snapshot.panes.filter { $0.tabId == tab.tabId }.compactMap { pane in
                guard let directory = snapshot.workingDirectory(ofPane: pane.paneId) else { return nil }
                return (worker: worker(pane: pane, tab: tab, snapshot: snapshot), directory: directory,
                        records: records(pane: pane, snapshot: snapshot))
            }
        }
    }

    private func records(pane: EnginePane, snapshot: EngineSnapshot) -> Records {
        guard let window, let agent = snapshot.agents.first(where: { $0.paneId == pane.paneId && $0.agent != nil }) else {
            return Records()
        }
        if agent.isSubagentViewer { return Records(toolUseId: agent.subagentToolUseId) }
        let session = agent.sessionReference ?? agent.terminalId.flatMap { window.store.recovery.sessionId(forTerminal: $0) }
        var records = Records(cwds: agent.searchCwds + [pane.cwd].compactMap { $0 })
        switch AgentBrand.forAgent(agent.agent)?.id {
        case "claude": records.claudeSession = session
        case "codex": records.codexSession = session
        default: break
        }
        return records
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

    #if DEBUG
    /// Sample data is showing (`OCTET_OPEN_WINDOW=planes:git:sample`), so
    /// nothing reads a repository over it.
    private var sampleShowing = false

    func showSample(groups: [Group], worktrees: [AgentGit.Worktree], openSections: Set<String>) {
        sampleShowing = true
        self.groups = groups
        self.worktrees = worktrees
        self.openSections = openSections
        hasRepository = true
        loading = false
    }
    #endif

    func refresh() {
        #if DEBUG
        if sampleShowing { return }
        #endif
        guard let window else { return }
        let scoped = scope()
        // Hidden, only whether there's a repository at all, from files.
        guard window.ui.showing(.git) else {
            let has = scoped.contains { GitBranch.location(for: $0.directory) != nil }
            if has != hasRepository { hasRepository = has }
            return
        }
        guard !reading else { rerun = true; return }
        reading = true
        let scope = scoped.map(\.directory).sorted()
        if scope != loadedScope { loaded = false; loadedScope = scope }
        if groups.isEmpty { loading = true }
        let sessionWide = everyone()
        let known = tops
        let editLog = self.editLog, cache = self.cache
        let worktreeDetails = openSections.contains("worktrees")
        let notARepositoryLifetime = Self.notARepositoryLifetime
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Git()
            var tops = known
            func topLevel(of directory: String) -> String? {
                if let known = tops[directory],
                   known.top != nil || Date().timeIntervalSince(known.at) < notARepositoryLifetime { return known.top }
                let found = git.topLevel(directory)
                tops[directory] = (found, Date())
                return found
            }
            // One group per checkout, in the order its workers appear.
            var order: [String] = []
            var workers: [String: [Worker]] = [:]
            for (worker, directory, _) in scoped {
                guard let top = topLevel(of: directory) else { continue }
                if workers[top] == nil { order.append(top) }
                if !(workers[top]?.contains(where: { $0.paneId == worker.paneId }) ?? false) {
                    workers[top, default: []].append(worker)
                }
            }
            let edited = Self.edits(of: scoped.map { ($0.worker, $0.records) }, log: editLog)
            var failures: [String: String] = [:]
            let groups = order.compactMap { top -> Group? in
                switch AgentGit.readResult(top: top, git: git, cache: cache) {
                case .success(let checkout):
                    return Group(checkout: checkout, workers: workers[top] ?? [], editors: Self.editors(of: checkout, edited: edited))
                case .failure(let failure):
                    failures[top] = failure.message
                    return nil
                }
            }
            // The list is cheap; how far each has gone, and whether it's
            // clean, is a git status per worktree, read only when shown.
            let worktrees = order.first.map { AgentGit.worktrees(top: $0, git: git, details: worktreeDetails, cache: cache) } ?? []
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
                    self.tops = tops
                    // Read for a tab no longer in front: read again for the
                    // one that is, without showing this.
                    let current = self.scope().map(\.directory).sorted()
                    if current == scope {
                        self.loading = false
                        self.loaded = true
                        if groups != self.groups { self.groups = groups }
                        if worktrees != self.worktrees { self.worktrees = worktrees }
                        if byWorktree != self.worktreeWorkers { self.worktreeWorkers = byWorktree }
                        if failures != self.failures { self.failures = failures }
                        let has = !groups.isEmpty
                        if has != self.hasRepository { self.hasRepository = has }
                    }
                    if self.rerun || current != scope {
                        self.rerun = false
                        self.refresh()
                    }
                }
            }
        }
    }

    // MARK: - Who edited what

    /// Each worker's edited paths, resolved. A lead's subagents are found
    /// beside its transcript and credited to their own tabs, matched by the
    /// tool call that started them (or its description, for tabs opened
    /// before viewers reported it); one whose tab has closed is credited to
    /// the lead that sent it.
    private nonisolated static func edits(of workers: [(Worker, Records)], log: AgentEditLog) -> [(Worker, Set<String>)] {
        let viewers = workers.filter { $0.0.isSubagent }
        var edited: [String: (Worker, Set<String>)] = [:]
        func credit(_ worker: Worker, _ paths: Set<String>) {
            guard !paths.isEmpty else { return }
            edited[worker.paneId, default: (worker, [])].1.formUnion(paths)
        }
        let claudeNeedles = ["\"file_path\"", "\"notebook_path\""]
        for (worker, records) in workers where !worker.isSubagent {
            if let session = records.claudeSession,
               let transcript = log.resolve("claude:\(session)", find: {
                   AgentEdits.claudeTranscript(sessionId: session, cwds: records.cwds)
               }) {
                credit(worker, log.paths(in: transcript, needles: claudeNeedles, parse: AgentEdits.claudePaths))
                for subagent in AgentEdits.claudeSubagents(ofTranscript: transcript) {
                    let viewer = viewers.first { $0.1.toolUseId != nil && $0.1.toolUseId == subagent.toolUseId }?.0
                        ?? subagent.description.flatMap { description in
                            viewers.first { $0.1.toolUseId == nil && !description.isEmpty && $0.0.name.contains(description.prefix(24)) }?.0
                        }
                    credit(viewer ?? worker, log.paths(in: subagent.transcript, needles: claudeNeedles, parse: AgentEdits.claudePaths))
                }
            }
            if let session = records.codexSession,
               let rollout = log.resolve("codex:\(session)", find: { AgentSessionFiles.codexPath(forSession: session) }) {
                let cwd = records.cwds.first
                credit(worker, log.paths(in: rollout, needles: ["*** "]) { AgentEdits.codexPaths(line: $0, cwd: cwd) })
            }
        }
        // In the scope's order, so marks don't reshuffle between refreshes;
        // each folder's symlinks are resolved once.
        var folders: [String: String] = [:]
        func resolve(_ path: String) -> String {
            let standard = (path as NSString).standardizingPath
            let folder = (standard as NSString).deletingLastPathComponent
            let real = folders[folder] ?? URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            folders[folder] = real
            return (real as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
        }
        return workers.compactMap { entry in
            edited[entry.0.paneId].map { ($0.0, Set($0.1.map(resolve))) }
        }
    }

    /// Who edited each of the checkout's changed files.
    private nonisolated static func editors(of checkout: AgentGit.Checkout, edited: [(Worker, Set<String>)]) -> [String: [Worker]] {
        guard !edited.isEmpty else { return [:] }
        let top = resolved(checkout.top)
        var result: [String: [Worker]] = [:]
        for file in checkout.files {
            let path = (top as NSString).appendingPathComponent(file.path)
            let who = edited.filter { $0.1.contains(path) }.map { $0.0 }
            if !who.isEmpty { result[file.path] = who }
        }
        return result
    }

    /// A path with its folder's symlinks resolved (`/var` is `/private/var`),
    /// whether or not the file itself still exists.
    private nonisolated static func resolved(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        let folder = URL(fileURLWithPath: (standard as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        return (folder as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
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
    /// `only` narrows a commit to those files: one agent's edits, say.
    func handoff(_ handoff: AgentGitHandoff, in group: Group, only paths: [String]? = nil) {
        guard let target = promptTarget(in: group.workers) else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in this tab, then try again.")
            return
        }
        send(handoff.prompt(checkout: group.checkout, only: paths), to: target)
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
            // A rename is two paths in the index; both move together.
            if file.staged { try ReviewDiff.unstage(paths: file.paths, in: top) } else { try ReviewDiff.stage(paths: file.paths, in: top) }
        }
    }

    /// Throws a file's changes away at once; the toast's Undo puts back
    /// what was there, unless the file changed again since.
    func discard(_ file: AgentGit.FileChange, in top: String) {
        runGit(failure: "Couldn't discard \(file.path)") { () throws -> [DiscardedFile] in
            let git = Git()
            // A rename's old path comes back too, so it's kept for Undo.
            var kept = file.paths.map { DiscardedFile.capture($0, in: top) }
            if file.kind == .untracked {
                // To the Trash, not deleted: an untracked entry can be a whole
                // folder, a nested clone or worktree with work of its own.
                var landed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: (top as NSString).appendingPathComponent(file.path)),
                                                  resultingItemURL: &landed)
                kept[0].trashed = landed as URL?
            } else if file.kind == .added {
                try git.run(["rm", "-q", "-f", "--", file.path], in: top)
            } else {
                // For a rename, both paths: the new one goes, the old one is back.
                try git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + file.paths, in: top)
            }
            for index in kept.indices { kept[index].discarded(in: top) }
            return kept
        } done: { [weak self] kept in
            ToastCenter.shared.info("Discarded \((file.path as NSString).lastPathComponent)", detail: file.path, after: 8,
                                    action: .init(title: "Undo") { self?.undoDiscard(kept, in: top) })
        }
    }

    private func undoDiscard(_ kept: [DiscardedFile], in top: String) {
        guard let first = kept.first else { return }
        runGit(failure: "Couldn't undo the discard") {
            // Checked first, so a half-done undo never happens.
            if let moved = kept.first(where: { !$0.canUndo(in: top) }) { throw DiscardedFile.Changed(path: moved.path) }
            for file in kept { try file.undo(in: top) }
        } done: { _ in
            ToastCenter.shared.info("Restored \((first.path as NSString).lastPathComponent)",
                                    detail: "Its changes are back, unstaged.")
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

    // MARK: - Commit, push, pull

    /// Commits what's staged, or every change when nothing is, then pushes
    /// when asked. Undo puts the commit's changes back, staged.
    func commit(_ checkout: AgentGit.Checkout, push: Bool = false) {
        let top = checkout.top
        let message = (drafts[top] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            ToastCenter.shared.info("Write a commit message first", detail: "Or Write Message asks the agent for one.")
            return
        }
        let branch = checkout.branch
        perform(in: top, label: "Committing…", failure: "Couldn't commit") { git in
            // Decided now, not from the panel's last read: something staged
            // since (or unstaged) changes what "Commit" means.
            if !Self.hasStaged(in: top, git: git) { try git.run(["add", "-A"], in: top) }
            let sha = try ReviewDiff.commitStaged(message: message, in: top, git: git)
            let count = (try? git.run(["diff-tree", "--root", "--no-commit-id", "-r", "--name-only", "HEAD"], in: top))
                .map { $0.split(separator: "\n").count } ?? 0
            if push, let pushArgs = Self.pushArguments(branch: branch, in: top, git: git) {
                try git.run(pushArgs, in: top, environment: Self.remoteEnvironment)
            }
            return (sha, count)
        } done: { [weak self] (sha: String, count: Int) in
            self?.drafts[top] = nil
            let what = Recap.count(count, "file")
            ToastCenter.shared.info("Committed \(sha)\(push ? " and pushed" : "")", detail: "\(what): \(message.split(separator: "\n").first ?? "")",
                                    after: 8, action: push ? nil : .init(title: "Undo") { self?.undoCommit(sha, in: top) })
        }
    }

    /// Whether anything is in the index that HEAD doesn't have.
    nonisolated private static func hasStaged(in top: String, git: Git) -> Bool {
        // Exits 1 when there's a difference, which `run` throws for.
        (try? git.run(["diff", "--cached", "--quiet"], in: top)) == nil
    }

    /// Takes the last commit back, keeping its changes staged, if it's
    /// still the last one.
    private func undoCommit(_ sha: String, in top: String) {
        perform(in: top, label: "Undoing…", failure: "Couldn't undo the commit") { git in
            let head = try git.run(["rev-parse", "--short", "HEAD"], in: top)
            guard head == sha else { throw Checkpoints.GitError(description: "Something was committed after it; undo that first.") }
            if (try? git.run(["rev-parse", "-q", "--verify", "HEAD~1"], in: top)) == nil {
                // A shallow clone's oldest commit has no parent here either,
                // but deleting the branch there would lose history.
                if (try? git.run(["rev-parse", "--is-shallow-repository"], in: top)) == "true" {
                    throw Checkpoints.GitError(description: "This clone is shallow, so its parent isn't here to go back to.")
                }
                // The repository's first commit has no parent to reset to:
                // the branch goes back to unborn, the index keeps the files.
                try git.run(["update-ref", "-d", "HEAD"], in: top)
            } else {
                try git.run(["reset", "--soft", "HEAD~1"], in: top)
            }
        } done: { _ in ToastCenter.shared.info("Commit undone", detail: "Its changes are staged again.") }
    }

    func push(_ checkout: AgentGit.Checkout) {
        let publishing = checkout.branch.upstream == nil
        let branch = checkout.branch
        perform(in: checkout.top, label: publishing ? "Publishing…" : "Pushing…", failure: "Couldn't push") { git in
            guard let arguments = Self.pushArguments(branch: branch, in: checkout.top, git: git) else {
                throw Checkpoints.GitError(description: branch.name == nil
                    ? "HEAD is detached; check out a branch first." : "This repository has no remote.")
            }
            try git.run(arguments, in: checkout.top, environment: Self.remoteEnvironment)
        } done: { _ in
            ToastCenter.shared.info(publishing ? "Published \(checkout.branch.name ?? "the branch")" : "Pushed")
        }
    }

    func pull(_ checkout: AgentGit.Checkout) {
        perform(in: checkout.top, label: "Pulling…", failure: "Couldn't pull") { git in
            try git.run(GitRemote.pullArguments, in: checkout.top, environment: Self.remoteEnvironment)
        } done: { _ in ToastCenter.shared.info("Up to date with \(checkout.branch.upstream ?? "upstream")") }
    }

    func fetch(_ checkout: AgentGit.Checkout) {
        perform(in: checkout.top, label: "Fetching…", failure: "Couldn't fetch") { git in
            try git.run(GitRemote.fetchArguments, in: checkout.top, environment: Self.remoteEnvironment)
        } done: { _ in }
    }

    func stageAll(_ checkout: AgentGit.Checkout) {
        perform(in: checkout.top, label: "Staging…", failure: "Couldn't stage everything") { git in
            try git.run(["add", "-A"], in: checkout.top)
        } done: { _ in }
    }

    func unstageAll(_ checkout: AgentGit.Checkout) {
        perform(in: checkout.top, label: "Unstaging…", failure: "Couldn't unstage") { git in
            try git.run(["reset", "-q"], in: checkout.top)
        } done: { _ in }
    }

    /// The branch's pull request page on its host, publishing the branch
    /// first when it isn't on the remote yet.
    func openPullRequest(_ checkout: AgentGit.Checkout) {
        guard let branch = checkout.branch.name else {
            ToastCenter.shared.info("Check out a branch first", detail: "HEAD is detached.")
            return
        }
        let publishing = checkout.branch.upstream == nil
        let remoteName = checkout.branch.upstream.map { String($0.prefix { $0 != "/" }) }
        let state = checkout.branch
        perform(in: checkout.top, label: publishing ? "Publishing…" : "Opening…", failure: "Couldn't open a pull request") { git in
            if publishing, let publish = Self.pushArguments(branch: state, in: checkout.top, git: git) {
                try git.run(publish, in: checkout.top, environment: Self.remoteEnvironment)
            }
            let remotes = (try? git.run(["remote"], in: checkout.top))?.split(separator: "\n").map(String.init) ?? []
            guard let name = remoteName ?? (remotes.contains("origin") ? "origin" : remotes.first) else {
                throw Checkpoints.GitError(description: "This repository has no remote.")
            }
            let url = try git.run(["remote", "get-url", name], in: checkout.top)
            guard let page = GitRemote.pullRequestURL(remote: url, branch: branch, base: checkout.base) else {
                throw Checkpoints.GitError(description: "\(url) isn't a web host Octet knows.")
            }
            return page
        } done: { page in NSWorkspace.shared.open(page) }
    }

    /// Runs git, so only off the main thread.
    nonisolated private static func pushArguments(branch: AgentGit.Branch, in top: String, git: Git) -> [String]? {
        let remotes = (try? git.run(["remote"], in: top))?.split(separator: "\n").map(String.init) ?? []
        return GitRemote.pushArguments(branch: branch.name, upstream: branch.upstream, remotes: remotes)
    }

    /// No prompt can be answered from the panel: ssh fails rather than asks.
    nonisolated private static var remoteEnvironment: [String: String] {
        ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil ? ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes"] : [:]
    }

    /// Runs `work` off the main thread with the checkout marked busy, then
    /// `done` with its result, or a toast saying what went wrong.
    private func perform<T>(in top: String, label: String, failure: String,
                            _ work: @escaping (Git) throws -> T, done: @escaping (T) -> Void) {
        guard busy[top] == nil else { return }
        busy[top] = label
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work(Git()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy[top] = nil
                    switch outcome {
                    case .success(let value): done(value)
                    case .failure(let error):
                        ToastCenter.shared.fail(nil, failure, detail: GitRemote.explain(String(describing: error)))
                    }
                    self.refresh()
                }
            }
        }
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
