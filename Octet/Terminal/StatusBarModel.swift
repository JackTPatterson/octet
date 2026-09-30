import Foundation

/// What the status bar knows about the focused pane: its folder, its
/// repository, the toolchain there, and what plugins' chips printed. Kept for
/// one pane at a time. Git state is re-read every few seconds; the pull
/// request every half minute; each plugin chip as often as it asks.
@MainActor
final class StatusBarModel: ObservableObject {
    struct Repo: Equatable {
        let root: String
        let gitDir: String
        var branch: String?
        var detached = false
        var linkedWorktree = false
        var operation = GitOperation()
        var changes: WorkingTreeChanges?
        var pullRequest: GitHubPullRequest?
        /// GitHub Actions for HEAD (or the branch's latest pushed commit).
        var ci: CIStatus?
    }

    @Published private(set) var directory: String?
    @Published private(set) var repo: Repo?
    @Published private(set) var runtime: ProjectRuntime?
    @Published private(set) var version: String?
    /// What each plugin chip printed, by descriptor id; missing means hidden.
    @Published private(set) var pluginOutputs: [String: StatusItemOutput] = [:]
    /// Remote Control, for a Claude Code session running in the pane: on,
    /// and its claude.ai link.
    /// How the pane's last command ended, from the shell's prompt marks.
    @Published private(set) var lastCommand: PromptMark?
    @Published private(set) var remoteControlOn = false
    @Published private(set) var remoteControlURL: URL?

    /// The Claude session whose log is read for Remote Control, and how far.
    private struct RemoteWatch {
        let sessionId: String
        let cwd: String
        let pid: Int?
        var path: String?
        var offset: UInt64 = 0
        var since: Date?
        var log = RemoteControlLog()
    }
    private var remoteWatch: RemoteWatch?
    private var readingRemote = false

    private var pane: String?
    private var ssh: SSHTarget?
    private var shellPid: Int?
    private var timer: Timer?
    private var readingGit = false
    private var readingPullRequest = false
    private var pullRequestReadAt = Date.distantPast
    private var pullRequestBranch: String?
    private var readingCI = false
    private var ciReadAt = Date.distantPast
    private var ciBranch: String?
    /// Failed runs' jobs, read once per run.
    private var ciFailedJobs: [Int: [String]] = [:]
    /// When each plugin chip last ran, keyed by its id and where it ran.
    private var pluginRanAt: [String: Date] = [:]
    /// Chip runs in flight, by id and folder: one still running for a folder
    /// left behind doesn't hold up the same chip for the folder in front.
    private var pluginRunning: Set<String> = []

    /// What the bar last showed for each folder (and SSH host), so coming
    /// back to a tab shows its chips at once while they refresh behind.
    private struct Remembered {
        var repo: Repo?
        var runtime: ProjectRuntime?
        var version: String?
        var pluginOutputs: [String: StatusItemOutput]
    }
    private var remembered: [String: Remembered] = [:]
    /// Oldest first, to keep `remembered` to `rememberLimit` folders.
    private var rememberedOrder: [String] = []
    private static let rememberLimit = 40
    /// Each pane's last finished command, shown again on returning to it.
    private var lastCommands: [String: PromptMark] = [:]

    /// Versions by runtime and repo root. A version manager can pick a
    /// different one per project, so a root is the smallest safe key.
    private static var versions: [String: String] = [:]
    private static var fetchingVersions: Set<String> = []

