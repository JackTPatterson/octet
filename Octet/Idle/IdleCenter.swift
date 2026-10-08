import AppKit
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
    private var reading = false
    private var loaded = false
    /// Workspaces being put to sleep, left alone meanwhile.
    private var sleepingNow: Set<String> = []

    private var url: URL { EngineSession.supportDirectory.appendingPathComponent("sleeping-workspaces.json") }

    func start(store: SessionStore) {
        self.store = store
        if !loaded {
            loaded = true
            sleeping = SleepingWorkspacesFile.load(from: url).workspaces
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            MainActor.assumeIsolated {
                IdleCenter.shared.refresh()
                IdleCenter.shared.sleepWhatsDue()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.refresh()
            self?.sleepWhatsDue()
        }
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
    /// saved anywhere else, and offering to close only the others.
    func close(_ workspaces: [EngineWorkspace]) {
        guard let store, !workspaces.isEmpty else { return }
        let ids = workspaces.map(\.workspaceId)
        refresh(ids) { [weak self] in
            guard let self else { return }
            let risky = workspaces.filter { !(self.work[$0.workspaceId]?.isClean ?? true) }
            let clean = workspaces.filter { workspace in !risky.contains { $0.workspaceId == workspace.workspaceId } }
            let noun = workspaces.count == 1 ? "idle workspace" : "idle workspaces"
            guard !risky.isEmpty else {
                return ConfirmCenter.shared.ask(
                    title: "Close \(Recap.count(workspaces.count, "idle workspace"))?",
                    message: "Their terminals and anything running in them end. Nothing in them is left unsaved.",
                    items: workspaces.map(\.label), confirmTitle: "Close", destructive: true
                ) { _ in store.closeWorkspaces(workspaces); self.selection.subtract(ids) }
            }
            var request = ConfirmCenter.Request(
                title: risky.count == workspaces.count && workspaces.count == 1
                    ? "\(risky[0].label) has work that isn't saved anywhere else"
                    : "\(risky.count) of \(workspaces.count) \(noun) hold work that isn't saved anywhere else",
                message: "Files stay on disk, but uncommitted and unpushed work is only in these folders, and running servers stop.",
                items: risky.map { "\($0.label) — \(self.work[$0.workspaceId]?.risks ?? "")" },
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
                MainActor.assumeIsolated { IdleCenter.shared.sleep(targets, busy: busy, automatic: automatic) }
            }
        }
    }

    private func sleep(_ workspaces: [EngineWorkspace], busy: Set<String>, automatic: Bool) {
        guard let store else { return }
        let snapshot = store.snapshot
        let shown = WindowRegistry.shared.shownWorkspaceIds()
        var ready: [EngineWorkspace] = []
        var held: [(EngineWorkspace, String)] = []
        for workspace in workspaces {
            let id = workspace.workspaceId
            let reason = WorkspaceSleep.reasonToStayAwake(
                workspace, snapshot: snapshot, busyPanes: busy,
                ports: PortsWatcher.shared.ports(inWorkspace: id, snapshot: snapshot),
                pinned: automatic && store.isPinned(id), shown: automatic && shown.contains(id))
            if let reason { held.append((workspace, reason)) } else { ready.append(workspace) }
        }
        sleepingNow.subtract(workspaces.map(\.workspaceId))
        if !ready.isEmpty { putToSleep(ready, quietly: automatic) }
        guard !automatic, !held.isEmpty else { return }
        ConfirmCenter.shared.ask(
            title: held.count == 1 ? "Sleep \(held[0].0.label) anyway?" : "Sleep \(held.count) workspaces anyway?",
            message: "Sleeping closes their terminals, so this ends what's running. Agents are resumed when they wake.",
            items: held.map { "\($0.0.label) — \($0.1)" }, confirmTitle: "Sleep", destructive: true
        ) { _ in self.putToSleep(held.map(\.0), quietly: false) }
    }

    private func putToSleep(_ workspaces: [EngineWorkspace], quietly: Bool) {
        guard let store else { return }
        let snapshot = store.snapshot
        var records: [SleepingWorkspace] = []
        for workspace in workspaces {
            let id = workspace.workspaceId
            let journal = Dictionary(snapshot.agents(inWorkspace: id).compactMap { agent -> (String, AgentSessionRecord)? in
                guard let terminal = agent.terminalId, let record = store.recovery.record(forTerminal: terminal) else { return nil }
                return (terminal, record)
            }, uniquingKeysWith: { first, _ in first })
            let sessions = AgentCenter.shared.sessions(in: id)
            let conversations = sessions.compactMap { session -> SleepingWorkspace.Conversation? in
                guard session.hasTurns, let sessionId = session.engine == .claude ? session.sessionId : session.threadId else { return nil }
                return .init(engine: session.engine.rawValue, sessionId: sessionId, title: session.title, cwd: session.cwd)
            }
            records.append(WorkspaceSleep.capture(
                workspace, snapshot: snapshot, records: journal, conversations: conversations,
                branch: store.branches[id], project: store.projectName(of: id),
                lastActive: store.activity.lastActive(id), work: work[id]))
            for session in sessions { AgentCenter.shared.close(session) }
            WaitCenter.shared.cancelSnooze(of: id)
        }
        sleeping.insert(contentsOf: records, at: 0)
        save()
        store.closeWorkspaces(workspaces, quietly: true)
        selection.subtract(workspaces.map(\.workspaceId))
        let title = workspaces.count == 1 ? "\(workspaces[0].label) is asleep" : "\(workspaces.count) workspaces are asleep"
        let detail = quietly ? "Unused for \(SettingsStore.shared.values.sleepIdleAfterDays) days. Wake them from Idle." : "Wake from Idle to bring it back as it was."
        if let first = records.first, records.count == 1 {
            ToastCenter.shared.info(title, detail: detail, after: 8, action: .init(title: "Wake") { IdleCenter.shared.wake(first.id) })
        } else {
            ToastCenter.shared.info(title, detail: detail, after: 8)
        }
    }

    /// Opens a sleeping workspace again: a workspace on its folder, each tab
    /// again (agents resumed in theirs), and its conversations.
    func wake(_ id: String, in window: WindowContext? = nil) {
        guard let store, let record = sleeping.first(where: { $0.id == id }) else { return }
        sleeping.removeAll { $0.id == id }
        save()
        let client = store.client
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let folder = FileManager.default.fileExists(atPath: record.cwd) ? record.cwd : NSHomeDirectory()
        let toast = ToastCenter.shared.progress("Waking \(record.label)…")
        DispatchQueue.global(qos: .userInitiated).async {
            var workspaceId: String?
            var failure: String?
            do {
                let created = try client.call("workspace.create", ["cwd": folder, "label": record.label, "focus": false])
                workspaceId = (created["workspace"] as? [String: Any])?["workspace_id"] as? String
                let firstTab = (created["tab"] as? [String: Any])?["tab_id"] as? String
                for (index, tab) in record.tabs.enumerated() {
                    let cwd = FileManager.default.fileExists(atPath: tab.cwd) ? tab.cwd : folder
                    if let agent = tab.agent {
                        _ = try client.call("layout.apply", AgentRecovery.resumeRequest(
                            agent, shell: shell, workspaceId: workspaceId, tabId: index == 0 ? firstTab : nil))
                    } else if index == 0, let firstTab {
                        _ = try? client.call("tab.rename", ["tab_id": firstTab, "label": tab.label])
                    } else if let workspaceId {
                        _ = try client.call("tab.create", ["workspace_id": workspaceId, "cwd": cwd, "label": tab.label, "focus": false])
                    }
                }
            } catch {
                failure = String(describing: error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = IdleCenter.shared
                    guard let workspaceId else {
                        center.sleeping.insert(record, at: 0)
                        center.save()
                        return ToastCenter.shared.fail(toast, "Couldn't wake \(record.label)", detail: failure)
                    }
                    for conversation in record.conversations {
                        guard let engine = AgentSession.Engine(rawValue: conversation.engine) else { continue }
                        AgentCenter.shared.resume(engine: engine, sessionId: conversation.sessionId, cwd: conversation.cwd,
                                                  workspaceId: workspaceId, title: conversation.title, start: false)
                    }
                    if let failure {
                        ToastCenter.shared.fail(toast, "Woke \(record.label), but not every tab", detail: failure)
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
