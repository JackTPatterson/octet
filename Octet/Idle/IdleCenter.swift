import AppKit
import Combine
import Foundation

/// The Idle dock's work: what each idle workspace still holds (read now and
/// then, off the main thread), closing them without losing anything unsaid,
/// and sleep, which closes a workspace's terminals and keeps a note to
/// bring it back as it was. Idle workspaces sleep by themselves after
/// Settings › General › Sleep idle workspaces after, when nothing would be
/// lost: no agent working or asking, nothing running, no server listening.
@MainActor
final class IdleCenter: ObservableObject {
    static let shared = IdleCenter()

    /// What each idle workspace holds, by id.
    @Published private(set) var work: [String: IdleWork] = [:]
    @Published private(set) var sleeping: [SleepingWorkspace] = []
    /// Idle rows picked with ⌘-click, to close or sleep together.
    @Published var selection: Set<String> = []

    private weak var store: SessionStore?
    private var timer: Timer?
    private var sleepTimer: Timer?
    private var reading = false
    private var loaded = false
    /// Workspaces being put to sleep, left alone meanwhile.
    private var sleepingNow: Set<String> = []
    /// Sleeping workspaces being woken, so a second click doesn't open them twice.
    private var wakingNow: Set<String> = []
    /// Idle docks on screen with a shelf open: only then is what idle
    /// workspaces hold worth reading every few minutes.
    private var openDocks: Set<UUID> = []
    /// Sleeps waiting for a fresh look at what panes run, by request.
    private var scanWaits: [UUID: AnyCancellable] = [:]
    private var activeObserver: NSObjectProtocol?

    private var url: URL { EngineSession.supportDirectory.appendingPathComponent("sleeping-workspaces.json") }

