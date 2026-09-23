import AppKit
import Combine
import SwiftUI

/// What an Octet window is opened with, and restored with across launches.
struct OctetWindowSpec: Codable, Hashable {
    var id = UUID()
    /// The workspace the window was opened for; nil shows whatever the
    /// engine has in front.
    var workspaceId: String?
    /// Where the window goes, in screen coordinates, when a tab was dropped
    /// there to make it.
    var origin: CGPoint?
    /// The whole frame, for a window reopened where it was last session.
    var frame: CGRect?
}

/// One Octet window: its own engine client, and what that client shows.
///
/// With one window, every member here forwards to `SessionStore` exactly as
/// Octet has always worked: the engine's focus is the window's. With more,
/// each window keeps its own workspace and tab and is moved by its own keys
/// (`EngineNavigation`), because the engine's API focus calls move every
/// client at once. Members are named after the store's, so the chrome reads
/// `window.focusedWorkspace` where it read `store.focusedWorkspace`.
@MainActor
final class WindowContext: ObservableObject, Identifiable {
    let id: UUID
    let store: SessionStore
    let ui = UIState()
    let editor = EditorWorkspace()
    private(set) lazy var twin = TwinSession(window: self)
    weak var nsWindow: NSWindow?
    /// This window's terminal, the only way to move this window's client.
    weak var surface: TerminalEngine.SurfaceView?
    private var outputSearch: OutputSearch?

    func findOutput(_ action: NSTextFinder.Action = .showFindInterface) {
        if let outputSearch, outputSearch.window?.parent != nil {
            if action != .showFindInterface || outputSearch.paneId == focusedPaneId {
                outputSearch.find(action)
                return
            }
            outputSearch.dismiss()
        }
        guard action == .showFindInterface, let nsWindow, nsWindow.attachedSheet == nil,
              let paneId = focusedPaneId,
              AgentCenter.shared.active(in: focusedWorkspace?.workspaceId) == nil else { return }
        let search = OutputSearch(client: store.client, paneId: paneId)
        outputSearch = search
        search.present(on: nsWindow)
    }
    /// Set as the window closes. Its engine client exits then, and that must
    /// not read as the engine going away, which quits the app.
    var closing = false

    /// With more than one window: the workspace and tab this client shows.
    @Published private(set) var workspaceId: String?
    @Published private(set) var tabId: String?
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
    private var visualTabOrder: [String] = []

    func orderedVisualTabs(_ ids: [String]) -> [String] {
        visualTabOrder = visualTabOrder.filter(ids.contains)
            + ids.filter { !visualTabOrder.contains($0) }
        return visualTabOrder
    }
    /// Empty terminal tabs retained only to keep a conversation's workspace
    /// alive. The tab bar hides them until the conversation closes or the
    /// person explicitly asks for a terminal.
    @Published private var conversationBackingTabs: [String: String] = [:]
    /// A workspace to go to as soon as the client can be moved: a window made
    /// for a tab, or restored, opens wherever the engine was and is then sent.
    private var pendingWorkspace: String?
    /// Where this window last sent its client, until the snapshot shows it
    /// arrived: tells an arrival apart from a move made in the engine itself.
    fileprivate var expected: (workspace: String, tab: String?)?
    private var watch: AnyCancellable?
    private var editorWatch: AnyCancellable?

    init(spec: OctetWindowSpec, store: SessionStore) {
        id = spec.id
        self.store = store
        pendingWorkspace = spec.workspaceId
        // The chrome reads through here, so a store change is a change here.
        watch = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        editorWatch = editor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
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
        return store.snapshot.tabs(inWorkspace: workspaceId)
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

    // MARK: - Moving this window

    func focusTab(_ id: String) {
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
        if let other = registry.window(showing: id), other !== self { return other.bringForward() }
        steer(toWorkspace: id, tab: nil)
    }

    func focusTabAnywhere(_ tab: EngineTab) {
        guard steers else { return store.focusTabAnywhere(tab) }
        if let other = registry.window(showing: tab.workspaceId), other !== self {
            other.bringForward()
            return other.steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
        }
        steer(toWorkspace: tab.workspaceId, tab: tab.tabId)
    }

    /// A banner's pane: its tab, in whichever window has its workspace.
    func focusAgent(paneId: String) {
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
        guard steers else { return store.selectTab(number: number) }
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        focusTab(tabs[index].tabId)
    }

    func selectAdjacentTab(offset: Int) {
        guard steers else { return store.selectAdjacentTab(offset: offset) }
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.tabId == tabId } ?? 0
        focusTab(tabs[(current + offset + tabs.count) % tabs.count].tabId)
    }

