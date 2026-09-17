import AppKit
import Foundation
import SwiftUI

/// Live mirror of Herd's herdr session: subscribes to herdr events and
/// re-fetches `session.snapshot` (coalesced) whenever anything changes.
@MainActor
final class HerdrStore: ObservableObject {
    @Published private(set) var snapshot: HerdrSnapshot = .empty
    @Published private(set) var groups: [ProjectGroup] = []
    /// Git branch per workspace id, read from `.git/HEAD` on each snapshot.
    @Published private(set) var branches: [String: String] = [:]
    /// Plugins installed in Herd's herdr session; refreshed when the palette opens.
    @Published private(set) var plugins: [HerdrPlugin] = []

    // MARK: Idle organization
    /// Project groups holding only workspaces that are in use.
    @Published private(set) var activeGroups: [ProjectGroup] = []
    /// Workspaces unused past `idleAfter`, most recently used first.
    @Published private(set) var idleWorkspaces: [HerdrWorkspace] = []
    @Published private(set) var activity = WorkspaceActivity()
    @Published private(set) var pinnedWorkspaceIds: Set<String> = []
    @Published var idleAfter: TimeInterval = WorkspaceActivity.defaultIdleAfter {
        didSet {
            UserDefaults.standard.set(idleAfter, forKey: Self.idleAfterKey)
            repartition()
        }
    }
    // Isolated sessions (HERD_SESSION) keep their own activity state.
    private static let keySuffix = HerdrSession.name == "herd" ? "" : ".\(HerdrSession.name)"
    private static let manualNamesKey = "herd.tabs.manualNames" + keySuffix
    private static let stampsKey = "herd.activity.stamps" + keySuffix
    private static let pinnedKey = "herd.activity.pinned" + keySuffix
    private static let idleAfterKey = "herd.activity.idleAfter" + keySuffix
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
    /// True while the focused pane sits at its shell's own prompt.
    var focusedPaneAtPrompt: Bool { ShellPrompt.isAtPrompt(focusedProcess) }
    @Published private(set) var isConnected = false
    @Published var lastError: String?

    let client: HerdrClient
    let recovery: AgentRecoveryController
    /// How full each agent's context is, refreshed from its session file.
    private(set) lazy var usageTracker = AgentUsageTracker(store: self)
    /// Herd's own interface to whichever agent is focused.
    private(set) lazy var twin = TwinSession(store: self)
    private let resolver = ProjectGrouping.CachedResolver()
    private var refreshScheduled = false
    private var eventThread: Thread?
    private var pollTimer: Timer?

