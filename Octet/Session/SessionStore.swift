import AppKit
import Foundation
import SwiftUI

struct RuntimeChildProcess: Equatable, Identifiable {
    let pid: Int
    let parentPid: Int
    let name: String
    var id: Int { pid }
}

/// An agent executable launched beneath another terminal or native agent.
/// These do not own a pane, so the session server cannot report them in its
/// ordinary agent list; Runtime discovery supplies them to the global board.
struct SpawnedRuntimeAgent: Equatable, Identifiable {
    let pid: Int
    let parentPid: Int
    let agent: String
    let name: String
    let paneId: String?
    let tabId: String?
    let workspaceId: String?
    let cwd: String?
    var id: Int { pid }
}

/// Live mirror of Octet's session: subscribes to session server events and
/// re-fetches `session.snapshot` (coalesced) whenever anything changes.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot: EngineSnapshot = .empty
    @Published private(set) var groups: [ProjectGroup] = []
    /// Git branch per workspace id, read from `.git/HEAD` on each snapshot.
    @Published private(set) var branches: [String: String] = [:]
    /// Where each subagent is working, by pane id, when it has left the
    /// folder its tab opened in (another worktree, repo or subfolder).
    @Published private(set) var agentLocations: [String: AgentLocation] = [:]
    /// Plugins installed in Octet's session; refreshed when the palette opens.
    @Published private(set) var plugins: [EnginePlugin] = []

    // MARK: Idle organization
    /// Project groups holding only workspaces that are in use.
    @Published private(set) var activeGroups: [ProjectGroup] = []
    /// Workspaces unused past `idleAfter`, most recently used first.
    @Published private(set) var idleWorkspaces: [EngineWorkspace] = []
    @Published private(set) var activity = WorkspaceActivity()
    @Published private(set) var pinnedWorkspaceIds: Set<String> = []
    @Published var idleAfter: TimeInterval = WorkspaceActivity.defaultIdleAfter {
        didSet {
            UserDefaults.standard.set(idleAfter, forKey: Self.idleAfterKey)
            repartition()
        }
    }
    // Isolated sessions (OCTET_SESSION) keep their own activity state.
    private static let keySuffix = EngineSession.name == "octet" ? "" : ".\(EngineSession.name)"
    private static let manualNamesKey = "octet.tabs.manualNames" + keySuffix
    private static let stampsKey = "octet.activity.stamps" + keySuffix
    private static let pinnedKey = "octet.activity.pinned" + keySuffix
    private static let idleAfterKey = "octet.activity.idleAfter" + keySuffix
    private var lastStampSave = Date.distantPast
    /// Workspaces marked idle by hand: viewing them doesn't count as use
    /// until the user focuses them again.
    private var forcedIdle: Set<String> = []
    private var lastFocusedWorkspaceId: String?
    /// Tabs the user named, which auto-naming leaves alone.
    private var manuallyNamedTabIds: Set<String> = []
    private var pendingTabNames: [String: TabAutoName.Candidate] = [:]
    private var clockTimer: Timer?
    /// What the focused pane is running, for the prompt editor: nil until
    /// the first look.
    @Published private(set) var focusedProcess: ShellPrompt.ProcessInfo?
    /// Process trees for the runtime panel, fetched only while that panel is
    /// open so ordinary snapshot polling stays light.
    @Published private(set) var paneProcesses: [String: ShellPrompt.ProcessInfo] = [:]
    /// Descendants of native agent processes, keyed by conversation id.
    @Published private(set) var nativeRuntimeProcesses: [String: [RuntimeChildProcess]] = [:]
    /// Model CLIs launched by an agent, including cross-model children.
    @Published private(set) var spawnedRuntimeAgents: [SpawnedRuntimeAgent] = []
    /// Background commands, monitors and subagents a Claude Code session in
    /// a terminal pane has running, from its session log, by pane.
    @Published private(set) var terminalRuntimes: [String: [HandoffRuntime]] = [:]
    /// Session logs already read, so each refresh reads only what was added.
    private let runtimeLogs = RuntimeLogTails()
    /// What each pane is running, by a plugin's runtime rules, by pane.
    @Published private(set) var paneRuntimes: [String: RuntimeBadge] = [:]
    /// Panes whose shell is running an interactive `ssh`, by pane.
    @Published private(set) var paneSSH: [String: SSHTarget] = [:]
    /// How many scans have filled `paneSSH`: the first finds sessions that
    /// were already open, which aren't new connections.
    private(set) var sshScans = 0
    private var loadingPaneRuntimes = false
    private var loadingPaneProcesses = false
    /// True while the focused pane sits at its shell's own prompt.
    var focusedPaneAtPrompt: Bool { ShellPrompt.isAtPrompt(focusedProcess) }
    /// The pane `focusedProcess` describes.
    @Published private(set) var focusedProcessPaneId: String?
    /// With several windows, the pane whose process to read: the key
    /// window's, which the engine's single focused pane may not be.
    var processPane: (() -> String?)?

    /// The terminal window acting now, for code that isn't inside one.
    var keyWindow: WindowContext? { WindowRegistry.shared.key }
    /// The key window's pane, tab and prompt state; the engine's focus with
    /// one window.
    var keyPaneId: String? {
        keyWindow?.focusedPaneId ?? snapshot.focusedPaneId ?? snapshot.panes.first(where: \.focused)?.paneId
    }
    var keyTabId: String? { keyWindow?.displayedFocusedTabId ?? displayedFocusedTabId }
    var keyProcess: ShellPrompt.ProcessInfo? { keyWindow.map(\.focusedProcess) ?? focusedProcess }
    var keyPaneAtPrompt: Bool { ShellPrompt.isAtPrompt(keyProcess) }
    @Published private(set) var isConnected = false
    @Published var lastError: String?

    let client: EngineClient
    let recovery: AgentRecoveryController
    /// Tabs closed with something running, kept running to reopen.
    let closedTabs: ClosedTabsController
    /// Terminals journaled for when the session server dies.
    let shellRecovery: ShellRecoveryController
    /// How full each agent's context is, refreshed from its session file.
    private(set) lazy var usageTracker = AgentUsageTracker(store: self)
    private let resolver = ProjectGrouping.CachedResolver()
    private var refreshScheduled = false
    private var eventThread: Thread?
    private var pollTimer: Timer?

    init(client: EngineClient) {
        self.client = client
        recovery = AgentRecoveryController(client: client)
        closedTabs = ClosedTabsController(client: client)
        shellRecovery = ShellRecoveryController(client: client)
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: Self.stampsKey) as? [String: Double] {
            activity = WorkspaceActivity(stamps: raw.mapValues { Date(timeIntervalSince1970: $0) })
        }
        pinnedWorkspaceIds = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        manuallyNamedTabIds = Set(defaults.stringArray(forKey: Self.manualNamesKey) ?? [])
        seenTips = Set(defaults.stringArray(forKey: Self.seenTipsKey) ?? [])
        let storedIdleAfter = defaults.double(forKey: Self.idleAfterKey)
        if storedIdleAfter > 0 { idleAfter = storedIdleAfter }
    }

    var focusedWorkspace: EngineWorkspace? {
        snapshot.workspaces.first { $0.workspaceId == snapshot.focusedWorkspaceId }
            ?? snapshot.workspaces.first(where: \.focused)
    }

    var focusedWorkspaceTabs: [EngineTab] {
        guard let id = focusedWorkspace?.workspaceId else { return [] }
        return snapshot.tabs(inWorkspace: id)
    }

    // MARK: Optimistic tab state
    // Tab clicks and closes show immediately instead of waiting for the session server's
    // round trip, so the tab bar animates the moment you act.
    @Published private(set) var pendingFocusedTabId: String?
    @Published private(set) var pendingClosedTabIds: Set<String> = []
    private var pendingFocusDeadline = Date.distantPast

    /// Tabs the tab bar shows: the focused workspace's, minus ones closing.
    var displayedTabs: [EngineTab] {
        focusedWorkspaceTabs.filter { !pendingClosedTabIds.contains($0.tabId) }
    }

    var displayedFocusedTabId: String? {
        pendingFocusedTabId ?? snapshot.focusedTabId ?? focusedWorkspaceTabs.first(where: \.focused)?.tabId
    }

    private func settleOptimisticTabs(with snapshot: EngineSnapshot) {
        if let pending = pendingFocusedTabId,
           snapshot.focusedTabId == pending || Date() > pendingFocusDeadline
            || !snapshot.tabs.contains(where: { $0.tabId == pending }) {
            pendingFocusedTabId = nil
        }
        if !pendingClosedTabIds.isEmpty {
            let remaining = pendingClosedTabIds.filter { id in snapshot.tabs.contains { $0.tabId == id } }
            if remaining != pendingClosedTabIds { pendingClosedTabIds = remaining }
        }
    }

    // MARK: - Lifecycle

    func start() {
        let client = self.client
        let thread = Thread { [weak self] in
            while self != nil {
                do {
                    try client.subscribe(connectionCreated: { _ in
                        Task { @MainActor [weak self] in
                            self?.isConnected = true
                            self?.scheduleRefresh()
                        }
                    }, onEvent: { _ in
                        Task { @MainActor [weak self] in self?.scheduleRefresh() }
                    })
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.isConnected {
                            self.recovery.connectionLost()
                            self.shellRecovery.connectionLost()
                        }
                        self.isConnected = false
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "octet.terminal-events"
        eventThread = thread
        thread.start()
        // Agent state changes are per-pane subscriptions in the session server; a light
        // periodic snapshot keeps state glyphs current.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        // Workspaces cross the idle threshold with no snapshot change.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.repartition() }
        }
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refreshPaneProcesses(in workspaceId: String?, nativeRoots: [String: Int] = [:]) {
        guard !loadingPaneProcesses else { return }
        // Inspect all panes so the global agent board includes model CLIs
        // spawned outside the workspace currently in front. RuntimePanel
        // still filters what it draws to the selected tab/session.
        let panes = snapshot.panes
        guard !panes.isEmpty || !nativeRoots.isEmpty else {
            paneProcesses = [:]
            nativeRuntimeProcesses = [:]
            spawnedRuntimeAgents = []
            terminalRuntimes = [:]
            return
        }
        loadingPaneProcesses = true
        let client = self.client
        let runtimeLogs = self.runtimeLogs
        // The session each Claude Code pane is on, for reading its log.
        let claudeSessions: [String: (sessionId: String, cwds: [String])] = snapshot.agents.reduce(into: [:]) { found, agent in
            guard AgentBrand.forAgent(agent.agent)?.id == "claude",
                  let sessionId = agent.sessionReference ?? agent.terminalId.flatMap({ recovery.sessionId(forTerminal: $0) })
            else { return }
            found[agent.paneId] = (sessionId, agent.searchCwds)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [String: ShellPrompt.ProcessInfo] = [:]
            for pane in panes {
                if let info = (try? client.call("pane.process_info", ["pane_id": pane.paneId])).flatMap(ShellPrompt.parse) {
                    found[pane.paneId] = info
                }
            }
            let processTree = Self.processTree()
            // Only the wrapper is left out of the lists; what a tool call
            // starts is still found beneath it in the tree.
            let toolShells = Self.agentToolShells(among: processTree.filter { process in
                let command = (process.name as NSString).lastPathComponent.lowercased()
                return ShellPrompt.shells.contains(command) || ShellPrompt.shells.contains("-" + command)
            }.map(\.pid))
            for (paneId, info) in found {
                var enriched = info
                let namedAgentRoots = info.foreground.filter { process in
                    let command = (process.name as NSString).lastPathComponent
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    return AgentBrand.forAgent(command)?.id == "claude"
                }
                let directChildren = info.foreground.filter { foreground in
                    processTree.contains { $0.pid == foreground.pid && $0.parent == info.shellPid }
                }
                let nonShell = info.foreground.filter { process in
                    let command = (process.name as NSString).lastPathComponent.lowercased()
                    return !ShellPrompt.shells.contains(command) && !ShellPrompt.shells.contains("-" + command)
                }
                let rootProcesses: [(name: String, pid: Int)]
                if !namedAgentRoots.isEmpty {
                    rootProcesses = namedAgentRoots
                } else if !directChildren.isEmpty {
                    rootProcesses = directChildren
                } else {
                    rootProcesses = Array(nonShell.prefix(1))
                }
                let roots = Set(rootProcesses.map(\.pid))
                enriched.background = Self.descendants(of: roots, in: processTree)
                    .filter { !toolShells.contains($0.pid) }
                    .map { (name: $0.name, pid: $0.pid) }
                found[paneId] = enriched
            }
            var logRuntimes: [String: [HandoffRuntime]] = [:]
            for (paneId, session) in claudeSessions {
                let claude = found[paneId]?.foreground.first { process in
                    let command = (process.name as NSString).lastPathComponent
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    return AgentBrand.forAgent(command)?.id == "claude"
                }
                // No Claude process in the pane means nothing it started runs.
                guard let claude else { continue }
                let live = runtimeLogs.live(sessionId: session.sessionId, cwds: session.cwds,
                                            processStart: AgentRuntimeHandoff.processStart(pid: claude.pid))
                if !live.isEmpty { logRuntimes[paneId] = live }
            }
            runtimeLogs.forget(except: Set(claudeSessions.values.map(\.sessionId)))
            var nativeFound: [String: [RuntimeChildProcess]] = [:]
            for (sessionId, pid) in nativeRoots {
                nativeFound[sessionId] = Self.descendants(of: [pid], in: processTree)
                    .filter { !toolShells.contains($0.pid) }
                    .map { RuntimeChildProcess(pid: $0.pid, parentPid: $0.parent, name: $0.name) }
            }
            var spawned: [Int: SpawnedRuntimeAgent] = [:]
            for pane in panes {
                guard let processes = found[pane.paneId]?.background else { continue }
                for process in processes {
                    guard let agent = AgentBrand.runtimeAgentID(forExecutable: process.name) else { continue }
                    let parent = processTree.first { $0.pid == process.pid }?.parent ?? 0
                    spawned[process.pid] = SpawnedRuntimeAgent(
                        pid: process.pid, parentPid: parent, agent: agent,
                        name: AgentBrand.forAgent(agent)?.displayName ?? agent,
                        paneId: pane.paneId, tabId: pane.tabId, workspaceId: pane.workspaceId,
                        cwd: pane.foregroundCwd ?? pane.cwd
                    )
                }
            }
            for processes in nativeFound.values {
                for process in processes {
                    guard let agent = AgentBrand.runtimeAgentID(forExecutable: process.name),
                          spawned[process.pid] == nil else { continue }
                    spawned[process.pid] = SpawnedRuntimeAgent(
                        pid: process.pid, parentPid: process.parentPid, agent: agent,
                        name: AgentBrand.forAgent(agent)?.displayName ?? agent,
                        paneId: nil, tabId: nil, workspaceId: workspaceId, cwd: nil
                    )
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingPaneProcesses = false
                self.paneProcesses = found
                self.nativeRuntimeProcesses = nativeFound
                self.spawnedRuntimeAgents = spawned.values.sorted { $0.pid < $1.pid }
                if logRuntimes != self.terminalRuntimes { self.terminalRuntimes = logRuntimes }
            }
        }
    }

    /// Matches what runs under each pane's shell against plugin runtime
    /// rules. Panes running an agent are left to the agent's own mark.
    func refreshPaneRuntimes(matcher: RuntimeMatcher) {
        guard !loadingPaneRuntimes else { return }
        loadingPaneRuntimes = true
        let client = self.client
        let agentPanes = Set(snapshot.agents.map(\.paneId))
        let panes = snapshot.panes.filter { !agentPanes.contains($0.paneId) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tree = Self.processArguments()
            var found: [String: RuntimeBadge] = [:]
            var ssh: [String: SSHTarget] = [:]
            for pane in panes {
                guard let info = (try? client.call("pane.process_info", ["pane_id": pane.paneId])).flatMap(ShellPrompt.parse),
                      let shell = info.shellPid else { continue }
                // Typed at the prompt, ssh is the shell's own child; one
                // deeper was started by something else (git, rsync).
                if let target = tree.lazy.filter({ $0.parent == shell }).compactMap({ SSHTarget.parse(commandLine: $0.arguments) }).first {
                    ssh[pane.paneId] = target
                }
                guard !matcher.isEmpty else { continue }
                let commands = Self.descendants(of: [shell], in: tree.map { RuntimeProcess(pid: $0.pid, parent: $0.parent, name: $0.arguments) })
                    .map { RuntimeMatcher.words($0.name) }
                let folder = pane.effectiveCwd
                if let badge = matcher.match(commands: commands, dependencies: {
                    folder.map(RuntimeMatcher.packageDependencies(from:)) ?? []
                }) {
                    found[pane.paneId] = badge
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingPaneRuntimes = false
                if found != self.paneRuntimes { self.paneRuntimes = found }
                self.sshScans += 1
                if ssh != self.paneSSH { self.paneSSH = ssh }
            }
        }
    }

    /// Every process with its full arguments, for runtime matching.
    private nonisolated static func processArguments() -> [(pid: Int, parent: Int, arguments: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { return nil }
            return (pid, parent, String(fields[2]))
        }
    }

    private struct RuntimeProcess {
        let pid: Int
        let parent: Int
        let name: String
    }

    /// One process-table read enriches every pane. This is intentionally only
    /// called while the Runtime panel is open.
    private nonisolated static func processTree() -> [RuntimeProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { return nil }
            return RuntimeProcess(pid: pid, parent: parent, name: String(fields[2]))
        }
    }

    /// Claude Code runs each Bash call in a `zsh -c` that sources its shell
    /// snapshot. Those are tool calls, already shown in the transcript (and
    /// background ones as tasks), not shells the agent opened.
    private nonisolated static func agentToolShells(among pids: [Int]) -> Set<Int> {
        guard !pids.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,args=", "-p", pids.map(String.init).joined(separator: ",")]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1].contains("/.claude/shell-snapshots/") else { return nil }
            return Int(fields[0])
        })
    }

    private nonisolated static func descendants(of roots: Set<Int>, in tree: [RuntimeProcess]) -> [RuntimeProcess] {
        var family = roots
        var changed = true
        while changed {
            changed = false
            for process in tree where family.contains(process.parent) && !family.contains(process.pid) {
                family.insert(process.pid)
                changed = true
            }
        }
        return tree.filter { family.contains($0.pid) && !roots.contains($0.pid) }
    }

    /// `then` runs once the new snapshot is applied, or it failed.
    func refresh(then: (@MainActor () -> Void)? = nil) {
        let client = self.client
        let inference = recovery.inferenceRequest()
        let chosenPane = processPane?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try client.snapshot() }
            // Disk reads stay off the main thread.
            let snapshot = try? result.get()
            // One extra call: what the focused pane is actually running.
            let focusedPaneId = chosenPane.flatMap { id in snapshot?.panes.contains { $0.paneId == id } == true ? id : nil }
                ?? snapshot?.focusedPaneId
                ?? snapshot?.panes.first(where: \.focused)?.paneId
            let process = focusedPaneId.flatMap { paneId in
                (try? client.call("pane.process_info", ["pane_id": paneId])).flatMap(ShellPrompt.parse)
            }
            let branches = snapshot.map(Self.readBranches)
            let locations = snapshot.map(Self.readLocations)
            let inferred = snapshot.flatMap { snapshot in
                inference.map { AgentSessionFiles.infer(agents: snapshot.agents, firstSeen: $0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    if process != self.focusedProcess { self.focusedProcess = process }
                    if focusedPaneId != self.focusedProcessPaneId { self.focusedProcessPaneId = focusedPaneId }
                    // Closed tabs wait in a workspace nothing else sees.
                    self.closedTabs.observe(snapshot)
                    let visible = ClosedTabs.visible(snapshot)
                    self.recovery.observe(visible, inferred: inferred ?? [:])
                    self.shellRecovery.observe(visible)
                    self.apply(visible, branches: branches ?? [:], locations: locations ?? [:])
                case .failure(let error):
                    self.lastError = String(describing: error)
                }
                then?()
            }
        }
    }

    func apply(_ snapshot: EngineSnapshot, branches: [String: String], locations: [String: AgentLocation] = [:]) {
        settleOptimisticTabs(with: snapshot)
        observeActivity(snapshot)
        autoNameTabs(in: snapshot)
        notifyAgentActivity(in: snapshot)
        usageTracker.refreshIfDue()
        AgentOfferCenter.shared.observe(snapshot)
        refreshTip()
        if branches != self.branches { self.branches = branches }
        if locations != self.agentLocations { self.agentLocations = locations }
        guard snapshot != self.snapshot || groups.isEmpty else { return }
        self.snapshot = snapshot
        let groups = ProjectGrouping.groups(snapshot: snapshot, resolveRoot: resolver.root(for:))
        if groups != self.groups { self.groups = groups }
        repartition()
    }

    private nonisolated static func readBranches(_ snapshot: EngineSnapshot) -> [String: String] {
        var branches: [String: String] = [:]
        for workspace in snapshot.workspaces {
            if let directory = snapshot.directory(ofWorkspace: workspace.workspaceId),
               let branch = GitBranch.current(in: directory) {
                branches[workspace.workspaceId] = branch
            }
        }
        return branches
    }

    /// Each subagent's reported folder, seen from where its tab opened.
    private nonisolated static func readLocations(_ snapshot: EngineSnapshot) -> [String: AgentLocation] {
        var locations: [String: AgentLocation] = [:]
        for agent in snapshot.agents {
            guard let cwd = agent.reportedCwd else { continue }
            let home = snapshot.panes.first { $0.paneId == agent.paneId }?.cwd
                ?? agent.workspaceId.flatMap(snapshot.directory(ofWorkspace:))
            locations[agent.paneId] = AgentLocations.locate(cwd, home: home)
        }
        return locations
    }

    /// Where the agents of a workspace have gone, one entry per place.
    func agentLocations(inWorkspace workspaceId: String) -> [(location: AgentLocation, count: Int)] {
        AgentLocations.grouped(snapshot.agents(inWorkspace: workspaceId).compactMap { agentLocations[$0.paneId] })
    }

    /// Where a tab's agent has gone, if anywhere.
    func agentLocation(inTab tabId: String) -> AgentLocation? {
        primaryAgent(in: snapshot.agents(inTab: tabId)).flatMap { agentLocations[$0.paneId] }
    }

    // MARK: - Remote machines

    /// Machines the engine has saved, refreshed when the palette opens.
    @Published private(set) var remoteMachines: [RemoteMachine] = []

    func refreshRemoteMachines() {
        guard let herdr = EngineSession.locateEngine() else { return }
        PluginCLI.runShell("\(PluginCLI.quote(herdr)) machine list --json", timeout: 30) { [weak self] result in
            let machines = RemoteMachines.parse(Data(result.output.utf8))
            guard let self, machines != self.remoteMachines else { return }
            self.remoteMachines = machines
        }
    }

    /// Opens a session on a machine in a new tab of the focused workspace.
    func openRemote(_ machine: RemoteMachine, workspaceId: String? = nil) {
        guard let herdr = EngineSession.locateEngine() else { return }
        var params: [String: Any] = [
            "focus": true,
            "tab_label": machine.label,
            "root": [
                "type": "pane",
                "label": machine.label,
                "command": machine.command(herdrPath: herdr, session: RemoteMachines.sessionName(for: machine)),
            ] as [String: Any],
        ]
        if let workspace = workspaceId ?? focusedWorkspace?.workspaceId { params["workspace_id"] = workspace }
        perform("layout.apply", params, toast: ToastText(
            progress: "Connecting to \(machine.label)…",
            success: "Opened \(machine.label)",
            failure: "Couldn't open \(machine.label)"
        ))
    }

    /// Asks the engine to prepare a machine; it does the ssh work.
    func addRemoteMachine(target: String) {
        guard let herdr = EngineSession.locateEngine() else { return }
        let handle = toasts.progress("Preparing \(target)…", detail: "Setting up the far side over ssh")
        PluginCLI.runShell("\(PluginCLI.quote(herdr)) machine add \(PluginCLI.quote(target))", timeout: 300) { [weak self] result in
            guard let self else { return }
            if result.exitCode == 0 {
                self.toasts.succeed(handle, "Added \(target)")
            } else {
                self.toasts.fail(handle, "Couldn't add \(target)", detail: PluginCLI.lastLines(result.output))
            }
            self.refreshRemoteMachines()
        }
    }

    // MARK: - Agent notices

    private var activityWatcher = AgentActivityWatcher()

    /// Raises a banner when an agent stops working, unless you are already
    /// looking at that pane.
    private func notifyAgentActivity(in snapshot: EngineSnapshot) {
        var shown = WindowRegistry.shared.shownTabIds
        if shown.isEmpty, let tab = displayedFocusedTabId ?? snapshot.focusedTabId { shown.insert(tab) }
        let appActive = NSApp?.isActive == true
        let events = activityWatcher.events(in: snapshot) { agent in
            appActive && agent.tabId.map(shown.contains) == true
        }
        guard !events.isEmpty else { return }
        AgentBannerCenter.shared.show(events)
    }

    /// Jumps to the pane a banner came from.
    func focus(_ event: AgentEvent) {
        if let tab = snapshot.tabs.first(where: { $0.tabId == event.tabId }) {
            focusTabAnywhere(tab)
        }
        focusAgent(paneId: event.paneId)
        OctetTerminalRuntime.focusTerminal()
    }

    // MARK: - Tips

    /// The tip shown at the foot of the sidebar, if any.
    @Published private(set) var currentTip: Tip?
    private var seenTips: Set<String> = []
    private static let seenTipsKey = "octet.tips.seen" + keySuffix

    private func refreshTip() {
        guard SettingsStore.shared.values.showTips else {
            currentTip = nil
            return
        }
        let context = tipContext()
        // Keep the current tip while it still fits the session.
        if let currentTip, currentTip.applies(context) { return }
        currentTip = Tips.next(seen: seenTips, context: context)
        markTipSeen()
    }

    /// `3/12`, so it reads as something to page through.
    var tipPosition: String {
        let relevant = Tips.all.filter { $0.applies(tipContext()) }
        guard let currentTip, let index = relevant.firstIndex(of: currentTip) else { return "" }
        return "\(index + 1)/\(relevant.count)"
    }

    /// Steps to another tip on click.
    func nextTip() {
        currentTip = Tips.following(currentTip, seen: seenTips, context: tipContext())
        markTipSeen()
    }

    /// The × on the card: no more tips until Settings turns them back on.
    func dismissTips() {
        SettingsStore.shared.values.showTips = false
        currentTip = nil
    }

    private func markTipSeen() {
        guard let currentTip, seenTips.insert(currentTip.id).inserted else { return }
        UserDefaults.standard.set(Array(seenTips), forKey: Self.seenTipsKey)
    }

    private func tipContext() -> TipContext {
        TipContext(
            workspaceCount: snapshot.workspaces.count,
            tabCount: snapshot.tabs.count,
            agentCount: snapshot.agents.count,
            idleCount: idleWorkspaces.count,
            hasRecoverableSessions: !recovery.resumableSessions().isEmpty,
            hasUnnamedTabs: snapshot.tabs.contains { TabAutoName.isUnnamed($0.label) },
            hasWorktree: snapshot.workspaces.contains { $0.worktree != nil },
            hasPlugins: !plugins.isEmpty
        )
    }

    // MARK: - Tab names

    /// Renames tabs to the work their pane reports, for any agent or shell.
    private func autoNameTabs(in snapshot: EngineSnapshot) {
        guard SettingsStore.shared.values.autoNameTabs else {
            pendingTabNames.removeAll()
            return
        }
        let present = Set(snapshot.tabs.map(\.tabId))
        if manuallyNamedTabIds.contains(where: { !present.contains($0) }) {
            manuallyNamedTabIds.formIntersection(present)
            UserDefaults.standard.set(Array(manuallyNamedTabIds), forKey: Self.manualNamesKey)
        }
        let renames = TabAutoName.renames(snapshot: snapshot, manual: manuallyNamedTabIds, pending: &pendingTabNames)
        for rename in renames {
            perform("tab.rename", ["tab_id": rename.tabId, "label": rename.label])
        }
    }

    /// Stops auto-naming a tab the user named themselves.
    private func markManuallyNamed(_ tabId: String) {
        guard manuallyNamedTabIds.insert(tabId).inserted else { return }
        pendingTabNames[tabId] = nil
        UserDefaults.standard.set(Array(manuallyNamedTabIds), forKey: Self.manualNamesKey)
    }

    /// Lets a tab follow its work again.
    func resumeAutoNaming(_ tabId: String) {
        guard manuallyNamedTabIds.remove(tabId) != nil else { return }
        UserDefaults.standard.set(Array(manuallyNamedTabIds), forKey: Self.manualNamesKey)
        scheduleRefresh()
    }

    func isManuallyNamed(_ tabId: String) -> Bool { manuallyNamedTabIds.contains(tabId) }

    // MARK: - Idle organization

    /// Stamps activity. The focused workspace counts as in use only while
    /// Octet is the active app, so leaving Octet open overnight doesn't keep it fresh.
    private func observeActivity(_ snapshot: EngineSnapshot) {
        var updated = activity
        // The window in front's workspace: with several, the engine's focus
        // is only whichever moved last.
        let focused = keyWindow?.focusedWorkspace?.workspaceId ?? snapshot.focusedWorkspaceId
        if let focused, focused != lastFocusedWorkspaceId, lastFocusedWorkspaceId != nil {
            forcedIdle.remove(focused)
        }
        lastFocusedWorkspaceId = focused
        let viewed = NSApp?.isActive == true && !forcedIdle.contains(focused ?? "") ? focused : nil
        updated.observe(snapshot, viewedWorkspaceId: viewed) { workspace in
            let claudeCwds = snapshot.agents(inWorkspace: workspace.workspaceId)
                .filter { AgentBrand.forAgent($0.agent)?.id == "claude" }
                .compactMap { $0.cwd }
            return claudeCwds.compactMap { ClaudeTranscriptActivity.lastActive(forCwd: $0) }.max()
        }
        guard updated != activity else { return }
        activity = updated
        if Date().timeIntervalSince(lastStampSave) > 10 {
            lastStampSave = Date()
            UserDefaults.standard.set(activity.stamps.mapValues { $0.timeIntervalSince1970 }, forKey: Self.stampsKey)
        }
        repartition()
    }

    func repartition() {
        let split = activity.partition(
            snapshot.workspaces, snapshot: snapshot, pinned: pinnedWorkspaceIds, idleAfter: idleAfter
        )
        let idleIds = Set(split.idle.map(\.workspaceId))
        let active = groups.compactMap { group -> ProjectGroup? in
            let members = group.workspaces.filter { !idleIds.contains($0.workspaceId) }
            return members.isEmpty ? nil : ProjectGroup(id: group.id, name: group.name, workspaces: members)
        }
        if active != activeGroups { activeGroups = active }
        if split.idle != idleWorkspaces { idleWorkspaces = split.idle }
    }

    func isPinned(_ workspaceId: String) -> Bool { pinnedWorkspaceIds.contains(workspaceId) }

    func setPinned(_ workspaceId: String, _ pinned: Bool) {
        if pinned { pinnedWorkspaceIds.insert(workspaceId) } else { pinnedWorkspaceIds.remove(workspaceId) }
        UserDefaults.standard.set(Array(pinnedWorkspaceIds), forKey: Self.pinnedKey)
        repartition()
    }

    /// Moves a workspace to Idle now (unless it is pinned, focused, or busy).
    func markIdle(_ workspaceId: String) {
        setPinned(workspaceId, false)
        forcedIdle.insert(workspaceId)
        let showing = keyWindow?.focusedWorkspace?.workspaceId ?? snapshot.focusedWorkspaceId
        let elsewhere = WindowRegistry.shared.shownWorkspaceIds()
        if workspaceId == showing,
           let next = activeGroups.flatMap(\.workspaces).first(where: { $0.workspaceId != workspaceId && !elsewhere.contains($0.workspaceId) }) {
            lastFocusedWorkspaceId = next.workspaceId
            if let window = keyWindow { window.focusWorkspace(next.workspaceId) } else { focusWorkspace(next.workspaceId) }
        }
        var updated = activity
        updated.markIdle(workspaceId)
        activity = updated
        repartition()
    }

    /// Project name for a workspace, for compact idle rows.
    func projectName(of workspaceId: String) -> String? {
        groups.first { $0.workspaces.contains { $0.workspaceId == workspaceId } }?.name
    }

    func closeIdleWorkspaces() {
        let targets = idleWorkspaces
        guard !targets.isEmpty else { return }
        let client = self.client
        let handle = toasts.progress("Closing \(targets.count) idle workspace\(targets.count == 1 ? "" : "s")…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for workspace in targets {
                do {
                    try client.call("workspace.close", ["workspace_id": workspace.workspaceId])
                } catch {
                    failures.append("\(workspace.label): \(Self.describeNonisolated(error))")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let closed = targets.count - failures.count
                if failures.isEmpty {
                    self.toasts.succeed(handle, "Closed \(closed) idle workspace\(closed == 1 ? "" : "s")")
                } else {
                    self.toasts.fail(handle, "Closed \(closed) of \(targets.count) idle workspaces",
                                     detail: failures.prefix(3).joined(separator: "\n"))
                }
                self.scheduleRefresh()
            }
        }
    }

    private nonisolated static func describeNonisolated(_ error: Error) -> String {
        if case EngineSocketError.server(_, let message) = error, !message.isEmpty { return message }
        return String(describing: error)
    }

    // MARK: - Actions

    /// Toast copy for a lasting action: shown while running and when done.
    struct ToastText {
        let progress: String
        let success: String
        let failure: String
    }

    private var toasts: ToastCenter { .shared }

    private func perform(
        _ method: String,
        _ params: [String: Any],
        toast text: ToastText? = nil,
        failure failureTitle: String? = nil,
        then: (@MainActor ([String: Any]) -> Void)? = nil
    ) {
        let client = self.client
        let handle = text.map { toasts.progress($0.progress) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try client.call(method, params) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    if let text { self.toasts.succeed(handle, text.success) }
                    then?(result)
                case .failure(let error):
                    let message = Self.describe(error)
                    if let text {
                        self.toasts.fail(handle, text.failure, detail: message)
                    } else if let failureTitle {
                        self.toasts.fail(nil, failureTitle, detail: message)
                    } else {
                        self.lastError = message
                    }
                }
                self.scheduleRefresh()
            }
        }
    }

    /// An engine call for a window that steers itself: failures are toasted,
    /// and `then` hears where anything it created ended up.
    func call(_ method: String, _ params: [String: Any], failure: String,
              then: @escaping @MainActor (EngineCreated) -> Void) {
        // What was made has to be in the snapshot before a window can be
        // steered to it by position.
        perform(method, params, failure: failure) { [weak self] result in
            self?.refresh { then(EngineCreated(result: result)) }
        }
    }

    private static func describe(_ error: Error) -> String {
        if case EngineSocketError.server(_, let message) = error, !message.isEmpty { return message }
        return String(describing: error)
    }

    private func tabLabel(_ id: String) -> String {
        snapshot.tabs.first { $0.tabId == id }.map { tab in
            TabAutoName.isUnnamed(tab.label) ? "the new tab" : tab.label
        } ?? "tab"
    }

    private func workspaceLabel(_ id: String) -> String {
        snapshot.workspaces.first { $0.workspaceId == id }?.label ?? "workspace"
    }

    func focusWorkspace(_ id: String) { perform("workspace.focus", ["workspace_id": id]) }
    func focusTab(_ id: String) {
        AgentCenter.shared.activeId = nil
        AgentCenter.shared.board = nil
        pendingFocusedTabId = id
        pendingFocusDeadline = Date().addingTimeInterval(1.5)
        // Settles on the next snapshot, or after the deadline if the session server refused.
        perform("tab.focus", ["tab_id": id], failure: "Couldn't switch tabs")
    }

    func closeTab(_ id: String) {
        let label = tabLabel(id)
        let tabs = displayedTabs
        if id == displayedFocusedTabId, let index = tabs.firstIndex(where: { $0.tabId == id }), tabs.count > 1 {
            // Show the neighbor the session server will focus while the close is in flight.
            pendingFocusedTabId = tabs[index > 0 ? index - 1 : 1].tabId
            pendingFocusDeadline = Date().addingTimeInterval(1.5)
        }
        pendingClosedTabIds.insert(id)
        let tab = snapshot.tabs.first { $0.tabId == id }
        closedTabs.close(panes: snapshot.panes.filter { $0.tabId == id },
                         title: tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? label,
                         workspace: snapshot.workspaces.first { $0.workspaceId == tab?.workspaceId }) { [weak self] in
            self?.perform("tab.close", ["tab_id": id], failure: "Couldn't close \(label)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.pendingClosedTabIds.remove(id)
        }
    }

    func closeWorkspace(_ id: String) {
        let label = workspaceLabel(id)
        perform("workspace.close", ["workspace_id": id], failure: "Couldn't close workspace \(label)")
    }

    func renameTab(_ id: String, to label: String) {
        markManuallyNamed(id)
        perform("tab.rename", ["tab_id": id, "label": label], failure: "Couldn't rename tab")
    }

    func newTab() {
        var params: [String: Any] = ["focus": true]
        if let workspace = focusedWorkspace {
            params["workspace_id"] = workspace.workspaceId
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { params["cwd"] = cwd }
        }
        perform("tab.create", params, failure: "Couldn't open a tab")
    }

    /// A terminal tab already running an agent. The terminal doesn't care
    /// which agent it is, so anything discovery found can open one: the CLI
    /// runs by its resolved path, and the shell takes over when it exits, so
    /// the tab stays useful rather than closing under you.
    func newTab(running agent: DiscoveredAgent) {
        guard var params = agentTabParams(agent, workspaceId: focusedWorkspace?.workspaceId) else { return }
        params["focus"] = true
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.call("layout.apply", params)
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't open \(agent.displayName) in a tab",
                                            detail: String(describing: error))
                }
            }
        }
    }

    /// The `layout.apply` for a tab running `agent` in `workspaceId`.
    func agentTabParams(_ agent: DiscoveredAgent, workspaceId: String?) -> [String: Any]? {
        guard let path = agent.executablePath else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cwd = workspaceId.flatMap { snapshot.directory(ofWorkspace: $0) } ?? NSHomeDirectory()
        var params: [String: Any] = [
            "tab_label": agent.displayName,
            "root": ["type": "pane", "label": agent.displayName, "cwd": cwd,
                     "command": [shell, "-lic", "\(shellQuote(path)); exec \(shell) -l"]] as [String: Any],
        ]
        if let workspaceId { params["workspace_id"] = workspaceId }
        return params
    }

    // MARK: - Moving tabs into splits

    /// The panes of a tab, for the drop zones a dragged tab shows over it.
    func paneLayout(ofTab tabId: String, completion: @escaping (PaneLayout?) -> Void) {
        guard let pane = snapshot.panes.first(where: { $0.tabId == tabId }) else { return completion(nil) }
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let layout = (try? client.call("pane.layout", ["pane_id": pane.paneId])).flatMap(PaneLayout.parse)
            DispatchQueue.main.async { completion(layout) }
        }
    }

    /// The one pane a tab holds, if it holds only one. A tab dragged onto the
    /// terminal becomes a split by moving its pane, so a tab already split
    /// has no single pane to move.
    func onlyPane(ofTab tabId: String) -> EnginePane? {
        let panes = snapshot.panes.filter { $0.tabId == tabId }
        return panes.count == 1 ? panes.first : nil
    }

    /// Moves a single-pane tab into `targetTab`, beside `targetPane` on
    /// `edge`. The tab it leaves is empty and the engine closes it.
    func splitTab(_ tabId: String, into targetTab: String, beside targetPane: String, edge: SplitEdge) {
        guard tabId != targetTab, let moving = onlyPane(ofTab: tabId) else { return }
        let client = self.client
        let multi = WindowRegistry.shared.isMulti
        let destination: [String: Any] = ["type": "tab", "tab_id": targetTab, "target_pane_id": targetPane, "split": edge.split]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result {
                // Several windows: `focus` would move every one of them.
                try client.call("pane.move", ["pane_id": moving.paneId, "destination": destination, "focus": !multi])
                if edge.swaps {
                    try client.call("pane.swap", ["source_pane_id": moving.paneId, "target_pane_id": targetPane])
                }
            }
            DispatchQueue.main.async {
                if case .failure(let error) = outcome {
                    ToastCenter.shared.fail(nil, "Couldn't split the tab in", detail: String(describing: error))
                }
                self?.scheduleRefresh()
                OctetTerminalRuntime.focusTerminal()
            }
        }
    }

    /// The focused pane, out of its split and into a tab of its own: the way
    /// back from dragging a tab in.
    func moveFocusedPaneToNewTab() {
        guard let paneId = snapshot.focusedPaneId,
              let tabId = snapshot.panes.first(where: { $0.paneId == paneId })?.tabId,
              snapshot.panes.filter({ $0.tabId == tabId }).count > 1 else { return }
        perform("pane.move", ["pane_id": paneId, "destination": ["type": "new_tab"], "focus": true],
                failure: "Couldn't move the pane to a new tab")
    }

    /// Types a line into the focused pane's shell and runs it, as if typed,
    /// then gives the terminal back its keyboard focus.
    func runInFocusedPane(_ line: String) {
        guard let paneId = snapshot.focusedPaneId else { return }
        runInPane(paneId, line: line)
    }

    /// Types a line into `paneId`'s shell and runs it.
    func runInPane(_ paneId: String, line: String) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("pane.send_text", ["pane_id": paneId, "text": line + "\r"]) }
            if case .failure(let error) = outcome {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't run that in the terminal", detail: String(describing: error))
                }
            }
        }
        OctetTerminalRuntime.focusTerminal()
    }

    /// Starts an agent in the focused pane: by name when the shell would find
    /// it, else by the path discovery found it at.
    func runInFocusedPane(_ agent: DiscoveredAgent) {
        guard let path = agent.executablePath else { return }
        runInFocusedPane(agent.onShellPath == true ? agent.command : shellQuote(path))
    }

    /// ⌘⇧A: the agents board for the tab in front (Codex's in a Codex tab,
    /// otherwise Claude's), or closes whichever is open.
    func toggleAgentsBoard() {
        let center = AgentCenter.shared
        if center.board != nil { center.board = nil; return }
        let agent = displayedFocusedTabId.flatMap { primaryAgent(in: snapshot.agents(inTab: $0)) }
        center.board = AgentBrand.forAgent(agent?.agent)?.id == "codex" ? .codex : .claude
    }

    /// A native conversation in the focused workspace's folder, with either
    /// agent. Both run headless and draw in the same view.
    func newConversation(engine: AgentSession.Engine = .claude) {
        guard let workspace = focusedWorkspace else { return }
        let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) ?? NSHomeDirectory()
        AgentCenter.shared.newConversation(workspaceId: workspace.workspaceId, cwd: cwd, engine: engine)
    }

    func newWorkspace(cwd: String? = nil) {
        var params: [String: Any] = ["focus": true]
        if let cwd { params["cwd"] = cwd }
        perform("workspace.create", params, failure: "Couldn't create a workspace")
    }

    /// Tab 1–9 of the focused workspace (9 = last).
    func selectTab(number: Int) {
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        focusTab(tabs[index].tabId)
    }

    func selectAdjacentTab(offset: Int) {
        let tabs = focusedWorkspaceTabs
        guard let current = tabs.firstIndex(where: { $0.tabId == displayedFocusedTabId }) ?? tabs.firstIndex(where: \.focused),
              !tabs.isEmpty else { return }
        focusTab(tabs[(current + offset + tabs.count) % tabs.count].tabId)
    }

    /// Next/previous workspace in sidebar order: active projects, then idle.
    func selectAdjacentWorkspace(offset: Int) {
        let ordered = activeGroups.flatMap(\.workspaces) + idleWorkspaces
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.workspaceId == focusedWorkspace?.workspaceId } ?? 0
        focusWorkspace(ordered[(current + offset + ordered.count) % ordered.count].workspaceId)
    }

    func closeFocusedTab() {
        guard let id = displayedFocusedTabId else { return }
        closeTab(id)
    }

    func renameWorkspace(_ id: String, to label: String) {
        perform("workspace.rename", ["workspace_id": id, "label": label], failure: "Couldn't rename workspace")
    }

    /// Renames from an edit field: nil (cancelled), blank or unchanged
    /// names are left alone.
    func renameWorkspace(_ id: String, to label: String?, from current: String) {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty, label != current else { return }
        renameWorkspace(id, to: label)
    }

    var focusedPaneId: String? {
        snapshot.focusedPaneId ?? snapshot.panes.first(where: \.focused)?.paneId
    }

    enum SplitDirection: String { case right, down }
    enum PaneDirection: String { case left, right, up, down }

    func splitPane(_ direction: SplitDirection) {
        var params: [String: Any] = ["direction": direction.rawValue, "focus": true]
        if let pane = focusedPaneId { params["target_pane_id"] = pane }
        if let workspace = focusedWorkspace,
           let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) {
            params["cwd"] = cwd
        }
        perform("pane.split", params, failure: "Couldn't split pane")
    }

    func toggleZoom() {
        var params: [String: Any] = ["mode": "toggle"]
        if let pane = focusedPaneId { params["pane_id"] = pane }
        perform("pane.zoom", params)
    }

    func closeFocusedPane() {
        guard let pane = focusedPaneId else { return }
        closePane(pane) { [weak self] in
            self?.perform("pane.close", ["pane_id": pane], failure: "Couldn't close pane")
        }
    }

    /// Closes a pane; one running something waits among the closed tabs.
    func closePane(_ paneId: String, close: @escaping @MainActor () -> Void) {
        guard let pane = snapshot.panes.first(where: { $0.paneId == paneId }) else { return close() }
        let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
        closedTabs.close(panes: [pane], title: tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Pane",
                         workspace: snapshot.workspaces.first { $0.workspaceId == pane.workspaceId }, closeRest: close)
    }

    func focusPane(_ direction: PaneDirection) {
        perform("pane.focus_direction", ["direction": direction.rawValue])
    }

    func focusAgent(paneId: String) { perform("agent.focus", ["target": paneId]) }

    /// Focuses a tab in any workspace.
    func focusTabAnywhere(_ tab: EngineTab) {
        let client = self.client
        let currentWorkspaceId = focusedWorkspace?.workspaceId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if tab.workspaceId != currentWorkspaceId {
                    try client.call("workspace.focus", ["workspace_id": tab.workspaceId])
                }
                try client.call("tab.focus", ["tab_id": tab.tabId])
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
            }
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
    }

    func openProject(path: String) {
        let label = URL(fileURLWithPath: path).lastPathComponent
        if let existing = groups.first(where: { $0.id == path })?.workspaces.first {
            focusWorkspace(existing.workspaceId)
            return
        }
        perform("workspace.create", ["cwd": path, "label": label, "focus": true], failure: "Couldn't open \(label)")
    }

    func createWorktree(branch: String) {
        var params: [String: Any] = ["branch": branch, "focus": true]
        if let workspace = focusedWorkspace { params["workspace_id"] = workspace.workspaceId }
        perform("worktree.create", params, toast: ToastText(
            progress: "Creating worktree \(branch)…", success: "Created worktree \(branch)",
            failure: "Couldn't create worktree \(branch)"
        ))
    }

    func reloadSessionConfig(quiet: Bool = false) {
        if quiet {
            perform("server.reload_config", [:], failure: "Couldn't apply the settings")
        } else {
            perform("server.reload_config", [:], toast: ToastText(
                progress: "Reloading the terminal config…", success: "Reloaded the terminal config", failure: "Couldn't reload the terminal config"
            ))
        }
    }

    func moveFocusedTab(by offset: Int) {
        guard let id = displayedFocusedTabId ?? snapshot.focusedTabId else { return }
        moveTab(id, by: offset)
    }

    /// The tabs of the workspace `id` is in, whichever window shows it.
    private func tabs(besideTab id: String) -> [EngineTab] {
        guard let workspace = snapshot.tabs.first(where: { $0.tabId == id })?.workspaceId else { return [] }
        return snapshot.tabs(inWorkspace: workspace)
    }

    func moveTab(_ id: String, by offset: Int) {
        guard let index = tabs(besideTab: id).firstIndex(where: { $0.tabId == id }) else { return }
        // A gap after the tab's own slot counts from before the move.
        moveTab(id, toGap: offset > 0 ? index + offset + 1 : index + offset)
    }

    /// The session server's `insert_index` is a gap in the current order: the tab lands
    /// just before the tab now at that position (count means the end).
    /// Moving the first of four with insert_index 2 leaves it second.
    func moveTab(_ id: String, toGap gap: Int) {
        moveTab(id, toGap: gap, among: tabs(besideTab: id))
    }

    /// `tabs` is the workspace's order, given when the snapshot doesn't have
    /// the tab yet: one that just moved in from another window.
    func moveTab(_ id: String, toGap gap: Int, among tabs: [EngineTab]) {
        guard let index = tabs.firstIndex(where: { $0.tabId == id }) else { return }
        let gap = max(0, min(tabs.count, gap))
        // Either gap next to the tab leaves it where it is.
        guard gap != index, gap != index + 1 else { return }
        let label = tabLabel(id)
        perform("tab.move", ["tab_id": id, "insert_index": gap], failure: "Couldn't move \(label)")
    }

    func closeTabs(except id: String) {
        for tab in tabs(besideTab: id) where tab.tabId != id { closeTab(tab.tabId) }
    }

    func closeTabs(rightOf id: String) {
        let tabs = tabs(besideTab: id)
        guard let index = tabs.firstIndex(where: { $0.tabId == id }) else { return }
        for tab in tabs[(index + 1)...] { closeTab(tab.tabId) }
    }

    // MARK: - Plugins

    func refreshPlugins() {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plugins: [EnginePlugin]
            do {
                let result = try client.call("plugin.list")
                let data = try JSONSerialization.data(withJSONObject: result["plugins"] ?? [])
                plugins = try JSONDecoder().decode([EnginePlugin].self, from: data)
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
                return
            }
            DispatchQueue.main.async {
                if self?.plugins != plugins { self?.plugins = plugins }
            }
        }
    }

    /// Context the session server passes to plugin commands, matching what the session server's own UI sends.
    var pluginInvocationContext: [String: Any] {
        var context: [String: Any] = ["invocation_source": "octet-palette"]
        let window = keyWindow
        if let workspace = window?.focusedWorkspace ?? focusedWorkspace {
            context["workspace_id"] = workspace.workspaceId
            context["workspace_label"] = workspace.label
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { context["workspace_cwd"] = cwd }
        }
        let tabs = window?.focusedWorkspaceTabs ?? focusedWorkspaceTabs
        if let tab = tabs.first(where: { $0.tabId == (window?.displayedFocusedTabId ?? snapshot.focusedTabId) }) {
            context["tab_id"] = tab.tabId
            context["tab_label"] = tab.label
        }
        if let paneId = window?.focusedPaneId ?? focusedPaneId {
            context["focused_pane_id"] = paneId
            if let pane = snapshot.panes.first(where: { $0.paneId == paneId }) {
                if let cwd = pane.foregroundCwd ?? pane.cwd { context["focused_pane_cwd"] = cwd }
                context["focused_pane_status"] = pane.agentStatus.rawValue
            }
            if let agent = snapshot.agents.first(where: { $0.paneId == paneId })?.agent {
                context["focused_pane_agent"] = agent
            }
        }
        return context
    }

    /// Invokes a plugin action and follows its run in `plugin.log.list` so the
    /// toast reports when the command actually finishes, not just when the session server
    /// accepted it.
    func invokePluginAction(pluginId: String, actionId: String, title: String) {
        let client = self.client
        let handle = toasts.progress("Running \(title)…")
        let started = UInt64(Date().timeIntervalSince1970 * 1000) - 1000
        let params: [String: Any] = ["plugin_id": pluginId, "action_id": actionId, "context": pluginInvocationContext]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try client.call("plugin.action.invoke", params)
            } catch {
                DispatchQueue.main.async { self?.toasts.fail(handle, "Couldn't run \(title)", detail: Self.describe(error)) }
                return
            }
            var log: EnginePluginLog?
            for _ in 0..<240 {
                let logs = (try? client.call("plugin.log.list", ["plugin_id": pluginId, "limit": 10]))
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                    .flatMap { try? JSONDecoder().decode([EnginePluginLog].self, from: $0) } ?? []
                log = logs.filter { $0.actionId == actionId && $0.startedUnixMs >= started }
                    .max { $0.startedUnixMs < $1.startedUnixMs }
                if let log, log.status != "running" { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch log?.status {
                case "succeeded":
                    self.toasts.succeed(handle, "\(title) finished",
                                        detail: log?.stdout.map { PluginCLI.lastLines($0, count: 2) })
                case "failed":
                    let detail = [log?.error, log?.stderr, log?.exitCode.map { "exit \($0)" }]
                        .compactMap { $0 }.first { !$0.isEmpty }
                    self.toasts.fail(handle, "\(title) failed", detail: detail.map { PluginCLI.lastLines($0) })
                default:
                    self.toasts.succeed(handle, "Started \(title)", detail: "Still running. See the plugin's logs.")
                }
                self.scheduleRefresh()
            }
        }
    }

    func openPluginPane(pluginId: String, paneId: String, placement: String?, title: String) {
        var params: [String: Any] = ["plugin_id": pluginId, "entrypoint": paneId, "focus": !WindowRegistry.shared.isMulti]
        // Overlay and popup panes always attach to the active pane; the session server
        // rejects an explicit target for them.
        if let pane = keyPaneId, placement == "split" || placement == "tab" || placement == "zoomed" {
            params["target_pane_id"] = pane
        }
        perform("plugin.pane.open", params, failure: "Couldn't open \(title)")
    }

    private func pluginName(_ pluginId: String) -> String {
        plugins.first { $0.pluginId == pluginId }?.name ?? pluginId
    }

    func setPluginEnabled(_ pluginId: String, _ enabled: Bool) {
        let name = pluginName(pluginId)
        perform(enabled ? "plugin.enable" : "plugin.disable", ["plugin_id": pluginId], toast: ToastText(
            progress: "\(enabled ? "Enabling" : "Disabling") \(name)…",
            success: "\(enabled ? "Enabled" : "Disabled") \(name)",
            failure: "Couldn't \(enabled ? "enable" : "disable") \(name)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    func unlinkPlugin(_ pluginId: String) {
        let name = pluginName(pluginId)
        perform("plugin.unlink", ["plugin_id": pluginId], toast: ToastText(
            progress: "Unlinking \(name)…", success: "Unlinked \(name)", failure: "Couldn't unlink \(name)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    func linkPlugin(path: String) {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        perform("plugin.link", ["path": path], toast: ToastText(
            progress: "Linking \(folder)…", success: "Linked plugin \(folder)", failure: "Couldn't link \(folder)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    /// Downloads the plugin, shows the session server's install preview for confirmation,
    /// then installs it — with a toast for each stage.
    func installPlugin(repo: String, enginePath: String, confirm: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        let handle = toasts.progress("Downloading \(repo)…", detail: "Fetching the install preview")
        PluginCLI.preview(repo: repo, enginePath: enginePath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.toasts.fail(handle, "Couldn't download \(repo)", detail: String(describing: error))
            case .success(let preview):
                let name = PluginCLI.previewField("name", in: preview) ?? repo
                let version = PluginCLI.previewField("version", in: preview)
                self.toasts.dismiss(handleId: handle)
                confirm(preview) { confirmed in
                    guard confirmed else {
                        self.toasts.info("Install cancelled", detail: name)
                        return
                    }
                    let installing = self.toasts.progress("Installing \(name)…", detail: "Running the plugin's build steps")
                    PluginCLI.install(repo: repo, enginePath: enginePath) { outcome in
                        if outcome.exitCode == 0 {
                            self.toasts.succeed(installing, "Installed \(name)\(version.map { " \($0)" } ?? "")")
                        } else {
                            self.toasts.fail(installing, "Couldn't install \(name)", detail: PluginCLI.lastLines(outcome.output))
                        }
                        self.refreshPlugins()
                    }
                }
            }
        }
    }

    func uninstallPlugin(_ pluginId: String, enginePath: String) {
        let name = pluginName(pluginId)
        let handle = toasts.progress("Removing \(name)…")
        PluginCLI.uninstall(pluginId: pluginId, enginePath: enginePath) { [weak self] outcome in
            guard let self else { return }
            if outcome.exitCode == 0 {
                self.toasts.succeed(handle, "Removed \(name)")
            } else {
                self.toasts.fail(handle, "Couldn't remove \(name)", detail: PluginCLI.lastLines(outcome.output))
            }
            self.refreshPlugins()
        }
    }

    func pluginLogs(pluginId: String?, completion: @escaping ([EnginePluginLog]) -> Void) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            var params: [String: Any] = ["limit": 50]
            if let pluginId { params["plugin_id"] = pluginId }
            let logs = (try? client.call("plugin.log.list", params))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                .flatMap { try? JSONDecoder().decode([EnginePluginLog].self, from: $0) } ?? []
            DispatchQueue.main.async { completion(logs) }
        }
    }

    // MARK: - Presentation helpers

    /// The most relevant agent in a set: blocked > working > done > idle.
    func primaryAgent(in agents: [EngineAgent]) -> EngineAgent? {
        let rank: [EngineAgentStatus: Int] = [.blocked: 0, .working: 1, .done: 2, .idle: 3, .unknown: 4]
        return agents.min { (rank[$0.agentStatus] ?? 9) < (rank[$1.agentStatus] ?? 9) }
    }
}

/// Claude Code session logs followed for their runtimes. Only the runtime
/// refresh touches it, one pass at a time, off the main thread.
final class RuntimeLogTails: @unchecked Sendable {
    private struct Tail {
        var path: String
        var offset: UInt64 = 0
        var partial = Data()
        var ledger = RuntimeLedger()
    }

    private var tails: [String: Tail] = [:]

    func live(sessionId: String, cwds: [String], processStart: Date?) -> [HandoffRuntime] {
        var tail = tails[sessionId] ?? {
            let path = cwds.lazy.compactMap { AgentConversation.findLog(sessionIds: [sessionId], cwd: $0) }.first
            return path.map { Tail(path: $0) }
        }() ?? Tail(path: "")
        guard !tail.path.isEmpty, let handle = FileHandle(forReadingAtPath: tail.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A log rewritten shorter is read again from the start.
        if size < tail.offset { tail = Tail(path: tail.path) }
        if size > tail.offset {
            try? handle.seek(toOffset: tail.offset)
            var data = tail.partial
            data.append((try? handle.readToEnd()) ?? Data())
            tail.offset = size
            // A line still being written stays for the next pass.
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                tail.partial = Data(data[data.index(after: lastNewline)...])
                for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
                    tail.ledger.consume(String(decoding: line, as: UTF8.self))
                }
            } else {
                tail.partial = data
            }
        }
        tails[sessionId] = tail
        return tail.ledger.live(processStart: processStart)
    }

    func forget(except sessionIds: Set<String>) {
        tails = tails.filter { sessionIds.contains($0.key) }
    }
}