    /// Next or previous workspace in sidebar order, passing over any another
    /// window already shows.
    func selectAdjacentWorkspace(offset: Int) {
        guard steers else { return store.selectAdjacentWorkspace(offset: offset) }
        let shownElsewhere = registry.shownWorkspaceIds(except: self)
        let ordered = (store.activeGroups.flatMap(\.workspaces) + store.idleWorkspaces)
            .filter { $0.workspaceId == workspaceId || !shownElsewhere.contains($0.workspaceId) }
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.workspaceId == workspaceId } ?? 0
        focusWorkspace(ordered[(current + offset + ordered.count) % ordered.count].workspaceId)
    }

    // MARK: - Making things in this window

    /// Something made through the API with `focus: false`, then this window
    /// sent to it: with more than one window, `focus: true` would move them all.
    private func create(_ method: String, _ params: [String: Any], failure: String) {
        var params = params
        params["focus"] = false
        store.call(method, params, failure: failure) { [weak self] created in
            guard let self, let workspace = created.workspaceId ?? self.workspaceId else { return }
            self.steer(toWorkspace: workspace, tab: created.tabId)
        }
    }

    func newTab() {
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

    func newTab(running agent: DiscoveredAgent) {
        editor.dismiss()
        guard steers else { return store.newTab(running: agent) }
        guard let params = store.agentTabParams(agent, workspaceId: workspaceId) else { return }
        create("layout.apply", params, failure: "Couldn't open \(agent.displayName) in a tab")
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
        create("worktree.create", params, failure: "Couldn't create worktree \(branch)")
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
        var params: [String: Any] = ["direction": direction.rawValue, "target_pane_id": pane, "focus": false]
        if let workspaceId, let cwd = store.snapshot.directory(ofWorkspace: workspaceId) { params["cwd"] = cwd }
        // Then into the new pane, by this window's own pane keys.
        store.call("pane.split", params, failure: "Couldn't split pane") { [weak self] _ in
            self?.send([EngineNavigation.prefix, EngineNavigation.Stroke(key: direction == .right ? "l" : "j")])
        }
    }

    func focusPane(_ direction: SessionStore.PaneDirection) {
        guard steers else { return store.focusPane(direction) }
        let key = ["left": "h", "down": "j", "up": "k", "right": "l"][direction.rawValue] ?? "l"
        send([EngineNavigation.prefix, EngineNavigation.Stroke(key: key)])
    }

    func toggleZoom() {
        guard steers else { return store.toggleZoom() }
        guard let pane = focusedPaneId else { return }
        store.call("pane.zoom", ["pane_id": pane, "mode": "toggle"], failure: "Couldn't zoom the pane") { _ in }
    }

    func closeFocusedPane() {
        guard steers else { return store.closeFocusedPane() }
        guard let pane = focusedPaneId else { return }
        store.call("pane.close", ["pane_id": pane], failure: "Couldn't close pane") { _ in }
    }

    func closeFocusedTab() {
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
    func closeTab(_ id: String) {
        guard steers else { return store.closeTab(id) }
        if id == tabId {
            let tabs = displayedTabs
            if let index = tabs.firstIndex(where: { $0.tabId == id }), tabs.count > 1 {
                tabId = tabs[index > 0 ? index - 1 : 1].tabId
            }
        }
        store.closeTab(id)
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

    func newConversation(engine: AgentSession.Engine = .claude, cwd: String? = nil,
                         replacingStarterTab starterTabId: String? = nil) {
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
        AgentCenter.shared.setActive(nil, in: focusedWorkspace?.workspaceId)
        AgentCenter.shared.setBoard(nil, in: focusedWorkspace?.workspaceId)
        twin.hide()
        editor.open(url, presentation: presentation)
        DebugSnapshot.overlay("editor", editor.isPresented)
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

    /// ⌘⇧A: this window's agents board, for the agent in its tab.
    func toggleAgentsBoard() {
        let center = AgentCenter.shared
        let workspace = focusedWorkspace?.workspaceId
        if center.board(in: workspace) != nil { return center.setBoard(nil, in: workspace) }
        let agent = displayedFocusedTabId.flatMap { store.primaryAgent(in: store.snapshot.agents(inTab: $0)) }
        center.setBoard(AgentBrand.forAgent(agent?.agent)?.id == "codex" ? .codex : .claude, in: workspace)
    }

    // MARK: - Steering

    /// Sends this window's client the keys to `workspace`, and to `tab` in it
    /// when given (else the tab the engine last showed there). Positions are
    /// what the engine's keys count: the order of the snapshot's lists.
    func steer(toWorkspace workspace: String, tab: String?) {
        let workspaces = store.snapshot.workspaces
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.workspaceId == workspace }) else { return }
        // Jumps are absolute, so a stale idea of where the client is can't
        // send it wrong.
        var strokes = EngineNavigation.toWorkspace(from: nil, to: workspaceIndex)
        if let tab, let tabIndex = store.snapshot.tabs(inWorkspace: workspace).firstIndex(where: { $0.tabId == tab }) {
            strokes += EngineNavigation.toTab(from: nil, to: tabIndex)
        }
        workspaceId = workspace
        tabId = tab ?? store.snapshot.workspaces[workspaceIndex].activeTabId
        expected = (workspace, tab)
        send(strokes)
    }

    fileprivate func send(_ strokes: [EngineNavigation.Stroke]) {
        guard let model = surface?.surfaceModel else { return }
        for stroke in strokes {
            guard let key = TerminalEngine.Input.Key(rawValue: stroke.key) else { continue }
            var mods: TerminalEngine.Input.Mods = []
            if stroke.ctrl { mods.insert(.ctrl) }
            if stroke.alt { mods.insert(.alt) }
            model.sendKeyEvent(.init(key: key, action: .press, text: stroke.text, mods: mods, unshiftedCodepoint: stroke.codepoint))
            model.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: stroke.codepoint))
        }
    }

    func bringForward() {
        nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Keeping up with the engine

    /// Starts this window on what the engine shows, or on the workspace it
    /// was opened for once its client is up.
    fileprivate func adoptEngineFocus() {
        workspaceId = store.focusedWorkspace?.workspaceId
        tabId = store.displayedFocusedTabId
    }

    /// The client has drawn its first frame: it can take keys now.
    func clientReady() {
        clientIsReady = true
        goToPendingWorkspace()
    }

    private var clientIsReady = false
    fileprivate private(set) var askedToRestore = false

    /// Goes where the window was opened for once both its client and the
    /// engine's snapshot are up; at launch the client can draw first.
    fileprivate func goToPendingWorkspace() {
        guard clientIsReady else { return }
        if !askedToRestore {
            askedToRestore = true
            if pendingWorkspace == nil { pendingWorkspace = registry.restoredWorkspace(for: self) }
        }
        guard let workspace = pendingWorkspace else { return }
        let workspaces = store.snapshot.workspaces
        guard !workspaces.isEmpty else { return }
        pendingWorkspace = nil
        // A restored window's workspace may be gone: it keeps what it shows.
        guard workspaces.contains(where: { $0.workspaceId == workspace }) else { return }
        if steers { steer(toWorkspace: workspace, tab: nil) } else { store.focusWorkspace(workspace) }
    }

    /// Checks this window against a new snapshot: a tab or workspace it shows
    /// that closed is replaced by a neighbour, and the engine is told.
    fileprivate func reconcile() {
        let snapshot = store.snapshot
        guard !snapshot.workspaces.isEmpty else { return }
        if let workspaceId, !snapshot.workspaces.contains(where: { $0.workspaceId == workspaceId }) {
            let shown = registry.shownWorkspaceIds(except: self)
            let next = snapshot.workspaces.first { !shown.contains($0.workspaceId) } ?? snapshot.workspaces[0]
            return steer(toWorkspace: next.workspaceId, tab: nil)
        }
        guard let workspaceId else { return adoptEngineFocus() }
        let tabs = snapshot.tabs(inWorkspace: workspaceId)
        if tabId == nil || !tabs.contains(where: { $0.tabId == tabId }), let first = tabs.first {
            let active = snapshot.workspaces.first { $0.workspaceId == workspaceId }?.activeTabId
            tabId = tabs.first { $0.tabId == active }?.tabId ?? first.tabId
        }
    }

    /// The engine's focus moved to `workspace`/`tab`. If this window sent
    /// its client there, that's the arrival; the registry decides otherwise.
    fileprivate func arrived(workspace: String, tab: String?) -> Bool {
        guard let expected, expected.workspace == workspace, expected.tab == nil || expected.tab == tab else { return false }
        self.expected = nil
        if let tab { tabId = tab }
        return true
    }

    /// A move made inside this window's client, with the engine's own keys.
    fileprivate func followEngine(workspace: String, tab: String?) {
        workspaceId = workspace
        if let tab { tabId = tab }
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

    // MARK: Restoring across launches
    // macOS brings the windows back, frames and all, but not what each one
    // showed: SwiftUI hands every restored window the default spec. So each
    // window's workspace is kept here with its frame, and a restored window
    // takes the one saved nearest where it reopened.

    private static let savedKey = "octet.windows"
    private var restoring: [(workspace: String, frame: CGRect)] = {
        let saved = UserDefaults.standard.array(forKey: WindowRegistry.savedKey) as? [[String: Any]] ?? []
        return saved.compactMap { entry in
            guard let workspace = entry["workspace"] as? String, let frame = entry["frame"] as? String else { return nil }
            return (workspace, NSRectFromString(frame))
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
        return restoring.remove(at: index).workspace
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
            WindowOpener.open?(OctetWindowSpec(workspaceId: entry.workspace, frame: entry.frame))
        }
    }

    func save() {
        _ = terminateWatch
        guard !terminating else { return }
        // While windows are still reopening, what they show isn't settled.
        guard Date() >= restoreUntil || restoring.isEmpty else { return }
        let entries: [[String: Any]] = windows.compactMap { window in
            guard !window.closing, let workspace = window.focusedWorkspace?.workspaceId,
                  let frame = window.nsWindow?.frame else { return nil }
            return ["workspace": workspace, "frame": NSStringFromRect(frame)]
        }
        guard !entries.isEmpty else { return }
        UserDefaults.standard.set(entries, forKey: Self.savedKey)
    }

    /// The window acting now: the key one, else the last that was.
    var key: WindowContext? {
        windows.first(where: \.isKey) ?? lastKey ?? windows.first
    }

    func add(_ window: WindowContext) {
        guard !windows.contains(where: { $0 === window }) else { return }
        if restoreUntil == .distantFuture {
            restoreUntil = Date().addingTimeInterval(10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reopenRest() }
        }
        // Going from one window to two: the one already open keeps what the
        // engine shows, which from now on is its own to keep.
        if windows.count == 1 { windows[0].adoptEngineFocus() }
        windows.append(window)
        if windows.count > 1 { window.adoptEngineFocus() }
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
        windows.removeAll { $0 === window }
        // A window closed by hand is gone next launch too; quitting keeps all.
        if window.closing { save() }
        // Back to one: its view becomes the engine's focus again, and the
        // API is safe to use, with only one client to move.
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
        save()
        // What the new key window's pane runs decides how its keys are read.
        if changed, isMulti { window.store.refresh() }
    }

    func window(showing workspaceId: String) -> WindowContext? {
        guard isMulti else { return nil }
        return windows.first { $0.workspaceId == workspaceId }
    }

    func shownWorkspaceIds(except window: WindowContext? = nil) -> Set<String> {
        Set(windows.filter { $0 !== window }.compactMap(\.workspaceId))
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
        guard isMulti, let store = windows.first?.store else { return }
        windows.forEach { $0.reconcile() }
        let focus = (store.snapshot.focusedWorkspaceId, store.snapshot.focusedTabId)
        defer { lastFocus = focus }
        guard focus.0 != lastFocus.workspace || focus.1 != lastFocus.tab, let workspace = focus.0 else { return }
        if windows.contains(where: { $0.arrived(workspace: workspace, tab: focus.1) }) { return }
        guard let key, key.workspaceId == workspace || !shownWorkspaceIds(except: key).contains(workspace) else { return }
        key.followEngine(workspace: workspace, tab: focus.1)
    }
}
