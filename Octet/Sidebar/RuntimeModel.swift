import AppKit
import Combine
import SwiftUI

/// What the right panel's Agents tab lists, built once per change rather
/// than on every redraw. The view used to rebuild every entry several times
/// a frame (each pass scanning the whole conversation and reading each
/// background job's state from disk); now the entries are rebuilt here, a
/// moment after something they're read from publishes, and the view only
/// draws them.
///
/// The model also owns the process scan's clock: every 4 seconds while the
/// panel shows and Octet is in front, less often while the panel is hidden
/// (a new subagent still opens it) or nothing has run for a minute, and not
/// at all while Octet is behind other apps.
@MainActor
final class RuntimeModel: ObservableObject {
    /// What the panel is showing: the workspace in front, and its tab.
    struct Scope: Equatable {
        enum Mode: String { case workspace, tab }
        var workspaceId: String?
        var tabId: String?
        var focusedPaneId: String?
        var mode: Mode = .workspace
    }

    /// One group per root agent, in the order they're drawn.
    @Published private(set) var groups: [RuntimeGroup] = []
    /// Account background agents that only share a folder with this
    /// workspace: kept apart, since ownership is a guess.
    @Published private(set) var folder: [RuntimeEntry] = []
    /// Everything listed, for auto-reveal and the panel's bookkeeping.
    var entries: [RuntimeEntry] { groups.flatMap(\.entries) + folder }

    let store: SessionStore
    private(set) var scope = Scope()
    private var subscriptions: Set<AnyCancellable> = []
    private var rebuildWork: DispatchWorkItem?
    private var timer: Timer?
    private var interval: TimeInterval = 0
    /// Between start() and stop(): a model whose panel is gone builds nothing.
    private var started = false
    private var panelVisible = true
    private var appActive = NSApp?.isActive ?? true
    /// When something last ran, for backing the scan off once all is quiet.
    private var lastLive = Date()
    private let jobs = BackgroundJobCache()

    static let debounce: TimeInterval = 0.1
    static let liveInterval: TimeInterval = 4
    static let quietInterval: TimeInterval = 10
    static let hiddenInterval: TimeInterval = 12