    func show(pane: String?, directory: String?, ssh: SSHTarget?, client: EngineClient) {
        let paneChanged = pane != self.pane
        guard paneChanged || directory != self.directory || ssh != self.ssh else { return }
        // Kept under where it was shown, before any of that changes.
        rememberCurrent()
        self.pane = pane
        self.ssh = ssh
        self.client = client
        if paneChanged {
            shellPid = nil
            lastCommand = pane.flatMap { lastCommands[$0] }
            if let pane { lookUpShell(pane, client: client) }
            refreshLastCommand()
        }
        if directory != self.directory {
            self.directory = directory
            let restored = directory.flatMap { remembered[Self.rememberKey($0, ssh)] }
            pluginOutputs = restored?.pluginOutputs ?? [:]
            pluginRanAt = [:]
            loadRepo(restoring: restored)
        } else {
            // Over SSH or back: remote chips run, local ones stop.
            pluginRanAt = [:]
        }
        refreshPlugins()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private static func rememberKey(_ directory: String, _ ssh: SSHTarget?) -> String {
        (ssh?.display ?? "") + "\u{0}" + directory
    }

    private func rememberCurrent() {
        guard let directory else { return }
        let key = Self.rememberKey(directory, ssh)
        remembered[key] = Remembered(repo: repo, runtime: runtime, version: version, pluginOutputs: pluginOutputs)
        rememberedOrder.removeAll { $0 == key }
        rememberedOrder.append(key)
        if rememberedOrder.count > Self.rememberLimit { remembered[rememberedOrder.removeFirst()] = nil }
    }

    /// Re-runs plugin chips now, as after Settings turns one on.
    func refreshPluginsNow() {
        pluginRanAt = [:]
        refreshPlugins()
    }

    private func lookUpShell(_ pane: String, client: EngineClient) {
        DispatchQueue.global(qos: .utility).async {
            let pid = (try? client.call("pane.process_info", ["pane_id": pane])).flatMap(ShellPrompt.parse)?.shellPid
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pane == pane else { return }
                self.shellPid = pid
                self.refreshPluginsNow()
            }
        }
    }

    private var client: EngineClient?