    func start(store: SessionStore) {
        self.store = store
        if !loaded {
            loaded = true
            sleeping = SleepingWorkspacesFile.load(from: url).workspaces
        }
        // Reading runs git in every idle workspace, so only while someone
        // can see it; deciding what's due to sleep is cheap and always runs.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            MainActor.assumeIsolated { IdleCenter.shared.refreshIfShown() }
        }
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            MainActor.assumeIsolated { IdleCenter.shared.sleepWhatsDue() }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { IdleCenter.shared.refreshIfShown() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.refreshIfShown()
            self?.sleepWhatsDue()
        }
    }

    /// An Idle dock appeared, opened or folded a shelf, or went away. One
    /// newly open reads at once.
    func dock(_ token: UUID, open: Bool) {
        if open {
            if openDocks.insert(token).inserted { refreshIfShown() }
        } else {
            openDocks.remove(token)
        }
    }

    private func refreshIfShown() {
        guard NSApp?.isActive == true, !openDocks.isEmpty else { return }
        refresh()
    }

    private func save() {
        SleepingWorkspacesFile(workspaces: sleeping).save(to: url)
    }

    // MARK: - What they hold

    /// Reads `ids` (every idle workspace by default) again.
    func refresh(_ ids: [String]? = nil, then: (@MainActor () -> Void)? = nil) {
        guard let store else { return }
        let snapshot = store.snapshot
        let targets = (ids ?? store.idleWorkspaces.map(\.workspaceId)).compactMap { id -> (String, String, [Int], Bool)? in
            guard let workspace = snapshot.workspaces.first(where: { $0.workspaceId == id }),
                  let directory = snapshot.directory(ofWorkspace: id) else { return nil }
            return (id, directory, PortsWatcher.shared.ports(inWorkspace: id, snapshot: snapshot), workspace.worktree != nil)
        }
        guard ids != nil || !reading else { return }
        if ids == nil { reading = true }
        let full = ids == nil
        DispatchQueue.global(qos: .utility).async {
            var found: [String: IdleWork] = [:]
            for (id, directory, ports, isWorktree) in targets {
                found[id] = IdleWork.read(directory: directory, ports: ports, isWorktree: isWorktree)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = IdleCenter.shared
                    if full {
                        center.reading = false
                        let idle = Set(center.store?.idleWorkspaces.map(\.workspaceId) ?? [])
                        center.work = center.work.filter { idle.contains($0.key) }.merging(found) { _, new in new }
                    } else {
                        center.work.merge(found) { _, new in new }
                    }
                    then?()
                }
            }
        }
    }

    // MARK: - Closing

    /// Closes idle workspaces, saying first which hold work that isn't
    /// saved anywhere else or have an agent still at it, and offering to
    /// close only the others. One with nothing to lose closes at once, as
    /// a row's × should; several are still asked about.
    func close(_ workspaces: [EngineWorkspace]) {
        guard let store, !workspaces.isEmpty else { return }
        let ids = workspaces.map(\.workspaceId)
        refresh(ids) { [weak self] in
            guard let self else { return }
            let risky = workspaces.filter { self.risks(of: $0, in: store.snapshot) != nil }
            let clean = workspaces.filter { workspace in !risky.contains { $0.workspaceId == workspace.workspaceId } }
            let noun = workspaces.count == 1 ? "idle workspace" : "idle workspaces"
            if risky.isEmpty, workspaces.count == 1 {
                store.closeWorkspaces(workspaces)
                self.selection.subtract(ids)
                return
            }
            guard !risky.isEmpty else {
                return ConfirmCenter.shared.ask(
                    title: "Close \(Recap.count(workspaces.count, "idle workspace"))?",
                    message: "Their terminals and anything running in them end. Nothing in them is left unsaved.",
                    items: workspaces.map(\.label), confirmTitle: "Close", destructive: true
                ) { _ in store.closeWorkspaces(workspaces); self.selection.subtract(ids) }
            }
            var request = ConfirmCenter.Request(
                title: risky.count == workspaces.count && workspaces.count == 1
                    ? "Close \(risky[0].label)? It's still doing something"
                    : "\(risky.count) of \(workspaces.count) \(noun) are still doing something",
                message: "Files stay on disk, but uncommitted and unpushed work is only in these folders, and agents and servers stop.",
                items: risky.map { "\($0.label) — \(self.risks(of: $0, in: store.snapshot) ?? "")" },
                confirmTitle: workspaces.count == 1 ? "Close Anyway" : "Close All",
                destructive: true,
                onConfirm: { _ in store.closeWorkspaces(workspaces); self.selection.subtract(ids) })
            if !clean.isEmpty {
                request.alternateTitle = "Close the \(clean.count) Clean"
                request.onAlternate = { store.closeWorkspaces(clean); self.selection.subtract(clean.map(\.workspaceId)) }
            }
            ConfirmCenter.shared.ask(request)
        }
    }

    /// What closing would end, or nil when nothing: an agent still working
    /// or asking (a workspace moved to Idle by hand can be busy), then work
    /// only in its folder and servers.
    private func risks(of workspace: EngineWorkspace, in snapshot: EngineSnapshot) -> String? {
        let id = workspace.workspaceId
        let agents = snapshot.agents(inWorkspace: id)
        // Octet's own conversations end with the workspace too.
        let conversations = AgentCenter.shared.idleActivity
        var parts: [String] = []
        if agents.contains(where: { $0.agentStatus == .working }) || workspace.agentStatus == .working
            || conversations.working.contains(id) {
            parts.append("an agent is working")
        } else if agents.contains(where: { $0.agentStatus == .blocked }) || workspace.agentStatus == .blocked
            || conversations.blocked.contains(id) {
            parts.append("an agent is waiting on you")
        }
        if let held = work[workspace.workspaceId]?.risks { parts.append(held) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: - Sleep

    /// Puts workspaces to sleep. By hand, one that would end something asks
    /// first; on its own (`automatic`) it's skipped instead.
    func sleep(_ workspaces: [EngineWorkspace], automatic: Bool = false) {
        guard let store else { return }
        let targets = workspaces.filter { !sleepingNow.contains($0.workspaceId) }
        guard !targets.isEmpty else { return }
        let snapshot = store.snapshot
        let client = store.client
        let ids = targets.map(\.workspaceId)
        let panes = snapshot.panes.filter { ids.contains($0.workspaceId) }.map(\.paneId)
        sleepingNow.formUnion(ids)
        refresh(ids)
        DispatchQueue.global(qos: .userInitiated).async {
            let busy = Set(panes.filter { pane in
                (try? client.call("pane.process_info", ["pane_id": pane])).flatMap(ShellRecovery.job(in:)) != nil
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    IdleCenter.shared.afterPaneScan { IdleCenter.shared.sleep(targets, busy: busy, automatic: automatic) }
                }
            }
        }
    }

    /// Runs `then` once every pane's processes and agents' session logs
    /// have been read again, so what an agent left running behind it is
    /// known; or after a few seconds, if no scan comes back.
    private func afterPaneScan(_ then: @escaping @MainActor () -> Void) {
        guard let store else { return }
        let token = UUID()
        let finish: @MainActor () -> Void = {
            guard IdleCenter.shared.scanWaits.removeValue(forKey: token) != nil else { return }
            then()
        }
        scanWaits[token] = store.paneScanEnded.first().sink { _ in MainActor.assumeIsolated { finish() } }
        // The same conversations the runtime panel passes, so this scan
        // doesn't drop what it shows of them.
        var roots: [String: Int] = [:]
        for session in AgentCenter.shared.sessions where session.conversation.isRunning {
            if let pid = session.runtimePID { roots[session.id] = pid }
        }
        store.refreshPaneProcesses(in: nil, nativeRoots: roots)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish() } }
    }

    /// Agent panes with something running behind the agent: a background
    /// command, monitor or subagent its session log lists, or a shell or
    /// model CLI it started. (Its MCP servers, also children, don't count.)
    private func agentJobs(in panes: [String]) -> Set<String> {
        guard let store else { return [] }
        return Set(panes.filter { pane in
            if store.terminalRuntimes[pane]?.isEmpty == false { return true }
            if store.spawnedRuntimeAgents.contains(where: { $0.paneId == pane }) { return true }
            return store.paneProcesses[pane]?.background.contains { process in
                let name = (process.name as NSString).lastPathComponent.lowercased()
                return ShellPrompt.shells.contains(name) || ShellPrompt.shells.contains("-" + name)
            } == true
        })
    }

    /// The agents Octet has journaled in a workspace, with their session ids, by terminal.
    private func journal(in workspaceId: String, snapshot: EngineSnapshot) -> [String: AgentSessionRecord] {
        guard let store else { return [:] }
        return Dictionary(snapshot.agents(inWorkspace: workspaceId).compactMap { agent -> (String, AgentSessionRecord)? in
            guard let terminal = agent.terminalId, let record = store.recovery.record(forTerminal: terminal) else { return nil }
            return (terminal, record)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func sleep(_ workspaces: [EngineWorkspace], busy: Set<String>, automatic: Bool) {
        guard let store else { return }
        let snapshot = store.snapshot
        let shown = WindowRegistry.shared.shownWorkspaceIds()
        let conversations = AgentCenter.shared.idleActivity
        var ready: [EngineWorkspace] = []
        var held: [(EngineWorkspace, String)] = []
        for workspace in workspaces {
            let id = workspace.workspaceId
            let panes = snapshot.panes.filter { $0.workspaceId == id }.map(\.paneId)
            let reason = WorkspaceSleep.reasonToStayAwake(
                workspace, snapshot: snapshot, busyPanes: busy, agentJobs: agentJobs(in: panes),
                records: journal(in: id, snapshot: snapshot), conversations: conversations,
                ports: PortsWatcher.shared.ports(inWorkspace: id, snapshot: snapshot),
                pinned: automatic && store.isPinned(id), shown: automatic && shown.contains(id))
            if let reason { held.append((workspace, reason)) } else { ready.append(workspace) }
        }
        sleepingNow.subtract(workspaces.map(\.workspaceId))
        if !ready.isEmpty { putToSleep(ready, quietly: automatic) }
        guard !automatic, !held.isEmpty else { return }
        ConfirmCenter.shared.ask(
            title: held.count == 1 ? "Sleep \(held[0].0.label) anyway?" : "Sleep \(held.count) workspaces anyway?",
            message: "Sleeping closes their terminals, so this ends what's running. Agents that can be resumed are, when they wake.",
            items: held.map { "\($0.0.label) — \($0.1)" }, confirmTitle: "Sleep", destructive: true
        ) { _ in self.putToSleep(held.map(\.0), quietly: false) }
    }

    private func putToSleep(_ workspaces: [EngineWorkspace], quietly: Bool) {
        guard let store else { return }
        let snapshot = store.snapshot
        let days = SettingsStore.shared.values.sleepIdleAfterDays
        var records: [SleepingWorkspace] = []
        for workspace in workspaces {
            let id = workspace.workspaceId
            let journal = journal(in: id, snapshot: snapshot)
            let sessions = AgentCenter.shared.sessions(in: id)
            let conversations = sessions.compactMap { session -> SleepingWorkspace.Conversation? in
                guard session.hasTurns, let sessionId = session.engine == .claude ? session.sessionId : session.threadId else { return nil }
                return .init(engine: session.engine.rawValue, sessionId: sessionId, title: session.title, cwd: session.cwd)
            }
            var record = WorkspaceSleep.capture(
                workspace, snapshot: snapshot, records: journal, conversations: conversations,
                branch: store.branches[id], project: store.projectName(of: id),
                lastActive: store.activity.lastActive(id), work: work[id])
            record.cause = quietly ? .automatic(afterDays: days) : .manual
            records.append(record)
            for session in sessions { AgentCenter.shared.close(session) }
            WaitCenter.shared.cancelSnooze(of: id)
        }
        sleeping.insert(contentsOf: records, at: 0)
        save()
        store.closeWorkspaces(workspaces, quietly: true)
        selection.subtract(workspaces.map(\.workspaceId))
        let title = workspaces.count == 1 ? "\(workspaces[0].label) is asleep" : "\(workspaces.count) workspaces are asleep"
        let detail = quietly ? "Unused for \(days) days. Wake them from Idle." : "Wake from Idle to bring it back as it was."
        if let first = records.first, records.count == 1 {
            ToastCenter.shared.info(title, detail: detail, after: 8, action: .init(title: "Wake") { IdleCenter.shared.wake(first.id) })
        } else {
            ToastCenter.shared.info(title, detail: detail, after: 8)
        }
    }

    /// Opens a sleeping workspace again: a workspace on its folder, each tab
    /// again (agents resumed in theirs), and its conversations. The note is
    /// kept until it's done; tabs that don't come back stay asleep in it.
    func wake(_ id: String, in window: WindowContext? = nil) {
        guard let store, let record = sleeping.first(where: { $0.id == id }), wakingNow.insert(id).inserted else { return }
        let client = store.client
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let folder = FileManager.default.fileExists(atPath: record.cwd) ? record.cwd : NSHomeDirectory()
        let toast = ToastCenter.shared.progress("Waking \(record.label)…")
        DispatchQueue.global(qos: .userInitiated).async {
            var workspaceId: String?
            var failure: String?
            var missed: [SleepingWorkspace.Tab] = []
            do {
                let created = try client.call("workspace.create", ["cwd": folder, "label": record.label, "focus": false])
                workspaceId = (created["workspace"] as? [String: Any])?["workspace_id"] as? String
                let firstTab = (created["tab"] as? [String: Any])?["tab_id"] as? String
                // Tab by tab: one that fails doesn't cost the rest.
                for (index, tab) in record.tabs.enumerated() where workspaceId != nil {
                    let cwd = FileManager.default.fileExists(atPath: tab.cwd) ? tab.cwd : folder
                    do {
                        if let agent = tab.agent {
                            _ = try client.call("layout.apply", AgentRecovery.resumeRequest(
                                agent, shell: shell, workspaceId: workspaceId, tabId: index == 0 ? firstTab : nil))
                        } else if index == 0, let firstTab {
                            _ = try? client.call("tab.rename", ["tab_id": firstTab, "label": tab.label])
                        } else if let workspaceId {
                            _ = try client.call("tab.create", ["workspace_id": workspaceId, "cwd": cwd, "label": tab.label, "focus": false])
                        }
                    } catch {
                        missed.append(tab)
                        failure = failure ?? String(describing: error)
                    }
                }
            } catch {
                failure = String(describing: error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = IdleCenter.shared
                    center.wakingNow.remove(record.id)
                    // Nothing opened: the note stays as it was, to try again.
                    guard let workspaceId else {
                        return ToastCenter.shared.fail(toast, "Couldn't wake \(record.label)", detail: failure)
                    }
                    if let index = center.sleeping.firstIndex(where: { $0.id == record.id }) {
                        if missed.isEmpty {
                            center.sleeping.remove(at: index)
                        } else {
                            // Only what didn't come back; the conversations do, below.
                            center.sleeping[index].tabs = missed
                            center.sleeping[index].conversations = []
                        }
                        center.save()
                    }
                    for conversation in record.conversations {
                        guard let engine = AgentSession.Engine(rawValue: conversation.engine) else { continue }
                        AgentCenter.shared.resume(engine: engine, sessionId: conversation.sessionId, cwd: conversation.cwd,
                                                  workspaceId: workspaceId, title: conversation.title, start: false)
                    }
                    if !missed.isEmpty {
                        ToastCenter.shared.fail(toast, "Woke \(record.label), but not every tab",
                                                detail: "\(Recap.count(missed.count, "tab")) still asleep in Idle. " + (failure ?? ""))
                    } else {
                        ToastCenter.shared.succeed(toast, "\(record.label) is awake")
                    }
                    center.store?.refresh {
                        (window ?? WindowRegistry.shared.key)?.focusWorkspace(workspaceId)
                    }
                }
            }
        }
    }

    func forget(_ id: String) {
        sleeping.removeAll { $0.id == id }
        save()
    }

    /// Forgets sleeping workspaces once asked: the note is the only way
    /// back to their tabs and agents' conversations.
    func confirmForget(_ records: [SleepingWorkspace]) {
        guard !records.isEmpty else { return }
        ConfirmCenter.shared.ask(
            title: records.count == 1 ? "Forget \(records[0].label)?" : "Forget \(records.count) sleeping workspaces?",
            message: "Their files stay where they are, but their tabs and conversations won't be reopened.",
            items: records.count == 1 ? [] : records.map(\.label), confirmTitle: "Forget", destructive: true
        ) { _ in
            for record in records { IdleCenter.shared.forget(record.id) }
        }
    }

    /// Idle workspaces past Settings' sleep time, put to sleep where nothing
    /// would be lost.
    func sleepWhatsDue() {
        guard let store else { return }
        let days = SettingsStore.shared.values.sleepIdleAfterDays
        guard days > 0 else { return }
        let due = store.idleWorkspaces.filter { workspace in
            let id = workspace.workspaceId
            return WorkspaceSleep.isDue(lastActive: store.activity.lastActive(id), afterDays: days)
                && !store.isPinned(id) && WaitCenter.shared.snooze(of: id) == nil
                // Snoozed comes back by itself soon; asleep it would not.
                && store.snoozedUntil[id] == nil
                // A workspace a wait comes back to stays, so it's there.
                && !WaitCenter.shared.waits.contains { $0.origin.workspaceId == id }
        }
        if !due.isEmpty { sleep(due, automatic: true) }
    }

    // MARK: - Servers

    /// Every port idle workspaces' servers listen on.
    var idlePorts: [Int] {
        guard let store else { return [] }
        return store.idleWorkspaces.flatMap { PortsWatcher.shared.ports(inWorkspace: $0.workspaceId, snapshot: store.snapshot) }
    }

    func stopIdleServers() {
        let ports = idlePorts
        guard !ports.isEmpty else { return }
        ConfirmCenter.shared.ask(
            title: "Stop \(ports.count == 1 ? "the server" : "\(ports.count) servers") in idle workspaces?",
            message: "Each is sent a request to quit, as Stop on its port does.",
            items: ports.map { ":\($0)" + (PortsWatcher.shared.services[$0].map { " — \($0)" } ?? "") },
            confirmTitle: "Stop", destructive: true
        ) { _ in
            for port in ports { PortsWatcher.shared.stop(port: port) }
        }
    }

    // MARK: - Merged worktrees

    /// Closes an idle worktree workspace whose branch is merged, and removes
    /// the worktree (the branch and its commits stay).
    func removeMergedWorktree(_ workspace: EngineWorkspace, window: WindowContext) {
        guard let store, let directory = store.snapshot.directory(ofWorkspace: workspace.workspaceId) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let worktrees = WorktreeCleanup.list(in: directory)
            let match = worktrees.first { !$0.isMain && AccountProfiles.contains($0.path, directory) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard var match else {
                        return ToastCenter.shared.info("\(workspace.label) isn't a worktree Octet can remove")
                    }
                    guard match.removable else {
                        return ToastCenter.shared.info("\(match.branch ?? workspace.label) isn't removed",
                                                       detail: match.dirty ? "It has uncommitted changes." : "Its branch isn't merged.")
                    }
                    match.bytes = nil
                    WorktreeCleanupActions.confirm([match], directory: directory, window: window)
                }
            }
        }
    }
}

extension AgentCenter {
    /// Octet's conversations as idling and sleeping see them, by workspace.
    /// Only a turn starting or ending, or a question, counts as use: a
    /// conversation restored at launch, or its transcript loading, isn't.
    var idleActivity: ConversationActivity {
        var activity = ConversationActivity()
        for session in sessions {
            let id = session.workspaceId
            let asking = session.pendingPermission != nil || session.pendingQuestion != nil
            let running = session.conversation.isRunning
            if asking {
                activity.blocked.insert(id)
            } else if running {
                activity.working.insert(id)
            }
            guard asking || running else { continue }
            let turn = session.turnStartedAt.map { String($0.timeIntervalSince1970) } ?? ""
            activity.signatures[id, default: ""] += "\(session.id)=\(turn):\(running):\(asking)|"
        }
        return activity
    }
}
