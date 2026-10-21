import AppKit
import Combine
import SwiftUI
import os

// What the Octet Notch shows, gathered from the stores Octet already keeps:
// agents (the hub's list), runtimes, waits and check-ins, usage and recent
// folders. Nothing here is invented: a page with nothing to say says so.

struct NotchRuntimeRow: Equatable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let since: Date?
}

struct NotchWaitRow: Equatable, Identifiable {
    let id: String
    let title: String
    /// What happens next, clipped to a line.
    let next: String
    let readyAt: Date?
}

struct NotchCheckInRow: Equatable, Identifiable {
    let id: String
    let title: String
    let due: Bool
    let nextAt: Date
    let canSkip: Bool
    /// "Every day at 9:00 AM", when it recurs.
    let schedule: String
}

struct NotchUsageRow: Equatable, Identifiable {
    // The timestamp isn't displayed; a background refresh alone must not
    // invalidate an otherwise identical island.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.name == rhs.name && lhs.plan == rhs.plan
            && lhs.note == rhs.note && lhs.windows == rhs.windows
    }

    struct Window: Equatable {
        let name: String
        let title: String
        let used: Double
        let resetsAt: Date?
    }
    let agent: String
    let name: String
    let plan: String?
    /// "API" for pay-as-you-go keys, "Signed out", or nil when it has windows.
    let note: String?
    let windows: [Window]
    let updatedAt: Date?
    var id: String { agent }
}

struct NotchFolder: Equatable, Identifiable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct NotchSnapshot: Equatable {
    var agents: [NotchAgentRow] = []
    var runtimes: [NotchRuntimeRow] = []
    var readyWaits: [NotchWaitRow] = []
    var waitingCount = 0
    var checkIns: [NotchCheckInRow] = []
    var usage: [NotchUsageRow] = []
    var folders: [NotchFolder] = []
    var focus: NotchAgentRow?

    var activity: NotchActivity {
        let counts = NotchAgentOrdering.activity(of: agents)
        let tightest = usage.compactMap { row -> (agent: String, used: Double)? in
            row.windows.map(\.used).max().map { (row.name, $0) }
        }
        return NotchActivity(working: counts.working, needsYou: counts.needsYou,
                             ready: readyWaits.count + checkIns.filter(\.due).count,
                             usage: NotchUsageWarning.worst(tightest))
    }
}

