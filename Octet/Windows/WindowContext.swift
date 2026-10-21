import AppKit
import Combine
import SwiftUI

/// What an Octet window is opened with, and restored with across launches.
struct OctetWindowSpec: Codable, Hashable {
    var id = UUID()
    /// The workspace the window was opened for; nil shows whatever the
    /// engine has in front.
    var workspaceId: String?
    var splitWorkspaceId: String?
    var splitEdge: SplitEdge?
    var splitTabIDs: [String]?
    /// Where the window goes, in screen coordinates, when a tab was dropped
    /// there to make it.
    var origin: CGPoint?
    /// The whole frame, for a window reopened where it was last session.
    var frame: CGRect?
}

/// One Octet window, and the workspace and tab it shows.
///
/// With one window, every member here forwards to `SessionStore` exactly as
/// Octet has always worked: the engine's focus is the window's. With more,
/// each window keeps its own workspace and tab, and draws that tab's panes
/// from the engine itself (`NativePaneGrid`). Members are named after the
/// store's, so the chrome reads `window.focusedWorkspace` where it read
/// `store.focusedWorkspace`.
@MainActor
final class WindowContext: ObservableObject, Identifiable {
    let id: UUID
    let store: SessionStore
    let ui = UIState()
    let chromeDropdowns = OctetDropdownState()
    /// The plan of the agent in front, for the todo panel and its button.
    let todos = TodoModel()
    /// The project's instructions files and allow rules, for the right panel.
    let projectAgent = ProjectAgentModel()
    /// The agents' git, for the git panel and its button.
    let git = GitPanelModel()
    /// Plugins' panels for the folder in front, for their tab bar buttons.
    let pluginPanels = PluginPanelModel()
    let terminalQuestions = TerminalQuestionWatcher()
    /// Open files belong to a workspace, so each keeps its own tabs.
    private var editors: [String: (workspace: EditorWorkspace, watch: AnyCancellable)] = [:]
    var editor: EditorWorkspace {
        let key = focusedWorkspace?.workspaceId ?? ""
        if let found = editors[key] { return found.workspace }
        let workspace = EditorWorkspace()
        let watch = workspace.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        editors[key] = (workspace, watch)
        return workspace
    }
    /// Every workspace's editor, for what must cover them all (unsaved files).
    var allEditors: [EditorWorkspace] { editors.values.map(\.workspace) }
    /// A second workspace rendered in this window with its own engine client
    /// and tab strip. The two workspaces keep their engine tab lists separate.
    @Published private(set) var splitContext: WindowContext?
    @Published private(set) var splitEdge: SplitEdge = .right
    /// Tabs assigned to this surface when it shares its parent's workspace.
    /// The parent owns the remaining tabs in that workspace.
    @Published private(set) var splitGroupTabIDs: Set<String>?
    @Published private var focusedSplitContextID: UUID?
    weak var splitParent: WindowContext?
    var isEmbeddedSplit = false
    let containerLogs: ContainerLogWorkspace
    private(set) lazy var twin = TwinSession(window: self)
    weak var nsWindow: NSWindow?
    /// A popup pane floating over this window's terminal (`PopupTerminal`).
    @Published var popupPaneId: String?
    /// Find in the focused pane's output, drawn over the terminal.
    private(set) lazy var outputFind = OutputFindState(
        client: store.client, serverHasOptions: { [weak self] in self?.store.hasOctetEngine ?? false }
    ) { OctetTerminalRuntime.focusTerminal() }

    func findOutput(_ action: NSTextFinder.Action = .showFindInterface) {
        // A conversation in front searches its own transcript, not terminal output.
        if let session = AgentCenter.shared.active(in: focusedWorkspace?.workspaceId) {
            session.find.perform(action)
            return
        }
        guard nsWindow?.attachedSheet == nil else { return }
        outputFind.perform(action, pane: focusedPaneId)
    }
    /// Set as the window closes, so nothing gives it workspaces on the way out.
    var closing = false
    /// Closing without its workspaces: merged into another window, or closed
    /// by Octet itself (left with nothing of its own). They move to the window
    /// in front rather than closing with it.
    var mergingAway = false

    /// With more than one window: the workspace and tab this window shows.
    @Published fileprivate(set) var workspaceId: String?
    @Published fileprivate(set) var tabId: String?
    /// Covers the terminal while a native agent is stopped and its saved
    /// session is opened in Octet. Without this bridge, the replacement shell
    /// flashes between the two interfaces.
    @Published private(set) var agentUIHandoff: String?
    @Published private(set) var agentUIHandoffTabId: String?
    @Published private(set) var agentUIHandoffTitle: String?
    @Published private(set) var agentUIHandoffWorkspaceId: String?
    /// Remains true briefly after the handoff cover disappears because the
    /// engine's replacement-tab snapshot can land a frame or two later.
    @Published private(set) var suppressHandoffTabAnimations = false

    /// Terminal tabs and Octet conversations are stored by different owners,
    /// but share one strip. Keep their visual chronology on the window rather
    /// than in TabBarView state so a rebuilt view never briefly falls back to
    /// "all terminals, then all conversations" on its first frame.
    private var visualTabOrders: [String: [String]] = [:]

    /// `ids` with the terminal tabs in the engine's order: the strip, in
    /// the places it last gave each tab.
    func orderedVisualTabs(_ ids: [String]) -> [String] {
        let workspace = focusedWorkspace?.workspaceId ?? ""
        let previous = visualTabOrders[workspace] ?? []
        // A drop holds its order until the engine's catches up with it, so
        // the tab doesn't jump back for the moment the move takes.
        if let held = heldStripOrders[workspace] {
            let present = Set(ids)
            let known = Set(held)
            // Held until every tab it placed is here (one moving in from
            // another window arrives a snapshot or two later) and the
            // engine's order agrees with it.
            let arrived = held.allSatisfy { !TabStripOrder.isTerminal($0) || present.contains($0) }
            let engine = ids.filter { TabStripOrder.isTerminal($0) && known.contains($0) }
            if !arrived || held.filter({ TabStripOrder.isTerminal($0) && present.contains($0) }) != engine {
                let extra = ids.filter { !known.contains($0) }
                // Kept whole, with what hasn't arrived, for when it does.
                visualTabOrders[workspace] = held + extra
                return held.filter(present.contains) + extra
            }
            heldStripOrders[workspace] = nil
        }
        let order = TabStripOrder.reconcile(previous: previous, current: ids)
        visualTabOrders[workspace] = order
        return order
    }

    /// Strip orders a drop made, until the engine's order matches them.
    private var heldStripOrders: [String: [String]] = [:]