    /// The last finished command in the pane, when its shell marks them.
    private func refreshLastCommand() {
        guard let pane, let client else { return }
        DispatchQueue.global(qos: .utility).async {
            let marks = (try? client.call("pane.marks", ["pane_id": pane, "limit": 4])).flatMap(PromptMarks.init(response:))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pane == pane else { return }
                let last = marks?.lastFinished
                // Panes come and go; a closed one's entry isn't worth keeping.
                if self.lastCommands.count > 200 { self.lastCommands = [:] }
                self.lastCommands[pane] = last
                if last != self.lastCommand { self.lastCommand = last }
            }
        }
    }

    private func tick() {
        refreshLastCommand()
        refreshRemoteControl()
        guard directory != nil else { return }
        refreshGit()
        refreshPlugins()
    }

    // MARK: - Remote Control

    /// Follows the Claude Code session in the focused pane, if one is.
    func watchRemoteControl(sessionId: String?, cwd: String?, claudePid: Int?) {
        guard let sessionId, let cwd else {
            remoteWatch = nil
            remoteControlOn = false
            remoteControlURL = nil
            return
        }
        guard remoteWatch?.sessionId != sessionId || remoteWatch?.pid != claudePid else { return }
        remoteWatch = RemoteWatch(sessionId: sessionId, cwd: cwd, pid: claudePid,
                                  since: claudePid.flatMap(AgentRuntimeHandoff.processStart(pid:)))
        remoteControlOn = false
        remoteControlURL = nil
        refreshRemoteControl()
    }

    /// Reads what the session log gained since last time.
    private func refreshRemoteControl() {
        guard var watch = remoteWatch, !readingRemote else { return }
        readingRemote = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if watch.path == nil {
                watch.path = AgentConversation.findLog(sessionIds: [watch.sessionId], cwd: watch.cwd)
            }
            if let path = watch.path, let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                if end < watch.offset { watch.offset = 0; watch.log = RemoteControlLog() }
                try? handle.seek(toOffset: watch.offset)
                let data = (try? handle.readToEnd()) ?? Data()
                // Whole lines only; a line still being written waits.
                if let last = data.lastIndex(of: 0x0A) {
                    let complete = data[data.startIndex...last]
                    for line in complete.split(separator: 0x0A) {
                        watch.log.consume(String(decoding: line, as: UTF8.self), since: watch.since)
                    }
                    watch.offset += UInt64(complete.count)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingRemote = false
                // The pane moved on meanwhile: this read is for another session.
                guard self.remoteWatch?.sessionId == watch.sessionId, self.remoteWatch?.pid == watch.pid else { return }
                self.remoteWatch = watch
                if self.remoteControlOn != watch.log.active { self.remoteControlOn = watch.log.active }
                let url = watch.log.active ? watch.log.url : nil
                if self.remoteControlURL != url { self.remoteControlURL = url }
            }
        }
    }

    // MARK: - Repository

    /// Reads the folder's repository. What it showed last time, when there
    /// was a last time, stays up until each part has been read again: the
    /// pull request and CI come from `gh`, which takes seconds.
    private func loadRepo(restoring restored: Remembered? = nil) {
        guard let directory, let location = GitBranch.location(for: directory) else {
            repo = nil
            runtime = nil
            version = nil
            return
        }
        let detected = ProjectRuntime.detect(from: directory, root: location.root)
        runtime = detected
        version = detected.flatMap { Self.versions[Self.key($0, location.root)] }
        if let cached = restored?.repo, cached.root == location.root, cached.gitDir == location.gitDir {
            repo = cached
        } else {
            repo = Repo(root: location.root, gitDir: location.gitDir, linkedWorktree: location.isLinkedWorktree)
        }
        pullRequestBranch = nil
        ciBranch = nil
        refreshGit()
        loadVersion()
    }

    private func refreshGit() {
        guard var repo else { return }
        // HEAD and the operation markers are small files: read them here.
        let branch = GitBranch.current(in: repo.root)
        let detached = GitBranch.isDetached(gitDir: repo.gitDir)
        var operation = GitOperation.read(gitDir: repo.gitDir)
        operation.conflicts = repo.operation.conflicts
        if branch != repo.branch || detached != repo.detached || operation != repo.operation {
            repo.branch = branch
            repo.detached = detached
            repo.operation = operation
            self.repo = repo
        }
        readWorkingTree()
        if pullRequestBranch != branch || Date().timeIntervalSince(pullRequestReadAt) > 30 {
            readPullRequest()
        }
        // Every 15s while something runs, so the chip follows along; every
        // minute otherwise, which also notices a push starting new runs.
        let ciInterval: TimeInterval = repo.ci?.overall == .running ? 15 : 60
        if ciBranch != branch || Date().timeIntervalSince(ciReadAt) > ciInterval {
            readCI()
        }
    }

    /// Reads now, as after a rerun or a push from the popover.
    func refreshCINow() {
        ciReadAt = .distantPast
        readCI()
    }

    private func readCI() {
        guard let repo, let branch = repo.branch, !repo.detached, !readingCI,
              OctetPluginHost.shared.statusBarOrder.contains("builtin.ci") else { return }
        readingCI = true
        ciReadAt = Date()
        let root = repo.root
        let known = ciFailedJobs
        DispatchQueue.global(qos: .utility).async {
            let head = try? Git().run(["rev-parse", "HEAD"], in: root)
            let result = LoginShell.run(["gh", "run", "list", "--branch", branch, "--limit", "30",
                                         "--json", GitHubRuns.listFields], in: root)
            var status = result.status == 0 ? GitHubRuns.status(runs: GitHubRuns.parseRuns(Data(result.output.utf8)), head: head) : nil
            // Which jobs failed, for the popover and the agent's prompt.
            var jobs = known
            if var current = status {
                for index in current.runs.indices where current.runs[index].state == .failed {
                    let id = current.runs[index].id
                    if jobs[id] == nil {
                        let view = LoginShell.run(["gh", "run", "view", String(id), "--json", "jobs"], in: root)
                        if view.status == 0 { jobs[id] = GitHubRuns.parseFailedJobs(Data(view.output.utf8)) }
                    }
                    current.runs[index].failedJobs = jobs[id] ?? []
                }
                status = current
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingCI = false
                self.ciBranch = branch
                self.ciFailedJobs = jobs
                guard var current = self.repo, current.root == root else { return }
                // A failed call (offline, signed out, not on GitHub) keeps the
                // last answer, and a branch with no runs has none.
                let next = result.status == 0 ? status : current.ci
                guard next != current.ci else { return }
                let before = current.ci
                current.ci = next
                self.repo = current
                if let next { self.announce(next, after: before, branch: branch) }
            }
        }
    }

    /// Says so when runs this pane was watching finish: only a change seen
    /// here, from running to done on the same commit, never a first read.
    private func announce(_ status: CIStatus, after before: CIStatus?, branch: String) {
        guard let before, before.sha == status.sha, before.overall == .running, status.overall != .running else { return }
        let pane = self.pane
        switch status.overall {
        case .passed:
            ToastCenter.shared.succeed(nil, "CI passed on \(branch)")
        case .failed:
            let names = status.failed.map(\.workflow).joined(separator: ", ")
            ToastCenter.shared.fail(nil, "CI failed on \(branch)", detail: names,
                                    action: .init(title: "Ask Agent to Fix") {
                                        MainActor.assumeIsolated {
                                            StatusBarModel.askAgentToFix(status, branch: branch, pane: pane)
                                        }
                                    })
        case .cancelled, .running:
            break
        }
    }

    /// Sends the failure to the agent in `pane` (or the pane in front) as a
    /// prompt: what failed, and how to read its log.
    static func askAgentToFix(_ status: CIStatus, branch: String?, pane: String?) {
        guard let window = WindowRegistry.shared.key else { return }
        let snapshot = window.store.snapshot
        let candidates = [pane, window.focusedPaneId].compactMap { $0 }
        guard let agent = candidates.lazy.compactMap({ id in
            snapshot.agents.first { $0.paneId == id && $0.agent != nil && !$0.isSubagentViewer }
        }).first else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in this pane, then try again.")
            return
        }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        window.store.broadcast(GitHubRuns.fixPrompt(status, branch: branch),
                               to: [Broadcast.Target(paneId: agent.paneId, name: name, isAgent: true)])
    }

    /// Re-runs the failed jobs of each failed run.
    func rerunFailed(_ status: CIStatus) {
        guard let root = repo?.root else { return }
        let ids = status.failed.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let failures = ids.filter { LoginShell.run(["gh", "run", "rerun", String($0), "--failed"], in: root).status != 0 }
            DispatchQueue.main.async { [weak self] in
                if failures.isEmpty {
                    ToastCenter.shared.info("Re-running \(ids.count == 1 ? "the failed jobs" : "failed jobs in \(ids.count) runs")")
                } else {
                    ToastCenter.shared.fail(nil, "Couldn't re-run \(failures.count) of \(ids.count)",
                                            detail: "Check that the GitHub CLI is signed in with access to this repository.")
                }
                self?.refreshCINow()
            }
        }
    }

    private func readWorkingTree() {
        guard let repo, !readingGit else { return }
        readingGit = true
        let root = repo.root
        let inOperation = repo.operation.kind != nil
        DispatchQueue.global(qos: .utility).async {
            let changes = WorkingTreeChanges.read(in: root)
            // Conflicts only exist mid-operation; skip the call otherwise.
            let conflicts = inOperation ? Self.conflictCount(in: root) : 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingGit = false
                guard var current = self.repo, current.root == root else { return }
                guard current.changes != changes || current.operation.conflicts != conflicts else { return }
                current.changes = changes
                current.operation.conflicts = conflicts
                self.repo = current
            }
        }
    }

    private nonisolated static func conflictCount(in root: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "diff", "--name-only", "--diff-filter=U"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    private func readPullRequest() {
        guard let repo, !readingPullRequest,
              OctetPluginHost.shared.statusBarOrder.contains("builtin.pullRequest") else { return }
        readingPullRequest = true
        pullRequestReadAt = Date()
        let root = repo.root
        let branch = repo.branch
        DispatchQueue.global(qos: .utility).async {
            let result = LoginShell.run(["gh", "pr", "view", "--json",
                                         "number,title,state,url,isDraft,reviewDecision,statusCheckRollup"], in: root)
            let value = result.status == 0 ? GitHubPullRequest.parse(Data(result.output.utf8)) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingPullRequest = false
                self.pullRequestBranch = branch
                guard var current = self.repo, current.root == root else { return }
                // A failed call (offline, signed out) keeps the last answer;
                // a successful empty one means the branch has no PR.
                let next = result.status == 0 ? value : (result.output.contains("no pull requests") ? nil : current.pullRequest)
                guard next != current.pullRequest else { return }
                current.pullRequest = next
                self.repo = current
            }
        }
    }

    // MARK: - Runtime version

    private func loadVersion() {
        guard let repo, let runtime, version == nil else { return }
        let root = repo.root
        let key = Self.key(runtime, root)
        guard !Self.fetchingVersions.contains(key) else { return }
        Self.fetchingVersions.insert(key)
        let command = "cd \(PluginCLI.quote(root)) && " + runtime.versionCommand.map(PluginCLI.quote).joined(separator: " ")
        PluginCLI.runShell(command, timeout: 10) { [weak self] result in
            Self.fetchingVersions.remove(key)
            guard result.exitCode == 0, let version = ProjectRuntime.version(fromOutput: result.output) else { return }
            Self.versions[key] = version
            guard let self, self.repo?.root == root, self.runtime == runtime else { return }
            self.version = version
        }
    }

    private static func key(_ runtime: ProjectRuntime, _ root: String) -> String { runtime.id + "|" + root }

    // MARK: - Plugin chips

    private func refreshPlugins() {
        guard let directory else { return }
        let host = OctetPluginHost.shared
        let order = Set(host.statusBarOrder)
        let items = host.statusItems
        var outputs = pluginOutputs
        for (id, entry) in items {
            let scope = entry.item.scope ?? .local
            let applies = order.contains(id) && (ssh == nil ? scope != .remote : scope != .local)
                && (ssh != nil || StatusBarItems.hasMarker(entry.item.whenFiles ?? [], from: directory, root: repo?.root))
            guard applies else {
                outputs[id] = nil
                continue
            }
            let every = max(entry.item.refreshSeconds ?? 10, 2)
            if let ran = pluginRanAt[id], Date().timeIntervalSince(ran) < every { continue }
            run(id, entry.item, of: entry.plugin, in: directory)
        }
        for id in outputs.keys where items[id] == nil { outputs[id] = nil }
        if outputs != pluginOutputs { pluginOutputs = outputs }
    }

    private func run(_ id: String, _ item: OctetPluginManifest.StatusItemContribution, of plugin: OctetPlugin, in directory: String) {
        let running = id + "\u{0}" + directory
        guard pluginRunning.insert(running).inserted else { return }
        pluginRanAt[id] = Date()
        var environment = [
            "OCTET_PLUGIN_DIR": plugin.directory,
            "OCTET_CWD": directory,
            "OCTET_REPO_ROOT": repo?.root ?? "",
            "OCTET_SHELL_PID": shellPid.map(String.init) ?? "",
        ]
        if let ssh {
            environment["OCTET_SSH_HOST"] = ssh.host
            environment["OCTET_SSH_USER"] = ssh.user ?? ""
        }
        let timeout = min(max(item.timeoutSeconds ?? 5, 0.5), 30)
        let pane = self.pane
        StatusCommand.run(item.run, in: directory, environment: environment, timeout: timeout) { [weak self] output in
            guard let self else { return }
            self.pluginRunning.remove(running)
            guard self.pane == pane, self.directory == directory else { return }
            let parsed = StatusItemOutput.parse(output)
            if self.pluginOutputs[id] != parsed { self.pluginOutputs[id] = parsed }
        }
    }
}