    init(store: SessionStore) {
        self.store = store
        let rebuild: (Any) -> Void = { [weak self] _ in self?.scheduleRebuild() }
        store.$snapshot.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        store.$paneProcesses.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        store.$terminalRuntimes.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        store.$nativeRuntimeProcesses.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        store.$spawnedRuntimeAgents.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        store.paneScanEnded.sink(receiveValue: rebuild).store(in: &subscriptions)
        // AgentCenter passes on its conversations' changes.
        AgentCenter.shared.objectWillChange.sink(receiveValue: rebuild).store(in: &subscriptions)
        AgentsStore.shared.$agents.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        AgentsStore.shared.$lastLines.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        CodexAgentsStore.shared.$agents.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        CodexAgentsStore.shared.$previews.map { _ in () }.sink(receiveValue: rebuild).store(in: &subscriptions)
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setAppActive(true) }.store(in: &subscriptions)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.setAppActive(false) }.store(in: &subscriptions)
    }

    // MARK: - Scope and clock

    /// The panel moved to another workspace or tab: rebuild at once.
    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        rebuildNow()
        reload()
    }

    /// The panel appeared or went away (it can be mounted while hidden).
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        retime()
        if visible { reload() }
    }

    func start() {
        started = true
        rebuildNow()
        reload()
        retime()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        interval = 0
        rebuildWork?.cancel()
        rebuildWork = nil
    }

    private func setAppActive(_ active: Bool) {
        appActive = active
        retime()
        if active { reload() }
    }

    /// How often to scan now, or nil for not at all.
    private var wantedInterval: TimeInterval? {
        guard appActive else { return nil }
        guard panelVisible else { return Self.hiddenInterval }
        return Date().timeIntervalSince(lastLive) > 60 ? Self.quietInterval : Self.liveInterval
    }

    private func retime() {
        let wanted = started ? wantedInterval ?? 0 : 0
        guard wanted != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = wanted
        guard wanted > 0 else { return }
        let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Scans the processes behind the panel. Only the workspace in front,
    /// unless the hub or the Notch is showing agents from everywhere.
    func reload() {
        var roots: [String: Int] = [:]
        for session in center.sessions where session.conversation.isRunning {
            if let pid = session.runtimePID { roots[session.id] = pid }
        }
        let everywhere = NotchController.shared.isShowing || WindowRegistry.shared.windows.contains {
            center.board(in: $0.focusedWorkspace?.workspaceId) != nil
        }
        store.refreshPaneProcesses(in: workspaceId, nativeRoots: roots, allPanes: everywhere)
    }

    // MARK: - Building

    private func scheduleRebuild() {
        guard started, rebuildWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildWork = nil
            self.rebuildNow()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    func rebuildNow() {
        rebuildWork?.cancel()
        rebuildWork = nil
        let next = build()
        let all = next.groups.flatMap(\.entries) + next.folder
        // Shells sit there for ever; only agents and their work count as live.
        if all.contains(where: { $0.kind != .shell && ($0.liveSince != nil || $0.state.bucket != .done) }) { lastLive = Date() }
        if next.groups != groups { groups = next.groups }
        if next.folder != folder { folder = next.folder }
        retime()
    }

    // MARK: - Sources

    private var center: AgentCenter { .shared }
    private var claudeAgents: AgentsStore { .shared }
    private var codexAgents: CodexAgentsStore { .shared }
    var workspaceId: String? { scope.workspaceId }
    var activeSession: AgentSession? { center.active(in: workspaceId) }

    /// The workspace's root agents, each with what it started, and the
    /// account-wide background agents that only share the folder.
    private func build() -> (groups: [RuntimeGroup], folder: [RuntimeEntry]) {
        #if DEBUG
        // Verification and demos: "planes:overview:sample" shows made-up work.
        if RuntimePanel.debugSample {
            let entries = RuntimePanel.sampleEntries.map { entry -> RuntimeEntry in
                var entry = entry; entry.rootID = "sample"; return entry
            }
            return ([RuntimeGroup(id: "sample", title: "Fix the upload retry", agentID: "claude", rootState: .working,
                                  state: AgentState.rollUp([.working] + entries.map(\.state)), paneId: nil, sessionId: nil,
                                  tabId: scope.tabId, contextFraction: 0.62, entries: entries, recency: nil,
                                  focused: true, loading: false)], [])
        }
        #endif
        guard let workspaceId else { return ([], []) }
        let snapshot = store.snapshot
        let sessions = center.sessions(in: workspaceId)
        let active = activeSession
        var groups: [RuntimeGroup] = []
        var directories = Set<String>()

        for session in sessions {
            let entries = sessionEntries(session).map { entry -> RuntimeEntry in
                var entry = entry; entry.rootID = "chat:" + session.id; return entry
            }
            let root = session.agentState
            let used = session.conversation.contextUsed ?? 0
            let window = session.conversation.contextWindow ?? 0
            directories.insert(Self.canonicalDirectory(session.cwd))
            groups.append(RuntimeGroup(
                id: "chat:" + session.id, title: session.title, agentID: session.engine.agent, rootState: root,
                state: AgentState.rollUp([root] + entries.map(\.state)), paneId: nil, sessionId: session.id, tabId: nil,
                contextFraction: window > 0 && used > 0 ? min(1, Double(used) / Double(window)) : nil,
                entries: entries, recency: session.conversation.items.last?.createdAt,
                focused: active?.id == session.id,
                loading: session.conversation.isRunning && session.runtimePID != nil
                    && store.nativeRuntimeProcesses[session.id] == nil && store.loadingPaneProcesses))
        }

        // Terminal roots: each pane running an agent of its own (a subagent's
        // viewer tab belongs under the agent that launched it). A pane whose
        // agent hasn't been recognised yet still gets a group if it runs
        // something, so new work never goes missing.
        let agents = snapshot.agents(inWorkspace: workspaceId)
        let viewers = Set(agents.filter(\.isSubagentViewer).map(\.paneId))
        let focusedPane = active == nil ? scope.focusedPaneId : nil
        for pane in snapshot.panes where pane.workspaceId == workspaceId && !viewers.contains(pane.paneId) {
            let agent = agents.first { $0.paneId == pane.paneId }
            let entries = paneEntries([pane]).map { entry -> RuntimeEntry in
                var entry = entry; entry.rootID = "pane:" + pane.paneId; return entry
            }
            guard agent != nil || entries.contains(where: { $0.kind != .shell }) else { continue }
            directories.formUnion(pane.searchCwds.map(Self.canonicalDirectory))
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let title = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? agent?.name ?? "Terminal"
            let root = agent.map { AgentState($0.agentStatus) } ?? .working
            let usage = store.usageTracker.usage(forTerminal: agent?.terminalId)
            groups.append(RuntimeGroup(
                id: "pane:" + pane.paneId, title: title, agentID: agent?.agent, rootState: root,
                state: AgentState.rollUp([root] + entries.map(\.state)), paneId: pane.paneId, sessionId: nil,
                tabId: pane.tabId, contextFraction: usage?.contextFraction, entries: entries, recency: nil,
                focused: focusedPane == pane.paneId || (focusedPane == nil && active == nil && pane.tabId == scope.tabId && pane.focused),
                loading: entries.isEmpty && store.loadingPaneProcesses && !store.scannedRuntimePaneIDs.contains(pane.paneId)))
        }
        if scope.mode == .tab {
            groups = groups.filter { group in
                active.map { group.sessionId == $0.id } ?? (group.tabId != nil && group.tabId == scope.tabId)
            }
        }
        let order = RuntimeGrouping.order(groups.map { .init(id: $0.id, focused: $0.focused, state: $0.state, recency: $0.recency) })
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (order.compactMap { byID[$0] }, backgroundTasks(in: directories))
    }

    /// What panes' agents started: shells, model CLIs in the process tree,
    /// what a Claude Code log says runs, and subagents in tabs of their own.
    private func paneEntries(_ panes: [EnginePane]) -> [RuntimeEntry] {
        let snapshot = store.snapshot
        var result: [RuntimeEntry] = []

        for pane in panes {
            guard let info = store.paneProcesses[pane.paneId] else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let location = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal"
            var shownShells = Set<String>()
            for process in info.background where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                guard shownShells.insert(title.lowercased()).inserted else { continue }
                result.append(RuntimeEntry(id: "\(pane.paneId)-\(process.pid)", kind: .shell,
                                           title: title, detail: "Active",
                                           location: location, command: process.name,
                                           prompt: nil, output: nil, process: title,
                                           depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                           paneId: pane.paneId))
            }
            let spawned = store.spawnedRuntimeAgents.filter { $0.paneId == pane.paneId }
            result += processAgents(spawned, location: location, sessionId: nil)
            // Claude Code in the terminal: its log says what it has running.
            // Its subagents' own subagents, and what they run, sit under them.
            result += HandoffRuntime.nested(store.terminalRuntimes[pane.paneId] ?? []).map { node in
                entry(node.runtime, location: location, paneId: pane.paneId, session: nil, depth: node.depth)
            }
        }
        // Subagents the Subagent Tabs hook opened as tabs of their own,
        // launched from this tab's panes (or by those subagents).
        let launchers = Set(panes.map(\.paneId))
        if !launchers.isEmpty {
            for viewer in snapshot.subagentViewers(launchedFrom: launchers) {
                let title = viewer.tab.map { TabAutoName.display(label: $0.label, number: $0.number) }
                    ?? viewer.agent.name ?? "Subagent"
                let status = viewer.agent.agentStatus
                result.append(RuntimeEntry(id: "subagent-tab-\(viewer.agent.paneId)", kind: .agent,
                                           title: title,
                                           detail: status == .unknown ? "Running" : stateLabel(status).capitalized,
                                           location: "Its own tab", command: nil,
                                           prompt: nil, output: nil,
                                           process: status == .done ? "Finished" : "Working in its tab",
                                           depth: viewer.depth, accentSeed: Self.seed(viewer.agent.paneId),
                                           agentID: viewer.agent.agent ?? "claude", modelName: nil,
                                           paneId: viewer.agent.paneId, autoReveal: true,
                                           parentID: viewer.agent.parentPaneId.map { "subagent-tab-" + $0 },
                                           state: RuntimeStates.subagentTab(status)))
            }
        }

        return result
    }

    /// What a conversation started: work carried over from its terminal,
    /// monitors, background tasks, subagents, shells and model CLIs.
    private func sessionEntries(_ session: AgentSession) -> [RuntimeEntry] {
        var result: [RuntimeEntry] = []
        result += carriedRuntimes(in: session)
        result += activeMonitors(in: session)
        result += activeBackgroundTasks(in: session)
        result += activeSubagents(in: session)
        var shownShells = Set<String>()
        for process in store.nativeRuntimeProcesses[session.id] ?? [] where Self.isShell(process.name) {
            let title = Self.commandName(process.name)
            guard shownShells.insert(title.lowercased()).inserted else { continue }
            result.append(RuntimeEntry(id: "\(session.id)-\(process.pid)", kind: .shell,
                                       title: title, detail: "Active",
                                       location: session.title, command: process.name,
                                       prompt: nil, output: nil, process: title,
                                       depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                       paneId: nil, sessionId: session.id, autoReveal: true))
        }
        let processes = store.nativeRuntimeProcesses[session.id] ?? []
        let spawned = processes.compactMap { process -> SpawnedRuntimeAgent? in
            guard let agent = Self.agentExecutable(process.name) else { return nil }
            return SpawnedRuntimeAgent(pid: process.pid, parentPid: process.parentPid, agent: agent,
                                       name: AgentBrand.forAgent(agent)?.displayName ?? agent,
                                       paneId: nil, tabId: nil, workspaceId: session.workspaceId, cwd: session.cwd)
        }
        result += processAgents(spawned, location: session.title, sessionId: session.id)
        return result
    }

    private static func commandName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private static func agentExecutable(_ raw: String) -> String? {
        AgentBrand.runtimeAgentID(forExecutable: raw)
    }

    private func processAgents(_ agents: [SpawnedRuntimeAgent], location: String,
                               sessionId: String?) -> [RuntimeEntry] {
        let ids = Set(agents.map(\.pid))
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.pid, $0) })
        return agents.map { agent in
            var depth = 0
            var parent = agent.parentPid
            var visited = Set<Int>()
            while ids.contains(parent), let ancestor = byId[parent], visited.insert(parent).inserted {
                depth += 1
                parent = ancestor.parentPid
            }
            return RuntimeEntry(id: "process-agent-\(agent.pid)", kind: .agent,
                                title: agent.name, detail: "Model",
                                location: location, command: agent.agent,
                                prompt: "Started by another agent", output: nil,
                                process: Self.commandName(agent.agent), depth: depth,
                                accentSeed: Self.seed(agent.agent), agentID: agent.agent, modelName: nil,
                                paneId: agent.paneId,
                                sessionId: sessionId, autoReveal: true, pid: agent.pid,
                                parentID: ids.contains(agent.parentPid) ? "process-agent-\(agent.parentPid)" : nil)
        }
    }

    private func backgroundTasks(in directories: Set<String>) -> [RuntimeEntry] {
        guard !directories.isEmpty else { return [] }
        let claude = claudeAgents.agents.filter {
            $0.kind == .background && ($0.state == .working || $0.state == .needsInput)
                && directories.contains(Self.canonicalDirectory($0.cwd))
        }.map { agent in
            let job = jobs.load(id: agent.id)
            return RuntimeEntry(id: "background-claude-\(agent.id)", kind: .agent,
                                title: agent.name,
                                detail: agent.state == .needsInput ? "Needs input" : "Background",
                                location: abbreviateHome(agent.cwd), command: nil,
                                prompt: job?.needs ?? job?.detail,
                                output: claudeAgents.lastLines[agent.sessionId],
                                process: "Background task", depth: 0,
                                accentSeed: Self.seed(agent.id), agentID: "claude", modelName: nil,
                                paneId: nil, autoReveal: false, state: AgentsHubList.status(agent))
        }
        let codex = codexAgents.agents.filter {
            ($0.state == .working || $0.state == .needsInput)
                && directories.contains(Self.canonicalDirectory($0.cwd))
        }.map { agent in
            RuntimeEntry(id: "background-codex-\(agent.id)", kind: .agent,
                         title: agent.name,
                         detail: agent.state == .needsInput ? "Needs input" : "Background",
                         location: abbreviateHome(agent.cwd), command: nil,
                         prompt: codexAgents.previews[agent.id], output: codexAgents.previews[agent.id],
                         process: "Background task", depth: 0,
                         accentSeed: Self.seed(agent.id), agentID: "codex", modelName: nil,
                         paneId: nil, autoReveal: false, state: AgentsHubList.status(agent))
        }
        return claude + codex
    }

    private static func canonicalDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Work the terminal had running when this conversation took over,
    /// until the agent has started each again (its new call takes the row).
    private func carriedRuntimes(in session: AgentSession) -> [RuntimeEntry] {
        guard !session.carriedRuntimes.isEmpty else { return [] }
        let started = session.processStartedAt ?? .distantFuture
        let restarted = session.conversation.items.compactMap { item -> String? in
            guard item.createdAt >= started, case .tool(let call) = item.kind, let input = call.inputObject else { return nil }
            return (input["command"] as? String) ?? (input["description"] as? String) ?? (input["name"] as? String)
        }
        return session.carriedRuntimes.compactMap { runtime in
            let key = runtime.command ?? runtime.title
            guard !restarted.contains(key) else { return nil }
            return entry(runtime, location: session.title, paneId: nil, session: session, carried: true)
        }
    }

    /// A row for work a Claude Code session log reports: live in a terminal
    /// pane, or carried into a conversation that is starting it again.
    private func entry(_ runtime: HandoffRuntime, location: String, paneId: String?,
                       session: AgentSession?, carried: Bool = false, depth: Int = 0) -> RuntimeEntry {
        let now = Date()
        let kind: RuntimeKind
        let detail: String
        let process: String
        switch runtime.kind {
        case .task:
            kind = .task
            detail = "Running"
            process = runtime.command?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "Background command"
        case .monitor:
            kind = .monitor
            detail = runtime.expiresAt.map { Self.remaining(until: $0, now: now) } ?? "Watching"
            process = "Watching"
        case .agent:
            kind = .agent
            detail = runtime.startedAt.map { "\(max(0, Int(now.timeIntervalSince($0))))s" } ?? "Working"
            process = "Working"
        }
        return RuntimeEntry(id: (carried ? "carried-" : "log-") + runtime.id, kind: kind, title: runtime.title,
                            detail: carried ? "Restarting" : detail, location: location, command: runtime.command,
                            prompt: runtime.kind == .agent ? runtime.prompt : runtime.title, output: nil,
                            process: carried ? "Moving from the terminal" : process, depth: depth,
                            accentSeed: Self.seed(runtime.id),
                            agentID: runtime.kind == .agent ? "claude" : nil,
                            modelName: runtime.kind == .agent ? session.map(modelName(for:)) : nil,
                            paneId: paneId, sessionId: session?.id, autoReveal: true,
                            liveSince: carried || runtime.kind == .monitor ? nil : runtime.startedAt,
                            parentID: runtime.parentId.map { (carried ? "carried-" : "log-") + $0 },
                            // Carried work waits for the conversation to start it again.
                            state: carried ? .waiting : .working)
    }

    private func activeMonitors(in session: AgentSession) -> [RuntimeEntry] {
        let now = Date()
        let started = session.processStartedAt ?? .distantFuture
        return session.conversation.items.compactMap { item in
            guard item.createdAt >= started,
                  case .tool(let call) = item.kind, call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
                  call.result?.localizedCaseInsensitiveContains("monitor started") == true,
                  let input = call.inputObject else { return nil }
            let timeout = (input["timeout_ms"] as? NSNumber)?.doubleValue ?? 120_000
            let expires = item.createdAt.addingTimeInterval(timeout / 1_000)
            guard expires > now else { return nil }
            let title = input["description"] as? String ?? call.summary
            return RuntimeEntry(id: "monitor-\(item.id)", kind: .monitor,
                                title: title.isEmpty ? "Monitor" : title,
                                detail: Self.remaining(until: expires, now: now),
                                location: session.title, command: input["command"] as? String,
                                prompt: input["description"] as? String, output: call.result,
                                process: "Watching", depth: 0, accentSeed: 0,
                                agentID: nil, modelName: nil,
                                paneId: nil, sessionId: session.id, autoReveal: true)
        }
    }

    /// Claude and compatible agents mark asynchronous shell calls in their
    /// tool input. Their shell may be re-parented immediately, so the stream
    /// is a more reliable ownership signal than the process tree alone.
    private func activeBackgroundTasks(in session: AgentSession) -> [RuntimeEntry] {
        session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind,
                  (call.name.caseInsensitiveCompare("Bash") == .orderedSame
                    || call.name.caseInsensitiveCompare("Shell") == .orderedSame),
                  let input = call.inputObject else { return nil }
            let requested = input["run_in_background"] as? Bool == true
                || input["background"] as? Bool == true
            let reported = call.result?.localizedCaseInsensitiveContains("background") == true
            guard requested || reported else { return nil }
            let command = input["command"] as? String ?? call.input
            let description = input["description"] as? String
            let executable = command.split(whereSeparator: \.isWhitespace).first
                .map { Self.commandName(String($0)) }
            let runningProcess = executable.flatMap { expected in
                (store.nativeRuntimeProcesses[session.id] ?? []).first {
                    Self.commandName($0.name).caseInsensitiveCompare(expected) == .orderedSame
                }
            }
            let hasProcess = runningProcess != nil
            // A replayed log is full of background calls from processes that
            // have since exited; only this process's own may still be running.
            let current = session.processStartedAt.map { item.createdAt >= $0 } ?? false
            guard hasProcess || (current && (call.result == nil || session.conversation.isRunning)) else { return nil }
            // Only a process that has gone can have exited.
            let exitCode = hasProcess ? nil : RuntimeStates.exitCode(in: call.result)
            return RuntimeEntry(id: "task-\(item.id)", kind: .task,
                                title: description ?? (call.summary.isEmpty ? "Background command" : call.summary),
                                detail: call.result == nil ? "Running" : "Background",
                                location: session.title, command: command,
                                prompt: description, output: call.result,
                                process: command.split(whereSeparator: \.isWhitespace).first.map(String.init),
                                depth: 0, accentSeed: Self.seed(item.id),
                                agentID: nil, modelName: nil,
                                paneId: nil, sessionId: session.id, autoReveal: true,
                                pid: runningProcess?.pid,
                                state: RuntimeStates.backgroundTask(isError: call.isError, exitCode: exitCode),
                                exitCode: exitCode, startedAt: item.createdAt)
        }
    }

    private func activeSubagents(in session: AgentSession) -> [RuntimeEntry] {
        let now = Date()
        let calls: [(item: AgentItem, call: AgentToolCall)] = session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind,
                  call.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || call.name.caseInsensitiveCompare("Task") == .orderedSame else { return nil }
            return (item, call)
        }
        let byId = Dictionary(uniqueKeysWithValues: calls.map { ($0.item.id, $0) })
        let childrenByParent = Dictionary(grouping: session.conversation.items.compactMap { item in
            item.parent.map { ($0, item) }
        }, by: \.0).mapValues { $0.map(\.1) }
        // Replayed launches without a result were cut off with an earlier
        // process, not running now.
        let started = session.processStartedAt ?? .distantFuture
        var visible = Set(calls.filter {
            $0.item.createdAt >= started && ($0.call.result != nil || session.conversation.isRunning)
        }.map { $0.item.id })
        // Keep the ownership chain visible even if an agent's launch call has
        // already returned while one of its descendants is still working.
        var frontier = Array(visible)
        while let id = frontier.popLast(), let parent = byId[id]?.item.parent,
              byId[parent] != nil, visible.insert(parent).inserted {
            frontier.append(parent)
        }

        // Each subagent with the ones it started under it, however deep.
        let shown = RuntimeTree.order(calls.filter { visible.contains($0.item.id) },
                                      id: { $0.item.id }, parent: { $0.item.parent })
        return shown.compactMap { node -> RuntimeEntry? in
            let (pair, depth) = node
            let item = pair.item
            let call = pair.call
            guard let input = call.inputObject else { return nil }
            let title = input["name"] as? String
                ?? input["description"] as? String
                ?? call.summary
            let prompt = input["prompt"] as? String
            let children = childrenByParent[item.id] ?? []
            let process = children.reversed().compactMap { child -> String? in
                guard case .tool(let childCall) = child.kind, childCall.result == nil else { return nil }
                if childCall.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || childCall.name.caseInsensitiveCompare("Task") == .orderedSame {
                    return "Managing subagent"
                }
                return childCall.summary.isEmpty ? childCall.displayName : "\(childCall.displayName)  \(childCall.summary)"
            }.first ?? (call.result == nil ? "Working" : "Finished")
            let output = children.reversed().compactMap { child -> String? in
                switch child.kind {
                case .text(let text) where !text.isEmpty: return text
                case .tool(let childCall) where childCall.result?.isEmpty == false: return childCall.result
                case .notice(let text) where !text.isEmpty: return text
                default: return nil
                }
            }.first ?? call.result
            let elapsed = max(0, Int(now.timeIntervalSince(item.createdAt)))
            return RuntimeEntry(id: "agent-\(item.id)", kind: .agent,
                                title: title.isEmpty ? "Subagent" : title,
                                detail: call.isError ? "Failed" : call.result == nil ? "\(elapsed)s" : "Finished",
                                location: session.title, command: prompt,
                                prompt: prompt, output: output, process: process,
                                depth: depth, accentSeed: Self.seed(item.id),
                                agentID: session.engine.agent, modelName: (input["model"] as? String) ?? modelName(for: session),
                                paneId: nil, sessionId: session.id, autoReveal: true,
                                liveSince: call.result == nil ? item.createdAt : nil,
                                parentID: item.parent.map { "agent-" + $0 },
                                state: RuntimeStates.subagent(isError: call.isError, hasResult: call.result != nil),
                                startedAt: item.createdAt,
                                finishedAt: call.result == nil ? nil : (children.last?.createdAt ?? item.createdAt),
                                todos: AgentTodos.latest(in: children).flatMap { TodoMeter($0.map(\.status)) })
        }
    }

    private func modelName(for session: AgentSession) -> String {
        switch session.engine {
        case .claude:
            return AgentSession.model(session.model)?.title ?? friendlyModelName(session.model)
        case .codex:
            return CodexCatalogStore.shared.model(session.model)?.displayName ?? friendlyModelName(session.model)
        case .pi:
            return session.piModels.first(where: { $0.id == session.model || $0.modelId == session.model })?.name
                ?? friendlyModelName(session.model)
        case .opencode:
            return session.openCodeModel?.name ?? friendlyModelName(session.model)
        case .qwen:
            return friendlyModelName(session.model)
        }
    }

    private func friendlyModelName(_ raw: String) -> String {
        TwinStyle.shortModel(raw).replacingOccurrences(of: "-", with: " ")
    }

    private static func seed(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 5 }
    }

    private static func isShell(_ raw: String) -> Bool {
        let command = commandName(raw).lowercased()
        return ShellPrompt.shells.contains(command) || ShellPrompt.shells.contains("-" + command)
    }

    private static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

/// A root agent in the workspace (a terminal agent or a conversation) and
/// everything it started, as one of the Agents tab's groups.
struct RuntimeGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let agentID: String?
    /// The root's own state.
    let rootState: AgentState
    /// The loudest of the root and everything under it.
    let state: AgentState
    let paneId: String?
    let sessionId: String?
    let tabId: String?
    let contextFraction: Double?
    let entries: [RuntimeEntry]
    let recency: Date?
    /// The one in front: the active conversation, or the focused pane.
    let focused: Bool
    /// Its first scan hasn't landed yet.
    let loading: Bool

    var summary: String {
        RuntimeGrouping.summary(subagents: entries.filter { $0.kind == .agent }.count,
                                tasks: entries.filter { $0.kind == .task }.count,
                                monitors: entries.filter { $0.kind == .monitor }.count)
    }
}