    private func hold(_ order: [String], in workspace: String) {
        heldStripOrders[workspace] = order
        objectWillChange.send()
        // A move the engine refused mustn't hold the strip for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.heldStripOrders[workspace] == order else { return }
            self.heldStripOrders[workspace] = nil
            self.objectWillChange.send()
        }
    }

    /// A tab of the strip dropped in the gap before position `gap`. Octet's
    /// own tabs move here alone; a terminal tab also moves in the engine,
    /// to the place that keeps it where it was dropped.
    func moveVisualTab(_ id: String, toGap gap: Int) {
        let workspace = focusedWorkspace?.workspaceId ?? ""
        let order = TabStripOrder.moving(id, toGap: gap, in: visualTabOrders[workspace] ?? [])
        objectWillChange.send()
        visualTabOrders[workspace] = order
        guard TabStripOrder.isTerminal(id) else { return }
        let tabId = String(id.dropFirst(TabStripOrder.terminalPrefix.count))
        let engine = store.snapshot.tabs(inWorkspace: workspace).map(\.tabId)
        hold(order, in: workspace)
        store.moveTab(tabId, toGap: TabStripOrder.engineGap(for: tabId, in: order, engine: engine))
    }

    /// A tab that just arrived (from another window) put at the strip's
    /// `gap`, where it was dropped, rather than last. `done` runs once it's
    /// there: focusing it before counts the wrong position.
    func placeArrivedTab(_ tabId: String, atGap gap: Int, then done: @escaping () -> Void = {}) {
        let workspace = focusedWorkspace?.workspaceId ?? ""
        let id = TabStripOrder.terminalPrefix + tabId
        var order = visualTabOrders[workspace] ?? []
        if !order.contains(id) { order.append(id) }
        order = TabStripOrder.moving(id, toGap: gap, in: order)
        visualTabOrders[workspace] = order
        hold(order, in: workspace)
        // The snapshot may not have it yet: it arrived last.
        var engine = store.snapshot.tabs(inWorkspace: workspace).map(\.tabId).filter { $0 != tabId }
        engine.append(tabId)
        let insert = TabStripOrder.engineGap(for: tabId, in: order, engine: engine)
        guard insert < engine.count - 1 else { return done() }
        store.call("tab.move", ["tab_id": tabId, "insert_index": insert], failure: "Couldn't move the tab") { _ in done() }
    }
    /// Empty terminal tabs retained only to keep a conversation's workspace
    /// alive. The tab bar hides them until the conversation closes or the
    /// person explicitly asks for a terminal.
    @Published private var conversationBackingTabs: [String: String] = [:]
    /// A workspace to go to once the engine's snapshot is in: a window made
    /// for a tab, or restored, opens wherever the engine was and then goes.
    private var pendingWorkspace: String?
    fileprivate var pendingSplitWorkspace: String?
    fileprivate var pendingSplitEdge: SplitEdge = .right
    fileprivate var pendingSplitTabIDs: [String]?
    /// Where this window last went, until the snapshot shows the engine's
    /// focus there: tells an arrival apart from a move made in the engine itself.
    fileprivate var expected: (workspace: String, tab: String?)?
    /// Since when this window has listed no workspace of its own.
    fileprivate var emptySince: Date?
    private var watch: AnyCancellable?
    private var containerLogsWatch: AnyCancellable?

    init(spec: OctetWindowSpec, store: SessionStore) {
        id = spec.id
        self.store = store
        containerLogs = ContainerLogWorkspace(key: "octet.workspaceContainerLogs.\(spec.id.uuidString)")
        pendingWorkspace = spec.workspaceId
        pendingSplitWorkspace = spec.splitWorkspaceId
        pendingSplitEdge = spec.splitEdge ?? .right
        pendingSplitTabIDs = spec.splitTabIDs
        // The chrome reads through here, so a store change is a change here.
        watch = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        containerLogsWatch = containerLogs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private var registry: WindowRegistry { .shared }
    /// Whether windows steer themselves. One window uses the API.
    var steers: Bool { registry.isMulti }

    // MARK: - What this window shows

    var focusedWorkspace: EngineWorkspace? {
        guard steers else { return store.focusedWorkspace }
        return store.snapshot.workspaces.first { $0.workspaceId == workspaceId }
    }

    var focusedWorkspaceTabs: [EngineTab] {
        guard steers else { return store.focusedWorkspaceTabs }
        guard let workspaceId else { return [] }
        let tabs = store.snapshot.tabs(inWorkspace: workspaceId)
        if let splitGroupTabIDs { return tabs.filter { splitGroupTabIDs.contains($0.tabId) } }
        if let child = splitContext, child.workspaceId == workspaceId,
           let assigned = child.splitGroupTabIDs {
            return tabs.filter { !assigned.contains($0.tabId) }
        }
        return tabs
    }

    var displayedTabs: [EngineTab] {
        guard steers else { return store.displayedTabs }
        return focusedWorkspaceTabs.filter { !store.pendingClosedTabIds.contains($0.tabId) }
    }

    var displayedFocusedTabId: String? {
        guard steers else { return store.displayedFocusedTabId }
        return tabId
    }

    /// The pane keys and splits act on. The engine reports one focused pane
    /// for the whole session: this window's when it moved last, else this
    /// tab's own focused pane, else its first.
    var focusedPaneId: String? {
        guard steers else { return store.focusedPaneId }
        guard let tabId else { return nil }
        if store.snapshot.focusedTabId == tabId, let pane = store.snapshot.focusedPaneId { return pane }
        let panes = store.snapshot.panes.filter { $0.tabId == tabId }
        return (panes.first(where: \.focused) ?? panes.first)?.paneId
    }

    /// What the focused pane runs. Looked up for one pane only, the one the
    /// engine last focused, so another window reads as unknown.
    var focusedProcess: ShellPrompt.ProcessInfo? {
        guard steers else { return store.focusedProcess }
        guard let pane = focusedPaneId, store.focusedProcessPaneId == pane else { return nil }
        return store.focusedProcess
    }

    var focusedPaneAtPrompt: Bool { ShellPrompt.isAtPrompt(focusedProcess) }

    var isKey: Bool { nsWindow?.isKeyWindow ?? false }

    // MARK: - This window's workspaces

    /// With several windows, each has workspaces of its own, the way each
    /// browser window has its own tabs: its sidebar lists only those.
    func owns(_ workspaceId: String) -> Bool {
        registry.belongs(workspaceId, to: self)
            || (splitContext.map { registry.belongs(workspaceId, to: $0) } ?? false)
    }

    /// The sidebar's groups, with only this window's workspaces.
    var activeGroups: [ProjectGroup] {
        guard steers else { return store.activeGroups }
        return store.activeGroups.compactMap { group in
            let mine = group.workspaces.filter { owns($0.workspaceId) }
            return mine.isEmpty ? nil : ProjectGroup(id: group.id, name: group.name, workspaces: mine)
        }
    }

    var idleWorkspaces: [EngineWorkspace] {
        guard steers else { return store.idleWorkspaces }
        return store.idleWorkspaces.filter { owns($0.workspaceId) }
    }

    /// This window's workspaces in sidebar order.
    var ownWorkspaces: [EngineWorkspace] {
        activeGroups.flatMap(\.workspaces) + idleWorkspaces
    }

    // MARK: - Beside the terminal

    /// One of Octet's own tabs shown beside the terminal rather than over
    /// it: a conversation, the editor or container logs, on `edge`, taking
    /// `share` of the space. It stays there as tabs change, until it's
    /// closed, dragged elsewhere, or put back over the terminal.
    struct Companion: Equatable {
        let stripId: String
        var edge: SplitEdge
        var share: CGFloat = 0.5
    }

    /// Each workspace's, since its conversations and logs are its own.
    @Published private var companions: [String: Companion] = [:]
    /// The share each tab last had beside the terminal, so it comes back at
    /// that size: the editor's split, too, which isn't dragged there.
    @Published private var companionShares: [String: CGFloat] = [:]

    /// The tab beside the terminal in the workspace showing, while it's open.
    var companion: Companion? {
        let workspace = focusedWorkspace?.workspaceId ?? ""
        guard var companion = companions[workspace] else { return nil }
        guard isOpen(companion.stripId) else {
            // Closed: it mustn't come back beside the terminal when one of
            // its kind opens again.
            DispatchQueue.main.async { [weak self] in
                if self?.companions[workspace]?.stripId == companion.stripId { self?.companions[workspace] = nil }
            }
            return nil
        }
        companion.share = share(of: companion.stripId)
        return companion
    }

    func share(of stripId: String) -> CGFloat { companionShares[stripId] ?? 0.5 }

    /// The divider beside `stripId` was dragged, or reset.
    func setShare(_ share: CGFloat, of stripId: String) {
        companionShares[stripId] = min(0.85, max(0.15, share))
    }

    /// Whether one of Octet's own tabs is still open in the workspace showing.
    private func isOpen(_ stripId: String) -> Bool {
        if stripId.hasPrefix("conversation:") {
            return AgentCenter.shared.sessions(in: focusedWorkspace?.workspaceId).contains { "conversation:" + $0.id == stripId }
        }
        if stripId.hasPrefix("editor:") { return !editor.documents.isEmpty }
        return workspaceContainerLogs.contains { $0.visualID == stripId }
    }

    func isBeside(_ stripId: String) -> Bool { companion?.stripId == stripId }

    /// Shows `stripId` beside the terminal on `edge`, taking it out from over
    /// the terminal if it was in front there.
    func showBeside(_ stripId: String, edge: SplitEdge) {
        let workspace = focusedWorkspace?.workspaceId
        if stripId.hasPrefix("conversation:"), AgentCenter.shared.active(in: workspace).map({ "conversation:" + $0.id }) == stripId {
            AgentCenter.shared.setActive(nil, in: workspace)
        }
        if stripId.hasPrefix("editor:") {
            editor.dismiss()
            editor.presentation = .split
        }
        if let log = activeContainerLog, log.visualID == stripId { containerLogs.activeID = nil }
        companions[workspace ?? ""] = Companion(stripId: stripId, edge: edge)
    }

    /// The tab beside the terminal goes back to being a tab of the strip.
    func stopShowingBeside() {
        companions[focusedWorkspace?.workspaceId ?? ""] = nil
    }


    // MARK: - Moving this window

    func focusTab(_ id: String) {
        containerLogs.activeID = nil
        editor.dismiss()
        DebugSnapshot.overlay("editor", false)
        conversationBackingTabs = conversationBackingTabs.filter { $0.value != id }
        AgentCenter.shared.setActive(nil, in: workspaceId)
        AgentCenter.shared.setBoard(nil, in: workspaceId)
        guard steers else { return store.focusTab(id) }
        guard let tab = store.snapshot.tabs.first(where: { $0.tabId == id }) else { return }
        focusTabAnywhere(tab)
    }

    /// A workspace another window shows brings that window forward, the way
    /// an editor brings forward the window that has a folder open; otherwise
    /// this window goes there.
    func focusWorkspace(_ id: String) {
        guard steers else { return store.focusWorkspace(id) }
        if let other = registry.window(showing: id), other !== self {
            other.bringForward()
            other.activateSplitSurface()
            return
        }
        // Another window's workspace is shown there, in that window.
        if let home = registry.home(of: id), home !== self {
            home.bringForward()
            home.activateSplitSurface()
            return home.steer(toWorkspace: id, tab: nil)
        }
        activateSplitSurface()
        steer(toWorkspace: id, tab: nil)
    }

    func focusTabAnywhere(_ tab: EngineTab) {
        containerLogs.activeID = nil
        guard steers else { return store.focusTabAnywhere(tab) }
        if let child = splitContext, child.workspaceId == tab.workspaceId,
           child.splitGroupTabIDs?.contains(tab.tabId) == true {
            child.activateSplitSurface()
            return child.steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
        }
        if splitGroupTabIDs?.contains(tab.tabId) == true {
            activateSplitSurface()
            return steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
        }
        if let parent = splitParent, parent.workspaceId == tab.workspaceId,
           splitGroupTabIDs?.contains(tab.tabId) == false {
            parent.activateSplitSurface()
            return parent.steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
        }
        if let other = registry.window(showing: tab.workspaceId) ?? registry.home(of: tab.workspaceId), other !== self {
            other.bringForward()
            other.activateSplitSurface()
            return other.steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
        }
        activateSplitSurface()
        steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
    }

    /// A banner's pane: its tab, in whichever window has its workspace.
    func focusAgent(paneId: String) {
        containerLogs.activeID = nil
        guard steers else { return store.focusAgent(paneId: paneId) }
        guard let pane = store.snapshot.panes.first(where: { $0.paneId == paneId }),
              let tab = store.snapshot.tabs.first(where: { $0.tabId == pane.tabId }) else { return }
        focusTabAnywhere(tab)
    }

    func focus(_ event: AgentEvent) {
        guard steers else { return store.focus(event) }
        if let tab = store.snapshot.tabs.first(where: { $0.tabId == event.tabId }) { focusTabAnywhere(tab) }
        OctetTerminalRuntime.focusTerminal()
    }

    func selectTab(number: Int) {
        if !workspaceContainerLogs.isEmpty {
            let tabs = logAwareVisualTabs
            let index = number >= 9 ? tabs.count - 1 : number - 1
            if tabs.indices.contains(index) { focusVisualTab(tabs[index]) }
            return
        }
        guard steers else { return store.selectTab(number: number) }
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        focusTab(tabs[index].tabId)
    }

    func selectAdjacentTab(offset: Int) {
        if !workspaceContainerLogs.isEmpty {
            let tabs = logAwareVisualTabs
            guard !tabs.isEmpty else { return }
            let current = activeVisualTab.flatMap { tabs.firstIndex(of: $0) } ?? 0
            focusVisualTab(tabs[((current + offset) % tabs.count + tabs.count) % tabs.count])
            return
        }
        guard steers else { return store.selectAdjacentTab(offset: offset) }
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.tabId == tabId } ?? 0
        focusTab(tabs[(current + offset + tabs.count) % tabs.count].tabId)
    }

    /// Next or previous of this window's workspaces, in sidebar order.
    func selectAdjacentWorkspace(offset: Int) {
        guard steers else { return store.selectAdjacentWorkspace(offset: offset) }
        let ordered = ownWorkspaces
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.workspaceId == workspaceId } ?? 0
        focusWorkspace(ordered[(current + offset + ordered.count) % ordered.count].workspaceId)
    }

    // MARK: - Making things in this window

    /// Something made through the API with `focus: false`, then this window
    /// sent to it: with more than one window, `focus: true` would move them all.
    private func create(_ method: String, _ params: [String: Any], failure: String,
                        result: (@MainActor ([String: Any]) -> Void)? = nil) {
        var params = params
        params["focus"] = false
        store.call(method, params, failure: failure, result: result) { [weak self] created in
            guard let self, let workspace = created.workspaceId ?? self.workspaceId else { return }
            if let tab = created.tabId, self.splitGroupTabIDs != nil {
                self.splitGroupTabIDs?.insert(tab)
            }
            self.steer(toWorkspace: workspace, tab: created.tabId)
        }
    }

    func newTab() {
        containerLogs.activeID = nil
        editor.dismiss()
        if let workspaceId = focusedWorkspace?.workspaceId,
           let session = AgentCenter.shared.active(in: workspaceId),
           let backing = conversationBackingTabs.removeValue(forKey: session.id),
           displayedTabs.contains(where: { $0.tabId == backing }) {
            focusTab(backing)
            return
        }
        guard steers else { return store.newTab() }
        guard let workspaceId else { return }
        var params: [String: Any] = ["workspace_id": workspaceId]
        if let cwd = store.snapshot.directory(ofWorkspace: workspaceId) { params["cwd"] = cwd }
        create("tab.create", params, failure: "Couldn't open a tab")
    }

    func newTab(running agent: DiscoveredAgent, arguments: [String] = [], label: String? = nil) {
        containerLogs.activeID = nil
        editor.dismiss()
        guard steers else { return store.newTab(running: agent, arguments: arguments, label: label) }
        guard let params = store.agentTabParams(agent, workspaceId: workspaceId,
                                                arguments: arguments, label: label) else { return }
        create("layout.apply", params, failure: "Couldn't open \(agent.displayName) in a tab")
    }

    /// A cloud session for `agent` in a new tab here, which the CLI streams
    /// into: `task` is what it's asked to do, when the agent takes one.
    func newCloudTab(_ agent: DiscoveredAgent, task: String?) {
        guard let arguments = CloudAgents.arguments(for: agent.id, task: task) else { return }
        newTab(running: agent, arguments: arguments,
               label: CloudAgents.tabLabel(agentName: agent.displayName, task: task))
    }

    /// `claude --teleport` in a new tab here: Claude lists its cloud
    /// sessions, and the one picked continues in this folder.
    func teleportCloudSession(_ agent: DiscoveredAgent) {
        newTab(running: agent, arguments: CloudAgents.teleportArguments, label: "\(agent.displayName) Teleport")
    }

    func newWorkspace(cwd: String? = nil) {
        guard steers else { return store.newWorkspace(cwd: cwd) }
        var params: [String: Any] = [:]
        if let cwd { params["cwd"] = cwd }
        create("workspace.create", params, failure: "Couldn't create a workspace")
    }

    func openProject(path: String) {
        guard steers else { return store.openProject(path: path) }
        if let existing = store.groups.first(where: { $0.id == path })?.workspaces.first {
            return focusWorkspace(existing.workspaceId)
        }
        let label = URL(fileURLWithPath: path).lastPathComponent
        create("workspace.create", ["cwd": path, "label": label], failure: "Couldn't open \(label)")
    }

    func createWorktree(branch: String) {
        guard steers else { return store.createWorktree(branch: branch) }
        var params: [String: Any] = ["branch": branch]
        if let workspaceId { params["workspace_id"] = workspaceId }
        create("worktree.create", params, failure: "Couldn't create worktree \(branch)") { [store] result in
            WorktreeSetupRunner.shared.run(after: result, store: store)
        }
    }

    /// Opens an engine layout here: an agent attached from a board, a
    /// conversation continued in its CLI, a Codex thread resumed.
    func applyLayout(_ params: [String: Any], failure: String) {
        var params = params
        if params["workspace_id"] == nil, let workspaceId { params["workspace_id"] = workspaceId }
        guard steers else {
            params["focus"] = true
            return store.call("layout.apply", params, failure: failure) { _ in }
        }
        create("layout.apply", params, failure: failure)
    }

    // MARK: - Panes and tabs in this window

    func splitPane(_ direction: SessionStore.SplitDirection) {
        guard steers else { return store.splitPane(direction) }
        guard let pane = focusedPaneId else { return }
        // The engine's focus moves no other window's panes: the new pane can
        // take it directly.
        var params: [String: Any] = ["direction": direction.rawValue, "target_pane_id": pane, "focus": true]
        if let workspaceId, let cwd = store.snapshot.directory(ofWorkspace: workspaceId) { params["cwd"] = cwd }
        store.call("pane.split", params, failure: "Couldn't split pane") { _ in }
    }

    /// A fresh shell on `edge`'s side of the focused pane, in the
    /// workspace's folder as ⌘D's: the way to split left or up, which
    /// have no key of their own.
    func splitPane(beside edge: SplitEdge) {
        guard let pane = focusedPaneId, let tab = store.snapshot.panes.first(where: { $0.paneId == pane })?.tabId else { return }
        store.splitNewPane(beside: pane, inTab: tab, edge: edge,
                           cwd: workspaceId.flatMap { store.snapshot.directory(ofWorkspace: $0) })
    }

    /// Every split in the tab showing back to equal shares.
    func equalizePanes() {
        guard store.hasOctetEngine else { return Self.needsOctetEngine("Making panes equal") }
        guard let pane = focusedPaneId else { return }
        store.call("pane.equalize", ["pane_id": pane], failure: "Couldn't make the panes equal") { _ in }
    }

    /// The focused pane's divider on that side, moved a couple of cells, as
    /// a keyboard resize moves it.
    func moveDivider(_ direction: SessionStore.PaneDirection) {
        guard store.hasOctetEngine else { return Self.needsOctetEngine("Moving a divider") }
        guard let pane = focusedPaneId else { return }
        store.call("pane.resize_cells", ["pane_id": pane, "direction": direction.rawValue, "cells": 2],
                   failure: "Couldn't move the divider") { _ in }
    }

    /// The focused pane out of its split into a window of its own.
    func moveFocusedPaneToNewWindow() {
        guard let pane = focusedPaneId else { return }
        WindowActions.tearOff(paneId: pane, store: store, frame: WindowActions.cascaded(from: self))
    }

    private static func needsOctetEngine(_ what: String) {
        ToastCenter.shared.info("\(what) needs Octet's own terminal engine",
                                detail: "This session runs a stock Herdr; Octet's build adds it (scripts/build-engine.sh).")
    }

    func focusPane(_ direction: SessionStore.PaneDirection) {
        guard steers, let pane = focusedPaneId else { return store.focusPane(direction) }
        // From this window's own pane, not wherever the engine's focus is.
        store.call("pane.focus_direction", ["pane_id": pane, "direction": direction.rawValue],
                   failure: "Couldn't move to the pane") { _ in }
    }

    /// Copy mode in the focused pane: its scrollback by the keys.
    func toggleCopyMode() {
        guard let pane = focusedPaneId, let view = PaneMirrorView.view(of: pane) else { return }
        if view.inCopyMode { view.leaveCopyMode() } else { view.enterCopyMode() }
    }

    /// The next pane of the tab, or the one before, in the order the layout
    /// lists them, round to the start.
    func cyclePane(by offset: Int) {
        guard let tab = displayedFocusedTabId,
              let panes = store.snapshot.layouts.first(where: { $0.tabId == tab })?.panes.map(\.paneId),
              panes.count > 1 else { return }
        let index = focusedPaneId.flatMap(panes.firstIndex(of:)) ?? 0
        let next = panes[((index + offset) % panes.count + panes.count) % panes.count]
        store.call("pane.focus", ["pane_id": next], failure: "Couldn't move to the pane") { _ in }
    }

    func toggleZoom() {
        guard steers else { return store.toggleZoom() }
        guard let pane = focusedPaneId else { return }
        store.call("pane.zoom", ["pane_id": pane, "mode": "toggle"], failure: "Couldn't zoom the pane") { _ in }
    }

    func closeFocusedPane() {
        guard steers else { return store.closeFocusedPane() }
        guard let pane = focusedPaneId else { return }
        store.closePane(pane) { [store] in
            store.call("pane.close", ["pane_id": pane], failure: "Couldn't close pane") { _ in }
        }
    }

    /// Brings a closed tab back into this window, running as it was left:
    /// `record`, else the one closed last.
    func reopenClosedTab(_ record: ClosedTabRecord? = nil) {
        let closed = store.closedTabs
        guard let record = record ?? closed.records.last else {
            ToastCenter.shared.info("No closed tabs to reopen",
                                    detail: "A tab closed while something runs in it can be reopened for a while.")
            return
        }
        guard let pane = closed.pane(for: record), let target = focusedWorkspace?.workspaceId else {
            closed.forget(record)
            ToastCenter.shared.info("\(record.title) has already ended")
            return
        }
        closed.forget(record)
        store.call("pane.move", ["pane_id": pane.paneId, "destination": ["type": "new_tab", "workspace_id": target], "focus": false],
                   failure: "Couldn't reopen \(record.title)") { [weak self] created in
            guard let self, let tab = created.tabId else { return }
            self.focusTab(tab)
            self.bringForward()
        }
    }

    func closeFocusedTab() {
        if let log = activeContainerLog { closeContainerLogs(log.id); return }
        if editor.isPresented {
            editor.closeEditor()
            return
        }
        if let session = AgentCenter.shared.active(in: focusedWorkspace?.workspaceId) {
            conversationBackingTabs[session.id] = nil
            AgentCenter.shared.close(session)
            return
        }
        guard let id = displayedFocusedTabId else { return }
        closeTab(id)
    }

    /// The engine picks the neighbour for a client whose tab closed; this
    /// window shows that neighbour at once rather than waiting to hear.
    func closeTab(_ id: String, confirmed: Bool = false) {
        guard steers else { return store.closeTab(id) }
        guard confirmed else {
            return store.confirmClosing(store.snapshot.panes.filter { $0.tabId == id }, place: "tab") { [weak self] in
                self?.closeTab(id, confirmed: true)
            }
        }
        if displayedTabs.count == 1, displayedTabs.first?.tabId == id {
            if let splitParent {
                splitParent.closeWorkspaceSplit()
            } else if let child = splitContext, child.workspaceId == workspaceId,
                      child.splitGroupTabIDs != nil, let survivor = child.displayedFocusedTabId {
                closeWorkspaceSplit()
                tabId = survivor
            } else if let survivor = splitContext?.focusedWorkspace?.workspaceId {
                closeWorkspaceSplit()
                focusWorkspace(survivor)
            }
        }
        if id == tabId {
            let tabs = displayedTabs
            if let index = tabs.firstIndex(where: { $0.tabId == id }), tabs.count > 1 {
                tabId = tabs[index > 0 ? index - 1 : 1].tabId
            }
        }
        store.closeTab(id, confirmed: true)
    }

    /// ⌘⇧R: the changes in the focused pane's project, or closes the review.
    func toggleReview() {
        if ui.review != nil {
            ui.review = nil
            OctetTerminalRuntime.focusTerminal()
            return
        }
        guard let directory = focusedDirectory else { return }
        ui.pullRequests = nil
        ui.review = DiffReviewModel(directory: directory)
    }

    /// The Pull Requests page over the terminal, or closes it. It doesn't
    /// need a project in front: "All" searches every repository.
    func togglePullRequests(scope: PullRequestScope = .all) {
        if ui.pullRequests != nil {
            ui.pullRequests = nil
            OctetTerminalRuntime.focusTerminal()
            return
        }
        ui.review = nil
        ui.pullRequests = PullRequestsPageModel(directory: focusedDirectory, scope: scope)
    }

    /// The folder of the pane in front, else of its workspace: where the
    /// review, the Diff plane and pull requests look.
    var focusedDirectory: String? {
        let snapshot = store.snapshot
        return focusedPaneId.flatMap({ snapshot.workingDirectory(ofPane: $0) })
            ?? focusedWorkspace.flatMap({ snapshot.directory(ofWorkspace: $0.workspaceId) })
    }

    func runInFocusedPane(_ line: String) {
        guard let pane = focusedPaneId else { return }
        store.runInPane(pane, line: line)
    }

    func runInFocusedPane(_ agent: DiscoveredAgent) {
        guard let path = agent.executablePath else { return }
        runInFocusedPane(agent.onShellPath == true ? agent.command : shellQuote(path))
    }

    func moveFocusedPaneToNewTab() {
        guard steers else { return store.moveFocusedPaneToNewTab() }
        guard let pane = focusedPaneId, let tabId,
              store.snapshot.panes.filter({ $0.tabId == tabId }).count > 1 else { return }
        create("pane.move", ["pane_id": pane, "destination": ["type": "new_tab"]], failure: "Couldn't move the pane to a new tab")
    }

    /// With no engine named, the default agent from Settings › Agents.
    func newConversation(engine: AgentSession.Engine? = nil, cwd: String? = nil,
                         replacingStarterTab starterTabId: String? = nil) {
        let engine = engine ?? .preferred
        containerLogs.activeID = nil
        editor.dismiss()
        guard let workspace = focusedWorkspace else { return }
        let folder = cwd ?? store.snapshot.directory(ofWorkspace: workspace.workspaceId) ?? NSHomeDirectory()
        let session = AgentCenter.shared.newConversation(workspaceId: workspace.workspaceId, cwd: folder, engine: engine)
        if let starterTabId { conversationBackingTabs[session.id] = starterTabId }
    }

    // MARK: - Inline editor

    var editorRootDirectory: String {
        if let workspaceId = focusedWorkspace?.workspaceId,
           let path = store.snapshot.directory(ofWorkspace: workspaceId) {
            if let document = editor.activeDocument,
               document.url.path != path && !document.url.path.hasPrefix(path + "/") {
                return ProjectRootResolver.projectRoot(forDirectory: document.directory,
                                                       projectParentDirectories: ProjectGrouping.defaultParentDirectories)
                    ?? document.directory
            }
            return path
        }
        return editor.activeDocument?.directory ?? NSHomeDirectory()
    }

    func showEditor() {
        containerLogs.activeID = nil
        guard !editor.documents.isEmpty else {
            editor.filePickerVisible = true
            return
        }
        AgentCenter.shared.setActive(nil, in: focusedWorkspace?.workspaceId)
        AgentCenter.shared.setBoard(nil, in: focusedWorkspace?.workspaceId)
        twin.hide()
        editor.isPresented = true
        DebugSnapshot.overlay("editor", true)
    }

    func openFile(_ url: URL, presentation: EditorWorkspace.Presentation = .split) {
        containerLogs.activeID = nil
        AgentCenter.shared.setActive(nil, in: focusedWorkspace?.workspaceId)
        AgentCenter.shared.setBoard(nil, in: focusedWorkspace?.workspaceId)
        twin.hide()
        if presentation == .split {
            editor.fileTreeVisible = false
            panelUI.showPlane(.files)
        }
        editor.open(url, presentation: presentation)
        DebugSnapshot.overlay("editor", editor.isPresented)
    }

    var editorFilesVisible: Bool {
        editor.presentation == .split ? panelUI.showing(.files) : editor.fileTreeVisible
    }

    func toggleEditorFiles() {
        if editor.presentation == .split {
            if panelUI.showing(.files) { panelUI.sidePanelVisible = false }
            else { panelUI.showPlane(.files) }
        } else {
            editor.fileTreeVisible.toggle()
        }
    }

    func toggleEditorPresentation() {
        editor.togglePresentation()
        if editor.presentation == .split {
            editor.fileTreeVisible = false
            panelUI.showPlane(.files)
        }
    }

    func splitWorkspace(_ workspaceId: String, at edge: SplitEdge) {
        guard focusedWorkspace?.workspaceId != workspaceId else { return }
        if let splitContext {
            if splitContext.focusedWorkspace?.workspaceId == workspaceId {
                splitEdge = edge
                WindowRegistry.shared.save()
                return
            }
            closeWorkspaceSplit()
        }
        let child = WindowContext(spec: OctetWindowSpec(workspaceId: workspaceId), store: store)
        child.isEmbeddedSplit = true
        child.splitParent = self
        child.nsWindow = nsWindow
        splitEdge = edge
        splitContext = child
        WindowRegistry.shared.add(child)
        // Registry.add initializes a new client from the engine's global
        // focus. Claim the dragged workspace before the split is drawn, or
        // its first frame (and tab strip) copies the destination workspace.
        child.steer(toWorkspace: workspaceId, tab: nil)
        activateSplitSurface(child)
        WindowRegistry.shared.save()
    }

    /// Put an existing engine tab in an independent tab group in this window.
    /// Both surfaces still show the same workspace; the tab and its panes are
    /// never recreated or moved by the session engine.
    func splitTabGroup(_ tabId: String, at edge: SplitEdge) {
        guard let workspaceId = focusedWorkspace?.workspaceId,
              store.snapshot.tabs.first(where: { $0.tabId == tabId })?.workspaceId == workspaceId else { return }
        if let child = splitContext, child.workspaceId == workspaceId,
           child.splitGroupTabIDs != nil {
            child.splitGroupTabIDs?.insert(tabId)
            if self.tabId == tabId { self.tabId = focusedWorkspaceTabs.first?.tabId }
            child.steer(toWorkspace: workspaceId, tab: tabId)
            activateSplitSurface(child)
            WindowRegistry.shared.save()
            return
        }
        if splitContext != nil { closeWorkspaceSplit() }
        let child = WindowContext(spec: OctetWindowSpec(workspaceId: workspaceId), store: store)
        child.isEmbeddedSplit = true
        child.splitParent = self
        child.nsWindow = nsWindow
        child.splitGroupTabIDs = [tabId]
        child.pendingWorkspace = nil
        child.askedToRestore = true
        splitEdge = edge
        splitContext = child
        WindowRegistry.shared.add(child)
        if self.tabId == tabId { self.tabId = focusedWorkspaceTabs.first?.tabId }
        child.steer(toWorkspace: workspaceId, tab: tabId)
        activateSplitSurface(child)
        WindowRegistry.shared.save()
    }

    func acceptTabIntoGroup(_ tabId: String) {
        guard let workspaceId,
              store.snapshot.tabs.first(where: { $0.tabId == tabId })?.workspaceId == workspaceId else { return }
        if splitGroupTabIDs != nil {
            if let parent = splitParent, parent.focusedWorkspaceTabs.count == 1,
               parent.focusedWorkspaceTabs.first?.tabId == tabId {
                parent.closeWorkspaceSplit()
                parent.focusTab(tabId)
                return
            }
            splitGroupTabIDs?.insert(tabId)
            if splitParent?.tabId == tabId { splitParent?.tabId = splitParent?.focusedWorkspaceTabs.first?.tabId }
        } else if let child = splitContext, child.workspaceId == workspaceId {
            child.splitGroupTabIDs?.remove(tabId)
            if child.tabId == tabId { child.tabId = child.focusedWorkspaceTabs.first?.tabId }
            if child.splitGroupTabIDs?.isEmpty == true { closeWorkspaceSplit() }
        }
        focusTab(tabId)
        WindowRegistry.shared.save()
    }

    var panelContext: WindowContext {
        if focusedSplitContextID == splitContext?.id, let splitContext { return splitContext }
        return self
    }

    var panelUI: UIState { splitParent?.ui ?? ui }

    /// Drawers in two tab groups of the same workspace need distinct shell
    /// identities, even though their terminal tabs share the workspace.
    var drawerKey: String {
        let workspace = SidebarTerminals.key(focusedWorkspace?.workspaceId)
        if splitParent?.focusedWorkspace?.workspaceId == focusedWorkspace?.workspaceId {
            return "\(workspace)::split:\(id.uuidString)"
        }
        return workspace
    }

    func activateSplitSurface(_ surface: WindowContext? = nil) {
        let owner = splitParent ?? self
        let target = surface ?? self
        guard target === owner || target === owner.splitContext else { return }
        owner.focusedSplitContextID = target === owner ? nil : target.id
        owner.ui.activateWorkspacePanel(target.focusedWorkspace?.workspaceId,
                                        preserveWindowState: owner.splitContext != nil)
        WindowRegistry.shared.becameKey(target)
    }

    func closeWorkspaceSplit() {
        guard let child = splitContext else { return }
        if focusedSplitContextID == child.id, child.workspaceId == workspaceId,
           child.splitGroupTabIDs != nil { tabId = child.tabId }
        child.closing = true
        WindowRegistry.shared.remove(child)
        splitContext = nil
        focusedSplitContextID = nil
        ui.activateWorkspacePanel(focusedWorkspace?.workspaceId, preserveWindowState: true)
        if !closing { WindowRegistry.shared.save() }
    }

    func detachWorkspaceSplit() {
        guard let child = splitContext, let workspaceId = child.focusedWorkspace?.workspaceId else { return }
        WindowOpener.open?(OctetWindowSpec(workspaceId: workspaceId,
                                           frame: WindowActions.cascaded(from: self)))
        closeWorkspaceSplit()
    }

    func showFilePicker() {
        editor.requestedPresentation = editor.isPresented ? editor.presentation : .split
        editor.filePickerVisible = true
    }

    func hidesAsConversationBackingTab(_ tabId: String, sessions: [AgentSession]) -> Bool {
        let liveIds = Set(sessions.map(\.id))
        return conversationBackingTabs.contains { liveIds.contains($0.key) && $0.value == tabId }
    }

    // MARK: - Agents in the terminal or in Octet

    /// Opens a conversation in the folder `pane` is in, for an agent typed at
    /// its prompt. False when Octet can't converse with that agent, which
    /// leaves the command to run in the terminal.
    @discardableResult
    func openAgentConversation(_ agent: String, inPane paneId: String?) -> Bool {
        guard let engine = AgentSession.Engine(rawValue: agent) else { return false }
        let pane = store.snapshot.panes.first { $0.paneId == paneId }
        // A command typed into a blank terminal replaces that visual tab. The
        // terminal remains only as a hidden workspace anchor, and closing the
        // conversation never closes the workspace beneath it.
        newConversation(engine: engine, cwd: pane?.effectiveCwd,
                        replacingStarterTab: pane?.tabId)
        return true
    }

    /// Starts `agent` here, as the setting says: Octet's conversation view,
    /// or its own interface typed into the focused pane.
    func startAgent(_ agent: DiscoveredAgent) {
        if SettingsStore.shared.values.agentOpening == .octet, openAgentConversation(agent.id, inPane: focusedPaneId) { return }
        runInFocusedPane(agent)
    }

    /// The banner's "Switch to Octet UI": moves an agent running in a terminal
    /// pane into a conversation, continuing its session when Octet knows the
    /// id. Two processes never write one session, so the terminal one ends.
    func continueInOctet(_ agent: EngineAgent) {
        guard let id = AgentOffer.agentId(agent), let engine = AgentSession.Engine(rawValue: id) else { return }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? engine.displayName
        let proceed: () -> Void = { [weak self] in self?.moveToOctet(agent, engine: engine) }
        guard agent.agentStatus == .working else {
            proceed()
            return
        }
        ConfirmCenter.shared.ask(
            title: "\(name) is working",
            message: "Switching to conversation view restarts \(name) in Octet. The step in progress runs again, and background commands, monitors and subagents are started again there.",
            confirmTitle: "Switch to Octet UI"
        ) { _ in proceed() }
    }

    /// A workspace menu's "Open on Octet UI": brings the agent's workspace
    /// into view, in whichever window shows it, then switches it over.
    func openOnOctetUI(_ agent: EngineAgent) {
        guard let workspaceId = agent.workspaceId else { return continueInOctet(agent) }
        if let other = registry.window(showing: workspaceId), other !== self {
            other.bringForward()
            return other.continueInOctet(agent)
        }
        focusWorkspace(workspaceId)
        continueInOctet(agent)
    }

    private func moveToOctet(_ agent: EngineAgent, engine: AgentSession.Engine) {
        guard let workspaceId = agent.workspaceId ?? focusedWorkspace?.workspaceId else { return }
        let snapshot = store.snapshot
        let cwd = agent.effectiveCwd ?? snapshot.directory(ofWorkspace: workspaceId) ?? NSHomeDirectory()
        let sessionId = agent.sessionReference ?? agent.terminalId.flatMap { store.recovery.sessionId(forTerminal: $0) }
        let label = snapshot.tabs.first { $0.tabId == agent.tabId }.map { TabAutoName.display(label: $0.label, number: $0.number) }
        let title = label.flatMap { TabAutoName.isUnnamed($0) ? nil : $0 }
        beginAgentUIHandoff(engine.agent, workspaceId: workspaceId,
                            tabId: agent.tabId, title: title ?? engine.displayName)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        let session: AgentSession = withTransaction(transaction) {
            let staged: AgentSession
            if let sessionId {
                staged = AgentCenter.shared.resume(engine: engine, sessionId: sessionId, cwd: cwd,
                                                   workspaceId: workspaceId, title: title, start: false)
            } else {
                staged = AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: cwd,
                                                            engine: engine, start: false)
            }
            if snapshot.panes.filter({ $0.tabId == agent.tabId }).count <= 1,
               let oldTabId = agent.tabId {
                conversationBackingTabs[staged.id] = oldTabId
            }
            agentUIHandoff = nil
            agentUIHandoffTabId = nil
            agentUIHandoffTitle = nil
            agentUIHandoffWorkspaceId = nil
            return staged
        }
        if sessionId == nil {
            ToastCenter.shared.info("Started a new \(engine.displayName) conversation",
                                    detail: "Octet couldn't tell which session the terminal was on. Its history stays in \(engine.displayName).")
        }
        AgentOfferCenter.shared.dismiss(agent)
        let turnInterrupted = agent.agentStatus == .working
        let finish: (Date?) -> Void = { [weak self] processStart in
            guard let self else { return }
            self.endTerminalAgent(agent, workspaceId: workspaceId) { backingTabId in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let backingTabId {
                        self.conversationBackingTabs[session.id] = backingTabId
                    } else {
                        self.conversationBackingTabs[session.id] = nil
                    }
                }
                session.startRestoredProcess()
                if let sessionId, engine == .claude {
                    Self.carryRuntimes(into: session, sessionId: sessionId, cwd: cwd,
                                       processStart: processStart, turnInterrupted: turnInterrupted)
                }
                // Snapshot delivery for the closed and backing tabs is
                // asynchronous. Keep their later diffs animation-free too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { self.suppressHandoffTabAnimations = false }
                }
            }
        }
        guard sessionId != nil, engine == .claude else { return finish(nil) }
        // Which background work is still live depends on when the terminal's
        // process started, and that is only readable while it runs.
        let client = store.client
        let paneId = agent.paneId
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Self.claudeProcessStart(client: client, paneId: paneId)
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(start) } }
        }
    }

    /// The start of the Claude Code process in `paneId`'s foreground.
    private nonisolated static func claudeProcessStart(client: EngineClient, paneId: String) -> Date? {
        guard let info = (try? client.call("pane.process_info", ["pane_id": paneId])).flatMap(ShellPrompt.parse) else { return nil }
        let claude = info.foreground.first { process in
            let command = (process.name as NSString).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return AgentBrand.forAgent(command)?.id == "claude"
        }
        return claude.flatMap { AgentRuntimeHandoff.processStart(pid: $0.pid) }
    }

    /// Reads the terminal session's final log and has the conversation start
    /// again whatever the terminal process was still running: background
    /// commands, monitors and subagents all end with the process that owns them.
    private static func carryRuntimes(into session: AgentSession, sessionId: String, cwd: String,
                                      processStart: Date?, turnInterrupted: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = AgentConversation.findLog(sessionIds: [sessionId], cwd: cwd)
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                .components(separatedBy: "\n") ?? []
            let runtimes = AgentRuntimeHandoff.liveRuntimes(lines: lines, processStart: processStart)
            var transcript = lines.isEmpty ? nil : AgentConversation.replay(lines: lines)
            transcript?.cwd = cwd
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard AgentCenter.shared.sessions.contains(where: { $0 === session }) else { return }
                    session.continueAfterHandoff(transcript: transcript, runtimes: runtimes,
                                                 turnInterrupted: turnInterrupted)
                }
            }
        }
    }

    private func beginAgentUIHandoff(_ agent: String, workspaceId: String?, tabId: String?, title: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            suppressHandoffTabAnimations = true
            agentUIHandoff = agent
            agentUIHandoffWorkspaceId = workspaceId
            agentUIHandoffTabId = tabId
            agentUIHandoffTitle = title
        }
        // A failed engine close reports its own toast. Do not leave the
        // transition cover stranded if that callback never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.agentUIHandoff == agent else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self?.agentUIHandoff = nil
                self?.agentUIHandoffTabId = nil
                self?.agentUIHandoffTitle = nil
                self?.agentUIHandoffWorkspaceId = nil
                self?.suppressHandoffTabAnimations = false
            }
        }
    }

    #if DEBUG
    func debugShowAgentUIHandoff(_ agent: String = "claude") {
        beginAgentUIHandoff(agent, workspaceId: focusedWorkspace?.workspaceId,
                            tabId: displayedFocusedTabId,
                            title: AgentBrand.forAgent(agent)?.displayName ?? "Agent")
    }
    #endif

    /// Closes the terminal the agent runs in (its pane in a split, else its
    /// tab), leaving the workspace a terminal: a workspace with no tab closes,
    /// and a conversation belongs to its workspace.
    private func endTerminalAgent(_ agent: EngineAgent, workspaceId: String,
                                  then done: @escaping (String?) -> Void) {
        let snapshot = store.snapshot
        let panesInTab = snapshot.panes.filter { $0.tabId == agent.tabId }.count
        let close: (String?) -> Void = { [store] backingTabId in
            if panesInTab > 1 || agent.tabId == nil {
                store.call("pane.close", ["pane_id": agent.paneId], failure: "Couldn't close the terminal") { _ in
                    done(backingTabId)
                }
            } else if let tab = agent.tabId {
                store.call("tab.close", ["tab_id": tab], failure: "Couldn't close the terminal") { _ in
                    done(backingTabId)
                }
            }
        }
        guard panesInTab <= 1, snapshot.tabs(inWorkspace: workspaceId).count <= 1 else {
            close(nil)
            return
        }
        var params: [String: Any] = ["workspace_id": workspaceId, "focus": false]
        if let cwd = snapshot.directory(ofWorkspace: workspaceId) { params["cwd"] = cwd }
        store.call("tab.create", params, failure: "Couldn't open a terminal") { created in
            close(created.tabId)
        }
    }

    /// ⌘⇧A: this window's agents hub, open or closed.
    func toggleAgentsBoard() {
        let center = AgentCenter.shared
        let workspace = focusedWorkspace?.workspaceId
        center.setBoard(center.board(in: workspace) == nil ? .all : nil, in: workspace)
    }

    // MARK: - Steering

    /// Shows `workspace` here, and `tab` in it when given (else the tab the
    /// engine last showed there). The panes are drawn from the engine
    /// whatever its focus, so nothing has to be moved to get there.
    func steer(toWorkspace workspace: String, tab: String?) {
        guard let shown = store.snapshot.workspaces.first(where: { $0.workspaceId == workspace }) else { return }
        workspaceId = workspace
        tabId = tab ?? shown.activeTabId
        expected = (workspace, tab)
        // What a window shows is its own.
        if steers, splitGroupTabIDs == nil { registry.claim(workspace, for: self) }
    }

    func bringForward() {
        nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Keeping up with the engine

    /// Starts this window on what the engine shows, or on the workspace it
    /// was opened for once its terminal is up.
    fileprivate func adoptEngineFocus() {
        workspaceId = store.focusedWorkspace?.workspaceId
        tabId = store.displayedFocusedTabId
    }

    /// The terminal area is up: the window can go where it was opened for.
    func terminalReady() {
        terminalIsReady = true
        goToPendingWorkspace()
    }

    private var terminalIsReady = false
    fileprivate var awaitingWorkspace: Bool { pendingWorkspace != nil }
    fileprivate private(set) var askedToRestore = false

    /// Goes where the window was opened for once both its terminal and the
    /// engine's snapshot are up; at launch the terminal can come first.
    fileprivate func goToPendingWorkspace() {
        guard terminalIsReady else { return }
        if !askedToRestore {
            askedToRestore = true
            if pendingWorkspace == nil { pendingWorkspace = registry.restoredWorkspace(for: self) }
        }
        guard let workspace = pendingWorkspace else { return }
        let workspaces = store.snapshot.workspaces
        guard !workspaces.isEmpty else { return }
        // A restored window's workspace may be gone: it keeps what it shows.
        guard workspaces.contains(where: { $0.workspaceId == workspace }) else { return }
        pendingWorkspace = nil
        guard steers else { return store.focusWorkspace(workspace) }
        steer(toWorkspace: workspace, tab: nil)
        if let split = pendingSplitWorkspace,
           workspaces.contains(where: { $0.workspaceId == split }) {
            pendingSplitWorkspace = nil
            if split == workspace, let ids = pendingSplitTabIDs, !ids.isEmpty {
                let tabs = store.snapshot.tabs(inWorkspace: workspace)
                let live = Set(tabs.map(\.tabId))
                let assigned = Set(ids).intersection(live)
                if !assigned.isEmpty, tabs.contains(where: { !assigned.contains($0.tabId) }),
                   let first = ids.first(where: assigned.contains) {
                    splitTabGroup(first, at: pendingSplitEdge)
                    splitContext?.splitGroupTabIDs = assigned
                }
            } else if split != workspace {
                splitWorkspace(split, at: pendingSplitEdge)
            }
        }
        registry.claimRestoredMembers(of: workspace, for: self)
        // A workspace moved into this window leaves the one that showed it.
        registry.windows.filter { $0 !== self }.forEach { $0.yield(workspace) }
    }

    /// Closes this window, keeping its workspaces, once the update under way
    /// is done: closed from inside one, the window can be dropped from the
    /// registry yet stay on screen.
    fileprivate func closeWindowLater() {
        mergingAway = true
        closing = true
        DispatchQueue.main.async { [weak self] in self?.nsWindow?.close() }
    }

    /// Another window took `workspace`: if this one shows it, it moves to the
    /// nearest of its own workspaces in sidebar order.
    fileprivate func yield(_ workspace: String) {
        guard workspaceId == workspace else { return }
        let ordered = store.activeGroups.flatMap(\.workspaces) + store.idleWorkspaces
        guard let index = ordered.firstIndex(where: { $0.workspaceId == workspace }) else { return }
        let candidates = Array(ordered[(index + 1)...]) + ordered[..<index].reversed()
        guard let next = candidates.first(where: { owns($0.workspaceId) && $0.workspaceId != workspace }) else { return }
        steer(toWorkspace: next.workspaceId, tab: nil)
    }

    /// Checks this window against a new snapshot: a tab or workspace it shows
    /// that closed is replaced by a neighbour, and the engine is told.
    fileprivate func reconcile() {
        // A window that's gone (a check scheduled before it closed) has
        // nothing to reconcile, and would take workspaces as its own.
        guard !closing, registry.windows.contains(where: { $0 === self }) else { return }
        let snapshot = store.snapshot
        guard !snapshot.workspaces.isEmpty else { return }
        // A window with no workspace of its own and others open has nothing to
        // show. It gets a moment, in case it's still settling, then closes.
        // Not while it's still on its way to the workspace it was opened for:
        // until it claims it, it owns nothing, by design.
        if !isEmbeddedSplit, steers, !awaitingWorkspace, ownWorkspaces.isEmpty,
           registry.windows.contains(where: { $0 !== self && !$0.closing && !$0.isEmbeddedSplit }) {
            let since = emptySince ?? Date()
            emptySince = since
            if Date().timeIntervalSince(since) > 2 {
                closeWindowLater()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.reconcile() }
        } else {
            emptySince = nil
        }
        if let workspaceId, !snapshot.workspaces.contains(where: { $0.workspaceId == workspaceId }) {
            // A split's workspace went (its last tab was dragged out, or it
            // closed): the split closes, and its window keeps its own workspace.
            // Picking another here would take a workspace off whoever owns it,
            // leaving a window that shows tabs and lists no workspaces.
            if isEmbeddedSplit, let parent = splitParent { return parent.closeWorkspaceSplit() }
            // The window's own went but its split's is alive: that one stays,
            // full size.
            if let survivor = splitContext?.focusedWorkspace?.workspaceId,
               snapshot.workspaces.contains(where: { $0.workspaceId == survivor }) {
                closeWorkspaceSplit()
                return steer(toWorkspace: survivor, tab: nil)
            }
            // Its last workspace went (its only tab was dragged out to a window
            // of its own, say) and other windows are open: this one has nothing
            // left to show, so it closes rather than staying open on an
            // arbitrary workspace, or on none.
            if !isEmbeddedSplit, ownWorkspaces.isEmpty,
               registry.windows.contains(where: { $0 !== self && !$0.closing && !$0.isEmbeddedSplit }) {
                closeWindowLater()
                return
            }
            // Its own next, else one no window shows, else any.
            let shown = registry.shownWorkspaceIds(except: self)
            let next = ownWorkspaces.first { $0.workspaceId != workspaceId }
                ?? snapshot.workspaces.first { !shown.contains($0.workspaceId) } ?? snapshot.workspaces[0]
            return steer(toWorkspace: next.workspaceId, tab: nil)
        }
        guard let workspaceId else { return adoptEngineFocus() }
        let tabs = focusedWorkspaceTabs
        if tabId == nil || !tabs.contains(where: { $0.tabId == tabId }), let first = tabs.first {
            let active = snapshot.workspaces.first { $0.workspaceId == workspaceId }?.activeTabId
            tabId = tabs.first { $0.tabId == active }?.tabId ?? first.tabId
        }
    }

    /// The engine's focus moved to `workspace`/`tab`. If this window went
    /// there, that's the arrival; the registry decides otherwise.
    fileprivate func arrived(workspace: String, tab: String?) -> Bool {
        guard let expected, expected.workspace == workspace, expected.tab == nil || expected.tab == tab else { return false }
        self.expected = nil
        if let tab { tabId = tab }
        return true
    }

}