    init(client: HerdrClient) {
        self.client = client
        recovery = AgentRecoveryController(client: client)
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

    var focusedWorkspace: HerdrWorkspace? {
        snapshot.workspaces.first { $0.workspaceId == snapshot.focusedWorkspaceId }
            ?? snapshot.workspaces.first(where: \.focused)
    }

    var focusedWorkspaceTabs: [HerdrTab] {
        guard let id = focusedWorkspace?.workspaceId else { return [] }
        return snapshot.tabs(inWorkspace: id)
    }

    // MARK: Optimistic tab state
    // Tab clicks and closes show immediately instead of waiting for herdr's
    // round trip, so the tab bar animates the moment you act.
    @Published private(set) var pendingFocusedTabId: String?
    @Published private(set) var pendingClosedTabIds: Set<String> = []
    private var pendingFocusDeadline = Date.distantPast

    /// Tabs the tab bar shows: the focused workspace's, minus ones closing.
    var displayedTabs: [HerdrTab] {
        focusedWorkspaceTabs.filter { !pendingClosedTabIds.contains($0.tabId) }
    }

    var displayedFocusedTabId: String? {
        pendingFocusedTabId ?? snapshot.focusedTabId ?? focusedWorkspaceTabs.first(where: \.focused)?.tabId
    }

    private func settleOptimisticTabs(with snapshot: HerdrSnapshot) {
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
                        if self.isConnected { self.recovery.connectionLost() }
                        self.isConnected = false
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "herd.terminal-events"
        eventThread = thread
        thread.start()
        // Agent state changes are per-pane subscriptions in herdr; a light
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

    func refresh() {
        let client = self.client
        let inference = recovery.inferenceRequest()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try client.snapshot() }
            // Disk reads stay off the main thread.
            let snapshot = try? result.get()
            // One extra call: what the focused pane is actually running.
            let focusedPaneId = snapshot?.focusedPaneId
                ?? snapshot?.panes.first(where: \.focused)?.paneId
            let process = focusedPaneId.flatMap { paneId in
                (try? client.call("pane.process_info", ["pane_id": paneId])).flatMap(ShellPrompt.parse)
            }
            let branches = snapshot.map(Self.readBranches)
            let inferred = snapshot.flatMap { snapshot in
                inference.map { AgentSessionFiles.infer(agents: snapshot.agents, firstSeen: $0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    if process != self.focusedProcess { self.focusedProcess = process }
                    self.recovery.observe(snapshot, inferred: inferred ?? [:])
                    self.apply(snapshot, branches: branches ?? [:])
                case .failure(let error):
                    self.lastError = String(describing: error)
                }
            }
        }
    }

    func apply(_ snapshot: HerdrSnapshot, branches: [String: String]) {
        settleOptimisticTabs(with: snapshot)
        observeActivity(snapshot)
        autoNameTabs(in: snapshot)
        notifyAgentActivity(in: snapshot)
        usageTracker.refreshIfDue()
        refreshTip()
        twin.snapshotChanged()
        if branches != self.branches { self.branches = branches }
        guard snapshot != self.snapshot || groups.isEmpty else { return }
        self.snapshot = snapshot
        let groups = ProjectGrouping.groups(snapshot: snapshot, resolveRoot: resolver.root(for:))
        if groups != self.groups { self.groups = groups }
        repartition()
    }

    private nonisolated static func readBranches(_ snapshot: HerdrSnapshot) -> [String: String] {
        var branches: [String: String] = [:]
        for workspace in snapshot.workspaces {
            if let directory = snapshot.directory(ofWorkspace: workspace.workspaceId),
               let branch = GitBranch.current(in: directory) {
                branches[workspace.workspaceId] = branch
            }
        }
        return branches
    }

    // MARK: - Remote machines

    /// Machines the engine has saved, refreshed when the palette opens.
    @Published private(set) var remoteMachines: [RemoteMachine] = []

    func refreshRemoteMachines() {
        guard let herdr = HerdrSession.locateHerdr() else { return }
        PluginCLI.runShell("\(PluginCLI.quote(herdr)) machine list --json", timeout: 30) { [weak self] result in
            let machines = RemoteMachines.parse(Data(result.output.utf8))
            guard let self, machines != self.remoteMachines else { return }
            self.remoteMachines = machines
        }
    }

    /// Opens a session on a machine in a new tab of the focused workspace.
    func openRemote(_ machine: RemoteMachine) {
        guard let herdr = HerdrSession.locateHerdr() else { return }
        var params: [String: Any] = [
            "focus": true,
            "tab_label": machine.label,
            "root": [
                "type": "pane",
                "label": machine.label,
                "command": machine.command(herdrPath: herdr, session: RemoteMachines.sessionName(for: machine)),
            ] as [String: Any],
        ]
        if let workspace = focusedWorkspace { params["workspace_id"] = workspace.workspaceId }
        perform("layout.apply", params, toast: ToastText(
            progress: "Connecting to \(machine.label)…",
            success: "Opened \(machine.label)",
            failure: "Couldn't open \(machine.label)"
        ))
    }

    /// Asks the engine to prepare a machine; it does the ssh work.
    func addRemoteMachine(target: String) {
        guard let herdr = HerdrSession.locateHerdr() else { return }
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
    private func notifyAgentActivity(in snapshot: HerdrSnapshot) {
        let focusedTab = displayedFocusedTabId ?? snapshot.focusedTabId
        let appActive = NSApp?.isActive == true
        let events = activityWatcher.events(in: snapshot) { agent in
            appActive && agent.tabId == focusedTab
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
        HerdTerminalRuntime.focusTerminal()
    }

    // MARK: - Tips

    /// The tip shown at the foot of the sidebar, if any.
    @Published private(set) var currentTip: Tip?
    private var seenTips: Set<String> = []
    private static let seenTipsKey = "herd.tips.seen" + keySuffix

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
    private func autoNameTabs(in snapshot: HerdrSnapshot) {
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
    /// Herd is the active app, so leaving Herd open overnight doesn't keep it fresh.
    private func observeActivity(_ snapshot: HerdrSnapshot) {
        var updated = activity
        let focused = snapshot.focusedWorkspaceId
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
        if workspaceId == snapshot.focusedWorkspaceId,
           let next = activeGroups.flatMap(\.workspaces).first(where: { $0.workspaceId != workspaceId }) {
            lastFocusedWorkspaceId = next.workspaceId
            focusWorkspace(next.workspaceId)
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
        if case HerdrSocketError.server(_, let message) = error, !message.isEmpty { return message }
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

    private static func describe(_ error: Error) -> String {
        if case HerdrSocketError.server(_, let message) = error, !message.isEmpty { return message }
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
        pendingFocusedTabId = id
        pendingFocusDeadline = Date().addingTimeInterval(1.5)
        // Settles on the next snapshot, or after the deadline if herdr refused.
        perform("tab.focus", ["tab_id": id], failure: "Couldn't switch tabs")
    }

    func closeTab(_ id: String) {
        let label = tabLabel(id)
        let tabs = displayedTabs
        if id == displayedFocusedTabId, let index = tabs.firstIndex(where: { $0.tabId == id }), tabs.count > 1 {
            // Show the neighbor herdr will focus while the close is in flight.
            pendingFocusedTabId = tabs[index > 0 ? index - 1 : 1].tabId
            pendingFocusDeadline = Date().addingTimeInterval(1.5)
        }
        pendingClosedTabIds.insert(id)
        perform("tab.close", ["tab_id": id], failure: "Couldn't close \(label)")
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
        perform("pane.close", ["pane_id": pane], failure: "Couldn't close pane")
    }

    func focusPane(_ direction: PaneDirection) {
        perform("pane.focus_direction", ["direction": direction.rawValue])
    }

    func focusAgent(paneId: String) { perform("agent.focus", ["target": paneId]) }

    /// Focuses a tab in any workspace.
    func focusTabAnywhere(_ tab: HerdrTab) {
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

    func reloadHerdrConfig(quiet: Bool = false) {
        if quiet {
            perform("server.reload_config", [:], failure: "Couldn't apply the settings")
        } else {
            perform("server.reload_config", [:], toast: ToastText(
                progress: "Reloading the terminal config…", success: "Reloaded the terminal config", failure: "Couldn't reload the terminal config"
            ))
        }
    }

    func moveFocusedTab(by offset: Int) {
        let tabs = focusedWorkspaceTabs
        guard let index = tabs.firstIndex(where: { $0.tabId == snapshot.focusedTabId }) else { return }
        let target = max(0, min(tabs.count - 1, index + offset))
        guard target != index else { return }
        let label = tabLabel(tabs[index].tabId)
        perform("tab.move", ["tab_id": tabs[index].tabId, "insert_index": target], failure: "Couldn't move \(label)")
    }

    // MARK: - Plugins

    func refreshPlugins() {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plugins: [HerdrPlugin]
            do {
                let result = try client.call("plugin.list")
                let data = try JSONSerialization.data(withJSONObject: result["plugins"] ?? [])
                plugins = try JSONDecoder().decode([HerdrPlugin].self, from: data)
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
                return
            }
            DispatchQueue.main.async {
                if self?.plugins != plugins { self?.plugins = plugins }
            }
        }
    }

    /// Context herdr passes to plugin commands, matching what herdr's own UI sends.
    var pluginInvocationContext: [String: Any] {
        var context: [String: Any] = ["invocation_source": "herd-palette"]
        if let workspace = focusedWorkspace {
            context["workspace_id"] = workspace.workspaceId
            context["workspace_label"] = workspace.label
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { context["workspace_cwd"] = cwd }
        }
        if let tab = focusedWorkspaceTabs.first(where: { $0.tabId == snapshot.focusedTabId }) {
            context["tab_id"] = tab.tabId
            context["tab_label"] = tab.label
        }
        if let paneId = focusedPaneId {
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
    /// toast reports when the command actually finishes, not just when herdr
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
            var log: HerdrPluginLog?
            for _ in 0..<240 {
                let logs = (try? client.call("plugin.log.list", ["plugin_id": pluginId, "limit": 10]))
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                    .flatMap { try? JSONDecoder().decode([HerdrPluginLog].self, from: $0) } ?? []
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
                    self.toasts.succeed(handle, "Started \(title)", detail: "Still running — see the plugin's logs")
                }
                self.scheduleRefresh()
            }
        }
    }

    func openPluginPane(pluginId: String, paneId: String, placement: String?, title: String) {
        var params: [String: Any] = ["plugin_id": pluginId, "entrypoint": paneId, "focus": true]
        // Overlay and popup panes always attach to the active pane; herdr
        // rejects an explicit target for them.
        if let pane = focusedPaneId, placement == "split" || placement == "tab" || placement == "zoomed" {
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

    /// Downloads the plugin, shows herdr's install preview for confirmation,
    /// then installs it — with a toast for each stage.
    func installPlugin(repo: String, herdrPath: String, confirm: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        let handle = toasts.progress("Downloading \(repo)…", detail: "Fetching the install preview")
        PluginCLI.preview(repo: repo, herdrPath: herdrPath) { [weak self] result in
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
                    PluginCLI.install(repo: repo, herdrPath: herdrPath) { outcome in
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

    func uninstallPlugin(_ pluginId: String, herdrPath: String) {
        let name = pluginName(pluginId)
        let handle = toasts.progress("Removing \(name)…")
        PluginCLI.uninstall(pluginId: pluginId, herdrPath: herdrPath) { [weak self] outcome in
            guard let self else { return }
            if outcome.exitCode == 0 {
                self.toasts.succeed(handle, "Removed \(name)")
            } else {
                self.toasts.fail(handle, "Couldn't remove \(name)", detail: PluginCLI.lastLines(outcome.output))
            }
            self.refreshPlugins()
        }
    }

    func pluginLogs(pluginId: String?, completion: @escaping ([HerdrPluginLog]) -> Void) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            var params: [String: Any] = ["limit": 50]
            if let pluginId { params["plugin_id"] = pluginId }
            let logs = (try? client.call("plugin.log.list", params))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                .flatMap { try? JSONDecoder().decode([HerdrPluginLog].self, from: $0) } ?? []
            DispatchQueue.main.async { completion(logs) }
        }
    }

    // MARK: - Presentation helpers

    /// The most relevant agent in a set: blocked > working > done > idle.
    func primaryAgent(in agents: [HerdrAgent]) -> HerdrAgent? {
        let rank: [HerdrAgentStatus: Int] = [.blocked: 0, .working: 1, .done: 2, .idle: 3, .unknown: 4]
        return agents.min { (rank[$0.agentStatus] ?? 9) < (rank[$1.agentStatus] ?? 9) }
    }
}