/// Runs a plugin's status command with the person's login PATH, so tools
/// from Homebrew and version managers are found as they are in a pane.
enum StatusCommand {
    private static var loginPath: String?
    private static var resolving = false
    private static var waiting: [() -> Void] = []

    @MainActor
    static func run(_ command: String, in directory: String, environment: [String: String], timeout: TimeInterval,
                    completion: @escaping @MainActor (String) -> Void) {
        withLoginPath { path in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                var env = TerminalEnvironment.sanitized(ProcessInfo.processInfo.environment)
                env["PATH"] = path
                env.merge(environment) { _, new in new }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion("") } }
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = process.terminationReason == .exit ? String(decoding: data.prefix(4096), as: UTF8.self) : ""
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(output) } }
            }
        }
    }

    @MainActor
    private static func withLoginPath(_ then: @escaping (String) -> Void) {
        if let loginPath { return then(loginPath) }
        waiting.append { then(loginPath ?? fallbackPath) }
        guard !resolving else { return }
        resolving = true
        DispatchQueue.global(qos: .utility).async {
            let path = resolveLoginPath()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    loginPath = (path?.isEmpty == false ? path! : fallbackPath)
                    resolving = false
                    let queued = waiting
                    waiting = []
                    queued.forEach { $0() }
                }
            }
        }
    }

    private static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let pathMarker = "__OCTET_PATH__"

    /// The PATH a pane gets. Interactive as well as login, as the runtime
    /// chip's shell is: version managers (nvm, fnm, pyenv) are set up in
    /// ~/.zshrc, which a login shell alone never reads. The marker picks the
    /// PATH out of whatever the rc files print on the way.
    private static func resolveLoginPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lic", "printf '\\n\(pathMarker)%s\\n' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last { $0.hasPrefix(pathMarker) }
        return line.map { String($0.dropFirst(pathMarker.count)) }
    }
}