/// Every Octet window, and which one is in front.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()
    @Published private(set) var windows: [WindowContext] = []
    private weak var lastKey: WindowContext?
    private var watch: AnyCancellable?
    private var lastFocus: (workspace: String?, tab: String?)

    var isMulti: Bool { windows.count > 1 }

    // MARK: Which window each workspace belongs to

    /// Workspace id to the window it belongs to. Set when a window shows a
    /// workspace or one is made while a window is in front; a workspace with
    /// none, or whose window closed, goes to the window in front.
    @Published private(set) var homes: [String: UUID] = [:] {
        // Each window's sidebar reads it through the window.
        didSet { if homes != oldValue { windows.forEach { $0.objectWillChange.send() } } }
    }

    /// The window in front among those open, never one that's closing.
    private var front: WindowContext? {
        (lastKey?.isKey == true && lastKey?.closing == false ? lastKey : nil)
            ?? windows.first { $0.isKey && !$0.closing } ?? windows.first { !$0.closing }
    }

    func home(of workspaceId: String) -> WindowContext? {
        guard isMulti, let id = homes[workspaceId] else { return nil }
        return windows.first { $0.id == id && !$0.closing }
    }

    func belongs(_ workspaceId: String, to window: WindowContext) -> Bool {
        guard isMulti else { return true }
        if let home = home(of: workspaceId) { return home === window }
        // One a window is opening for is that window's, not the front one's.
        return !reservations.contains(workspaceId) && front === window
    }

    fileprivate func claim(_ workspaceId: String, for window: WindowContext) {
        reserved[workspaceId] = nil
        guard homes[workspaceId] != window.id else { return }
        homes[workspaceId] = window.id
        save()
    }

    /// Workspaces with no window yet go to the one in front; ones gone are
    /// forgotten.
    private func settleHomes() {
        guard isMulti, let store = windows.first?.store, !store.snapshot.workspaces.isEmpty else { return }
        let live = Set(windows.filter { !$0.closing }.map(\.id))
        let ids = Set(store.snapshot.workspaces.map(\.workspaceId))
        var next = homes.filter { ids.contains($0.key) }
        if let front {
            for id in ids where next[id].map(live.contains) != true && !reservations.contains(id) { next[id] = front.id }
        }
        if next != homes { homes = next }
    }

    /// Saved with each window: the workspaces that were its own, so a
    /// window reopened at launch gets them back.
    private var restoredMembers: [String: [String]] = {
        let saved = UserDefaults.standard.array(forKey: WindowRegistry.savedKey) as? [[String: Any]] ?? []
        var members: [String: [String]] = [:]
        for entry in saved {
            guard let workspace = entry["workspace"] as? String else { continue }
            members[workspace] = entry["members"] as? [String] ?? []
        }
        return members
    }()

    fileprivate func claimRestoredMembers(of workspace: String, for window: WindowContext) {
        guard let members = restoredMembers.removeValue(forKey: workspace) else { return }
        // Its own again, unless another window is showing one of them now.
        for member in members where self.window(showing: member) == nil || member == workspace { homes[member] = window.id }
    }

    // MARK: Restoring across launches
    // macOS brings the windows back, frames and all, but not what each one
    // showed: SwiftUI hands every restored window the default spec. So each
    // window's workspace is kept here with its frame, and a restored window
    // takes the one saved nearest where it reopened.

    private static let savedKey = "octet.windows" + (EngineSession.name == "octet" ? "" : ".\(EngineSession.name)")
    private var restoring: [(workspace: String, split: String?, edge: SplitEdge, tabs: [String]?, frame: CGRect)] = {
        let saved = UserDefaults.standard.array(forKey: WindowRegistry.savedKey) as? [[String: Any]] ?? []
        return saved.compactMap { entry in
            guard let workspace = entry["workspace"] as? String, let frame = entry["frame"] as? String else { return nil }
            return (workspace, entry["splitWorkspace"] as? String,
                    SplitEdge(rawValue: entry["splitEdge"] as? String ?? "") ?? .right,
                    entry["splitTabIDs"] as? [String],
                    NSRectFromString(frame))
        }
    }()
    /// Restoring is for the windows opening at launch; after that it's off.
    private var restoreUntil = Date.distantFuture

    fileprivate func restoredWorkspace(for window: WindowContext) -> String? {
        guard Date() < restoreUntil, !restoring.isEmpty else { return nil }
        let origin = window.nsWindow?.frame.origin ?? .zero
        let index = restoring.indices.min { a, b in
            hypot(restoring[a].frame.minX - origin.x, restoring[a].frame.minY - origin.y)
                < hypot(restoring[b].frame.minX - origin.x, restoring[b].frame.minY - origin.y)
        }!
        let saved = restoring.remove(at: index)
        window.pendingSplitWorkspace = saved.split
        window.pendingSplitEdge = saved.edge
        window.pendingSplitTabIDs = saved.tabs
        return saved.workspace
    }

    /// Set as the app quits: windows closing then are kept for next launch.
    private var terminating = false
    private lazy var terminateWatch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { WindowRegistry.shared.terminating = true } }

    /// Windows macOS didn't bring back (it restores only some, or none when
    /// set to close windows on quit) are reopened where they were, the way
    /// an editor reopens every window it had.
    private func reopenRest() {
        // A restored window still starting up hasn't claimed its entry yet.
        if windows.contains(where: { !$0.askedToRestore }), Date() < restoreUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reopenRest() }
            return
        }
        let rest = restoring
        restoring = []
        guard let store = windows.first?.store else { return }
        var shown = shownWorkspaceIds()
        for entry in rest where !shown.contains(entry.workspace)
            && store.snapshot.workspaces.contains(where: { $0.workspaceId == entry.workspace }) {
            shown.insert(entry.workspace)
            WindowOpener.open?(OctetWindowSpec(workspaceId: entry.workspace,
                                               splitWorkspaceId: entry.split,
                                               splitEdge: entry.edge,
                                               splitTabIDs: entry.tabs, frame: entry.frame))
        }
    }

    func save() {
        _ = terminateWatch
        guard !terminating else { return }
        // While windows are still reopening, what they show isn't settled.
        guard Date() >= restoreUntil || restoring.isEmpty else { return }
        let entries: [[String: Any]] = windows.compactMap { window in
            guard !window.closing, !window.isEmbeddedSplit,
                  let workspace = window.focusedWorkspace?.workspaceId,
                  let frame = window.nsWindow?.frame else { return nil }
            let members = homes.filter { $0.value == window.id }.map(\.key).sorted()
            var entry: [String: Any] = ["workspace": workspace, "frame": NSStringFromRect(frame), "members": members]
            if let split = window.splitContext?.focusedWorkspace?.workspaceId {
                entry["splitWorkspace"] = split
                entry["splitEdge"] = window.splitEdge.rawValue
                if let tabs = window.splitContext?.splitGroupTabIDs {
                    entry["splitTabIDs"] = Array(tabs).sorted()
                }
            }
            return entry
        }
        guard !entries.isEmpty else { return }
        UserDefaults.standard.set(entries, forKey: Self.savedKey)
    }

    /// The window acting now: the key one, else the last that was.
    var key: WindowContext? {
        (lastKey?.isKey == true && lastKey?.closing == false ? lastKey : nil)
            ?? windows.first(where: { $0.isKey && !$0.closing })
            ?? windows.first(where: { !$0.closing })
    }

    func add(_ window: WindowContext) {
        guard !windows.contains(where: { $0 === window }) else { return }
        if restoreUntil == .distantFuture {
            restoreUntil = Date().addingTimeInterval(10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reopenRest() }
        }
        // Going from one window to two: the one already open keeps what the
        // engine shows, which from now on is its own to keep, and every
        // workspace so far is its own; the new window takes only what it's
        // opened for.
        // A workspace the new window is being opened for is never the first's:
        // a tab moved out to a window of its own takes the engine's focus with
        // it, and the first window adopting that would show the same tab as the
        // new one, the two typing into each other.
        var firstKeeps: String?
        var firstEmpty: WindowContext?
        if windows.count == 1 {
            let first = windows[0]
            let reserved = reservations
            if let focus = first.store.focusedWorkspace?.workspaceId, reserved.contains(focus) {
                // Something of its own, else nothing left: it closes.
                if let other = first.store.snapshot.workspaces.first(where: { !reserved.contains($0.workspaceId) }) {
                    firstKeeps = other.workspaceId
                } else {
                    firstEmpty = first
                }
            } else {
                first.adoptEngineFocus()
            }
            for workspace in first.store.snapshot.workspaces
            where homes[workspace.workspaceId] == nil && !reserved.contains(workspace.workspaceId) {
                homes[workspace.workspaceId] = first.id
            }
        }
        windows.append(window)
        if windows.count > 1 { window.adoptEngineFocus() }
        if let keep = firstKeeps { windows[0].steer(toWorkspace: keep, tab: nil) }
        if let empty = firstEmpty {
            // Once the new window is up, so the app always has one open.
            empty.closeWindowLater()
        }
        if watch == nil {
            observe(window.store)
            window.store.processPane = { [weak self] in
                guard let self, self.isMulti else { return nil }
                return self.key?.focusedPaneId
            }
        }
        windows.forEach { $0.objectWillChange.send() }
    }

    func remove(_ window: WindowContext) {
        // Closed by hand, with other windows open: what it showed closes with
        // it, as a browser window's tabs do, rather than turning up again in
        // the window it was torn off from. Running work is asked about first;
        // kept, it goes to the window in front below.
        let owned = homes.filter { $0.value == window.id }.map(\.key)
        let closesItsWorkspaces = window.closing && !window.mergingAway && !terminating
            && !window.isEmbeddedSplit && windows.contains(where: { $0 !== window && !$0.closing })
        windows.removeAll { $0 === window }
        if closesItsWorkspaces, !owned.isEmpty, let store = windows.first?.store {
            let live = Set(store.snapshot.workspaces.map(\.workspaceId))
            let closing = owned.filter(live.contains)
            let panes = store.snapshot.panes.filter { closing.contains($0.workspaceId) }
            if !closing.isEmpty {
                store.confirmClosing(panes, place: closing.count == 1 ? "workspace" : "window") {
                    closing.forEach { store.closeWorkspaceOnly($0) }
                }
            }
        }
        if lastKey === window { lastKey = window.splitParent ?? windows.first(where: { !$0.closing }) }
        // Its workspaces go to the window in front, where they're listed.
        if let front {
            for (workspace, id) in homes where id == window.id { homes[workspace] = front.id }
        }
        // A window closed by hand is gone next launch too; quitting keeps all.
        if window.closing { save() }
        // Back to one: its view becomes the engine's focus again.
        if windows.count == 1, let last = windows.first, let workspace = last.workspaceId {
            if let tab = last.tabId, let found = last.store.snapshot.tabs.first(where: { $0.tabId == tab }) {
                last.store.focusTabAnywhere(found)
            } else {
                last.store.focusWorkspace(workspace)
            }
        }
        windows.forEach { $0.objectWillChange.send() }
    }

    func becameKey(_ window: WindowContext) {
        let changed = lastKey !== window
        lastKey = window
        if changed { save() }
        // What the new key window's pane runs decides how its keys are read.
        if changed, isMulti { window.store.refresh() }
    }

    func window(showing workspaceId: String) -> WindowContext? {
        guard isMulti else { return nil }
        return windows.first { $0.workspaceId == workspaceId }
    }

    func shownWorkspaceIds(except window: WindowContext? = nil) -> Set<String> {
        Set(windows.filter { $0 !== window }.compactMap(\.workspaceId)).union(reservations)
    }

    /// Workspaces a window is being opened for, from when it's asked for
    /// until it claims one (or a few seconds pass). Until then they count
    /// as shown: the window in front mustn't follow the engine's focus into
    /// one, or both windows would show it, typing into each other.
    private var reserved: [String: Date] = [:]

    private var reservations: Set<String> {
        Set(reserved.filter { Date().timeIntervalSince($0.value) < 5 }.keys)
    }

    func reserve(_ workspaceId: String) {
        reserved[workspaceId] = Date()
    }

    /// Tabs on screen in any window: agents there aren't news.
    var shownTabIds: Set<String> {
        isMulti ? Set(windows.compactMap(\.tabId)) : Set([windows.first?.store.displayedFocusedTabId].compactMap { $0 })
    }

    private func observe(_ store: SessionStore) {
        watch = store.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.snapshotChanged() }
        }
    }

    /// With windows steering themselves, each new snapshot is checked: a
    /// window whose tab closed moves on, and a focus change no window asked
    /// for was made in the engine itself, in the window in front.
    private func snapshotChanged() {
        windows.forEach { $0.goToPendingWorkspace() }
        // A workspace can also disappear through a sidebar action or another
        // client. Repair the physical split before either surface reconciles
        // onto its sibling's workspace.
        if let store = windows.first?.store {
            let live = Set(store.snapshot.workspaces.map(\.workspaceId))
            for root in windows.filter({ !$0.isEmbeddedSplit }) {
                guard let child = root.splitContext else { continue }
                if let group = child.splitGroupTabIDs, child.workspaceId == root.workspaceId,
                   let workspaceId = root.workspaceId {
                    let tabs = store.snapshot.tabs(inWorkspace: workspaceId)
                    let childTabs = tabs.filter { group.contains($0.tabId) }
                    if childTabs.isEmpty {
                        root.closeWorkspaceSplit()
                    } else if !tabs.contains(where: { !group.contains($0.tabId) }) {
                        let survivor = child.tabId.flatMap { id in childTabs.first { $0.tabId == id }?.tabId }
                            ?? childTabs[0].tabId
                        root.closeWorkspaceSplit()
                        root.steer(toWorkspace: workspaceId, tab: survivor)
                    }
                    continue
                }
                if let id = child.workspaceId, !live.contains(id), !child.awaitingWorkspace {
                    root.closeWorkspaceSplit()
                } else if let id = root.workspaceId, !live.contains(id), !root.awaitingWorkspace,
                          let survivor = child.workspaceId, live.contains(survivor) {
                    root.closeWorkspaceSplit()
                    root.focusWorkspace(survivor)
                }
            }
        }
        settleHomes()
        guard isMulti, let store = windows.first?.store else { return }
        windows.forEach { $0.reconcile() }
        let focus = (store.snapshot.focusedWorkspaceId, store.snapshot.focusedTabId)
        defer { lastFocus = focus }
        guard focus.0 != lastFocus.workspace || focus.1 != lastFocus.tab, let workspace = focus.0 else { return }
        if windows.contains(where: { $0.arrived(workspace: workspace, tab: focus.1) }) { return }
        guard let key, key.workspaceId == workspace || !shownWorkspaceIds(except: key).contains(workspace) else { return }
        key.workspaceId = workspace
        if let tab = focus.1 { key.tabId = tab }
    }
}