/// The notch's data, shared by every display's island. Rebuilt a moment
/// after anything it reads changes, and only while the notch is on.
@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    @Published private(set) var snapshot = NotchSnapshot()
    /// Made-up data for the debug hooks: nothing live is read or acted on.
    private(set) var isSample = false

    /// The hub entries behind the agent rows, and the store each came from,
    /// so a click can go where the agent runs.
    private var hub: [String: HubAgent] = [:]
    private var owners: [String: SessionStore] = [:]
    /// When each agent was first seen in its present state, for rows whose
    /// source doesn't say.
    private var statusSince: [String: (status: NotchAgentRow.Status, at: Date)] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var storeSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var focusSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var invalidation = NotchInvalidation()
    private var refreshWork: DispatchWorkItem?
    private var folderTask: Task<Void, Never>?
    private var foldersLoadedAt: Date?
    private var running = false

    // MARK: Lifecycle

    func start() {
        guard !running, !isSample else { return }
        running = true
        // AgentCenter forwards conversation changes; project everything else onto
        // only fields the island reads, not store loading flags, drafts or history.
        AgentCenter.shared.objectWillChange.sink { [weak self] in self?.invalidate(.agents) }.store(in: &subscriptions)
        observe(AgentsStore.shared.$agents.removeDuplicates(), section: .agents)
        observe(AgentsStore.shared.$lastLines.removeDuplicates(), section: .agents)
        observe(CodexAgentsStore.shared.$agents.removeDuplicates(), section: .agents)
        observe(CodexAgentsStore.shared.$previews.removeDuplicates(), section: .agents)
        observe(WaitCenter.shared.$waits.removeDuplicates(), section: .work)
        observe(AccountStore.shared.$accounts.removeDuplicates(), section: .usage)
        observe(AgentDiscoveryStore.shared.$agents.removeDuplicates(), section: .usage)
        WindowRegistry.shared.$windows
            .sink { [weak self] windows in self?.watch(windows) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .filter { !($0.object is NotchPanel) }
            .sink { [weak self] _ in self?.invalidate(.agents) }
            .store(in: &subscriptions)
        refresh()
    }

    func stop() {
        running = false
        refreshWork?.cancel()
        refreshWork = nil
        _ = invalidation.drain()
        folderTask?.cancel()
        folderTask = nil
        subscriptions.removeAll()
        storeSubscriptions.removeAll()
        focusSubscriptions.removeAll()
        hub = [:]
        owners = [:]
        // Keep the last immutable snapshot while hidden; refresh on resume.
    }

    private func watch(_ windows: [WindowContext]) {
        let windowIDs = Set(windows.map { ObjectIdentifier($0) })
        focusSubscriptions = focusSubscriptions.filter { windowIDs.contains($0.key) }
        for window in windows where focusSubscriptions[ObjectIdentifier(window)] == nil {
            focusSubscriptions[ObjectIdentifier(window)] = Publishers.CombineLatest(window.$workspaceId, window.$tabId)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .sink { [weak self] _ in self?.invalidate(.agents) }
        }
        let live = Set(windows.map { ObjectIdentifier($0.store) })
        storeSubscriptions = storeSubscriptions.filter { live.contains($0.key) }
        for window in windows where storeSubscriptions[ObjectIdentifier(window.store)] == nil {
            let store = window.store
            let agents = store.$snapshot.map { NotchSessionInput($0) }.removeDuplicates()
                .map { _ in NotchInvalidation.Section.agents }.eraseToAnyPublisher()
            let runtimes = store.$terminalRuntimes.removeDuplicates()
                .map { _ in NotchInvalidation.Section.work }.eraseToAnyPublisher()
            let activity = store.usageTracker.$lastActivity.removeDuplicates()
                .map { _ in NotchInvalidation.Section.agents }.eraseToAnyPublisher()
            storeSubscriptions[ObjectIdentifier(store)] = Publishers.MergeMany(agents, runtimes, activity)
                .sink { [weak self] section in self?.invalidate(section) }
        }
        invalidate(.agents)
        invalidate(.work)
    }

    private func observe<P: Publisher>(_ publisher: P, section: NotchInvalidation.Section) where P.Failure == Never {
        publisher.sink { [weak self] _ in self?.invalidate(section) }.store(in: &subscriptions)
    }

    private func invalidate(_ section: NotchInvalidation.Section) {
        guard running, invalidation.insert(section) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.refreshWork = nil
            self.refresh(sections: self.invalidation.drain())
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchInvalidation.delay, execute: work)
    }

    /// Debug sample: replaces everything with `sample` and stops reading live state.
    func installSample(_ sample: NotchSnapshot) {
        stop()
        isSample = true
        snapshot = sample
    }

    // MARK: Building

    func refresh() {
        refreshWork?.cancel()
        refreshWork = nil
        _ = invalidation.drain()
        refresh(sections: [.agents, .work, .usage])
    }

    private func refresh(sections: Set<NotchInvalidation.Section>) {
        guard running, !isSample else { return }
        #if DEBUG
        NotchMetrics.recomputes += 1
        let started = CFAbsoluteTimeGetCurrent()
        os_signpost(.begin, log: NotchMetrics.log, name: "Snapshot")
        defer {
            NotchMetrics.refreshMS += (CFAbsoluteTimeGetCurrent() - started) * 1000
            os_signpost(.end, log: NotchMetrics.log, name: "Snapshot")
        }
        #endif
        let now = Date()
        let windows = WindowRegistry.shared.windows.filter { !$0.closing }
        var next = snapshot
        if sections.contains(.agents) {
            var seen = Set<String>()
            var entries: [HubAgent] = []
            var owners: [String: SessionStore] = [:]
            for window in windows {
                for agent in AgentsHubList.agents(store: window.store) where seen.insert(agent.id).inserted {
                    entries.append(agent)
                    owners[agent.id] = window.store
                }
            }
            hub = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.owners = owners

            var rows = entries.map { row(for: $0, now: now) }
            statusSince = statusSince.filter { seen.contains($0.key) }
            rows = NotchAgentOrdering.sorted(rows)

            next.agents = rows
            let window = WindowRegistry.shared.key
            let chat = AgentCenter.shared.active(in: window?.focusedWorkspace?.workspaceId)
            let focusID = chat.map { "chat:" + $0.id } ?? window?.focusedPaneId.map { "pane:" + $0 }
            next.focus = rows.first { $0.id == focusID }
        }
        if sections.contains(.work) {
            var runtimes: [String: HandoffRuntime] = [:]
            for window in windows {
                for list in window.store.terminalRuntimes.values {
                    for runtime in list where runtimes[runtime.id] == nil { runtimes[runtime.id] = runtime }
                }
            }
            next.runtimes = runtimes.values
                .sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
                .prefix(8)
                .map { NotchRuntimeRow(id: $0.id, kind: Self.title(of: $0.kind), title: $0.title, since: $0.startedAt) }
            let waits = WaitCenter.shared
            next.readyWaits = waits.ready.prefix(4).map {
                NotchWaitRow(id: $0.id, title: $0.title, next: HandoffBrief.clip($0.next.replacingOccurrences(of: "\n", with: " "), 90),
                             readyAt: $0.readyAt)
            }
            next.waitingCount = waits.waiting.count
            next.checkIns = CheckInCenter.shared.checkIns
                .filter { $0.checkIn.map { !$0.paused && !$0.isFinished } ?? false }
                .prefix(4)
                .map { wait in
                    NotchCheckInRow(id: wait.id, title: wait.title, due: wait.checkIn?.hasReminder == true, nextAt: wait.nextCheckAt,
                                    canSkip: wait.checkIn?.recurrence != nil,
                                    schedule: wait.checkIn?.recurrence?.summary ?? "Once")
                }
        }
        if sections.contains(.usage) { next.usage = usageRows() }
        if next != snapshot {
            #if DEBUG
            NotchMetrics.publications += 1
            #endif
            snapshot = next
        }
    }

    private func row(for agent: HubAgent, now: Date) -> NotchAgentRow {
        // The island has three rows' worth of state: what needs you (a
        // failure or a plan to read too), what's moving, what has settled.
        let status: NotchAgentRow.Status = switch agent.status.bucket {
        case .needsYou: .needsInput
        case .working: .working
        case .idle, .done: .done
        }
        let known = statusSince[agent.id]
        if known?.status != status { statusSince[agent.id] = (status, now) }
        var since = statusSince[agent.id]?.at
        // A source that knows when the work began says so.
        if status == .working {
            switch agent.target {
            case .chat(let session): since = session.turnStartedAt ?? since
            case .claudeBackground, .codexBackground: since = agent.date ?? since
            case .terminal: break
            }
        }
        var canReply = false
        if case .terminal = agent.target, status == .needsInput { canReply = true }
        return NotchAgentRow(id: agent.id, vendor: agent.vendor, title: agent.title, workspace: agent.workspace ?? agent.tab,
                             detail: agent.detail, status: status, since: since,
                             canStop: agent.canStop, canReply: canReply)
    }

    private func usageRows() -> [NotchUsageRow] {
        let store = AccountStore.shared
        return AgentDiscoveryStore.shared.agents.compactMap { agent in
            guard agent.executablePath != nil else { return nil }
            let account = store.accounts[agent.id] ?? AgentAccount(agent: agent.id, kind: .unknown)
            let live = account.live
            let worth = account.kind == .apiKey || account.kind == .signedOut || !live.isEmpty || account.plan != nil
            guard worth else { return nil }
            let note: String? = switch account.kind {
            case .apiKey: "API key"
            case .signedOut: "Signed out"
            default: live.isEmpty ? (account.plan == nil ? "Ready" : nil) : nil
            }
            return NotchUsageRow(agent: agent.id, name: UsagePalette.name(agent.id), plan: account.plan, note: note,
                                 windows: live.map { .init(name: $0.name, title: $0.title, used: $0.used, resetsAt: $0.resetsAt) },
                                 updatedAt: account.updatedAt)
        }
        .sorted { UsagePalette.order($0.agent) < UsagePalette.order($1.agent) }
    }

    private static func title(of kind: HandoffRuntime.Kind) -> String {
        switch kind {
        case .task: "Task"
        case .monitor: "Monitor"
        case .agent: "Subagent"
        }
    }

    /// Recent project folders for the Actions page, read off the main thread.
    func loadFolders() {
        guard running, !isSample, folderTask == nil,
              foldersLoadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        folderTask = Task { [weak self] in
            let folders = await RecentFolders.load()
            guard let self, !Task.isCancelled, self.running else { return }
            self.folderTask = nil
            self.foldersLoadedAt = Date()
            let mapped = folders.prefix(6).map { NotchFolder(path: $0.path) }
            if mapped != self.snapshot.folders { self.snapshot.folders = mapped }
        }
    }

    #if DEBUG
    var debugSubscriptions: Int { subscriptions.count + storeSubscriptions.count + focusSubscriptions.count }
    var debugPendingWork: Int { (refreshWork == nil ? 0 : 1) + (folderTask == nil ? 0 : 1) }
    #endif

    // MARK: Lookups for actions

    func hubAgent(_ id: String) -> HubAgent? { hub[id] }
    func store(for id: String) -> SessionStore? { owners[id] }
}

/// Ignore layout, scroll, connection and process-poll changes.
private struct NotchSessionInput: Equatable {
    let agents: [EngineAgent]
    let tabs: [EngineTab]
    let workspaces: [EngineWorkspace]
    let focusedPaneID: String?
    let focusedWorkspaceID: String?
    init(_ snapshot: EngineSnapshot) {
        focusedPaneID = snapshot.focusedPaneId
        focusedWorkspaceID = snapshot.focusedWorkspaceId
        agents = snapshot.agents
        tabs = snapshot.tabs
        workspaces = snapshot.workspaces
    }
}
