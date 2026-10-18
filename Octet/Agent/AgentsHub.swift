import SwiftUI

/// One agent, wherever it runs: a conversation in Octet, an agent in a
/// terminal tab (a cloud session is one of these), or a background session
/// Claude Code or Codex runs on its own.
struct HubAgent: Identifiable {
    enum Place: String, CaseIterable, Identifiable {
        case chat, terminal, background, cloud
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chat: "Chat"
            case .terminal: "Terminal"
            case .background: "Background"
            case .cloud: "Cloud"
            }
        }
        var icon: String {
            switch self {
            case .chat: "text.bubble"
            case .terminal: "terminal"
            case .background: "clock"
            case .cloud: "cloud"
            }
        }
    }

    enum Status: Int, Comparable, CaseIterable {
        case needsInput, working, done
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        /// The pill's word for it.
        var title: String {
            switch self {
            case .needsInput: "Needs input"
            case .working: "Working"
            case .done: "Done"
            }
        }

        /// The shelf's, after T3 Code's inbox: what needs you, what's
        /// moving, and what has settled.
        var shelf: String {
            switch self {
            case .needsInput: "Needs input"
            case .working: "Working"
            case .done: "Settled"
            }
        }

        var icon: String {
            switch self {
            case .needsInput: "message"
            case .working: "clock.arrow.circlepath"
            case .done: "circle.check"
            }
        }

        var color: Color {
            switch self {
            case .needsInput: HubStyle.waiting
            case .working: Theme.accent
            case .done: Color(hex: AgentStateColor.done)
            }
        }
    }

    /// Where a click goes.
    enum Target {
        case chat(AgentSession)
        case terminal(EngineTab)
        case claudeBackground(BackgroundAgent)
        case codexBackground(BackgroundAgent)
    }

    let id: String
    /// The agent's id, for its mark: "claude", "codex", …
    let vendor: String?
    let title: String
    /// What it last said or did, as one line.
    let detail: String?
    let place: Place
    let status: Status
    let cwd: String?
    let date: Date?
    let target: Target
    /// The workspace it belongs to, by name, when it has one.
    var workspace: String? = nil
    /// Its tab's name, for a terminal agent.
    var tab: String? = nil
    /// The terminal it runs in, for its context usage.
    var terminalId: String? = nil

    var opensInPlace: Bool {
        switch target {
        case .chat, .terminal: true
        case .claudeBackground, .codexBackground: false
        }
    }

    /// "workspace · tab", or the folder when it has no workspace.
    var location: String? {
        let parts = [workspace, tab].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return cwd.map(abbreviateHome)
    }

    var brandName: String? { AgentBrand.forAgent(vendor)?.displayName ?? vendor }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, detail, workspace, tab, cwd, brandName, place.title].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
extension HubAgent {
    /// Whether it can be stopped from the hub: a chat mid-turn, or a Claude
    /// background session still running.
    var canStop: Bool {
        switch target {
        case .chat(let session): session.conversation.isRunning
        case .claudeBackground(let agent): agent.kind == .background && (agent.state == .working || agent.state == .needsInput)
        case .terminal, .codexBackground: false
        }
    }

    func stop() {
        switch target {
        case .chat(let session): session.interrupt()
        case .claudeBackground(let agent): AgentsStore.shared.stop(agent)
        case .terminal, .codexBackground: break
        }
    }
}

/// Every agent from every source, for the hub and the Agents button.
@MainActor
enum AgentsHubList {
    static func agents(store: SessionStore) -> [HubAgent] {
        chats(store: store) + terminals(store: store) + claudeBackground() + codexBackground()
    }

    /// How many are waiting on you, across all of them.
    static func waitingCount(store: SessionStore) -> Int {
        agents(store: store).filter { $0.status == .needsInput }.count
    }

    private static func chats(store: SessionStore) -> [HubAgent] {
        let workspaces = store.snapshot.workspaces
        return AgentCenter.shared.sessions.map { session in
            let status: HubAgent.Status = session.pendingPermission != nil || session.pendingQuestion != nil ? .needsInput
                : session.conversation.isRunning ? .working : .done
            return HubAgent(id: "chat:" + session.id, vendor: session.engine.agent, title: session.title,
                            detail: lastText(session.conversation), place: .chat, status: status,
                            cwd: session.cwd, date: nil, target: .chat(session),
                            workspace: workspaces.first { $0.workspaceId == session.workspaceId }?.label)
        }
    }

    private static func terminals(store: SessionStore) -> [HubAgent] {
        let snapshot = store.snapshot
        let activity = store.usageTracker.lastActivity
        return snapshot.agents.compactMap { agent -> HubAgent? in
            guard agent.agent != nil, !agent.isSubagentViewer, let tabId = agent.tabId,
                  let tab = snapshot.tabs.first(where: { $0.tabId == tabId }) else { return nil }
            let status: HubAgent.Status = switch agent.agentStatus {
            case .blocked: .needsInput
            case .working: .working
            default: .done
            }
            let label = TabAutoName.display(label: tab.label, number: tab.number)
            let workspace = snapshot.workspaces.first { $0.workspaceId == tab.workspaceId }?.label
            return HubAgent(id: "pane:" + agent.paneId, vendor: AgentBrand.forAgent(agent.agent)?.id ?? agent.agent,
                            title: label, detail: agent.terminalId.flatMap { activity[$0] },
                            place: label.hasPrefix("☁") ? .cloud : .terminal, status: status,
                            cwd: agent.effectiveCwd, date: nil, target: .terminal(tab),
                            workspace: workspace, terminalId: agent.terminalId)
        }
    }

    private static func claudeBackground() -> [HubAgent] {
        let store = AgentsStore.shared
        return store.agents.filter { $0.kind == .background }.map { agent in
            HubAgent(id: "claude-bg:" + agent.sessionId, vendor: "claude", title: agent.name,
                     detail: store.lastLines[agent.sessionId], place: .background, status: status(agent),
                     cwd: agent.cwd, date: agent.startedAt, target: .claudeBackground(agent))
        }
    }

    private static func codexBackground() -> [HubAgent] {
        let store = CodexAgentsStore.shared
        // Codex's own sessions that Octet isn't already showing as a chat.
        let chatThreads = Set(AgentCenter.shared.sessions.compactMap { $0.engine == .codex ? $0.threadId : nil })
        return store.agents.filter { !chatThreads.contains($0.id) }.map { agent in
            HubAgent(id: "codex-bg:" + agent.id, vendor: "codex", title: agent.name,
                     detail: store.previews[agent.id].flatMap { $0.isEmpty ? nil : $0 }, place: .background,
                     status: status(agent), cwd: agent.cwd, date: agent.startedAt, target: .codexBackground(agent))
        }
    }

    static func status(_ agent: BackgroundAgent) -> HubAgent.Status {
        switch agent.state {
        case .needsInput: .needsInput
        case .working: .working
        case .done, .idle: .done
        }
    }

    /// The last thing the agent wrote, as one line.
    private static func lastText(_ conversation: AgentConversation) -> String? {
        for item in conversation.items.reversed() {
            if case .text(let text) = item.kind, !text.isEmpty { return plainPreview(text) }
        }
        return nil
    }
}

enum HubStyle {
    /// Amber, as on the Agents button's count.
    static let waiting = Color(hex: "FFC107")
    static let listDefaultWidth: CGFloat = 400
    static let listMinWidth: CGFloat = 360
}

/// Every agent in one place, after T3 Code's inbox: a list on the left
/// shelved by what needs you (waiting on an answer, working, settled), and
/// the chosen agent on the right. Chats and terminal agents open where they
/// run; a background session shows its transcript here. A task can start
/// from here in the background or the cloud.
struct AgentsHub: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var claude = AgentsStore.shared
    @ObservedObject private var codex = CodexAgentsStore.shared
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var tracker: AgentUsageTracker
    @StateObject private var dropdowns = OctetDropdownState()
    @State private var selected: String?
    @State private var filter: HubAgent.Place?
    @State private var vendorFilter: String?
    @State private var query = ""
    @State private var showsAllDone = false
    @State private var task = ""
    @State private var taskVendor = "claude"
    @State private var taskPlace: HubAgent.Place = .background
    @AppStorage("agentsHub.listWidth") private var listWidth = Double(HubStyle.listDefaultWidth)
    @FocusState private var listFocused: Bool
    private static let doneShown = 12

    init(store: SessionStore) {
        self.store = store
        _tracker = ObservedObject(wrappedValue: store.usageTracker)
    }

    var body: some View {
        let all = AgentsHubList.agents(store: store)
        let shelves = shelves(of: all)
        let current = all.first { $0.id == selected }
        GeometryReader { proxy in
            HStack(spacing: 0) {
                list(all: all, shelves: shelves)
                    .frame(width: width(in: proxy.size.width))
                    .zIndex(1)
                Rectangle().fill(Theme.divider).frame(width: 1)
                    .overlay { HubResizeHandle(width: $listWidth, total: proxy.size.width) }
                    .zIndex(2)
                detailPane(current, any: !all.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Theme.terminalBackground)
        .octetDropdownHost(dropdowns)
        .onExitCommand {
            // Esc closes a menu, then clears a search, then leaves.
            if dropdowns.openId != nil { dropdowns.openId = nil } else if !query.isEmpty { query = "" } else { close() }
        }
        .onAppear {
            if selected == nil { selected = shelves.flatMap(\.agents).first?.id }
            if !installed(taskVendor), let first = vendors.first { taskVendor = first }
            listFocused = true
            #if DEBUG
            applyDebugOptions()
            #endif
        }
        .onChange(of: query) { _, _ in keepSelectionVisible() }
        .onChange(of: filter) { _, _ in keepSelectionVisible() }
        .onChange(of: vendorFilter) { _, _ in keepSelectionVisible() }
    }

    private func width(in total: CGFloat) -> CGFloat {
        let most = max(HubStyle.listMinWidth, min(640, total * 0.6))
        return min(most, max(HubStyle.listMinWidth, CGFloat(listWidth)))
    }

    // MARK: - Shelves

    private struct Shelf: Identifiable {
        let status: HubAgent.Status
        /// The rows shown; Settled may hold back its older ones.
        let agents: [HubAgent]
        let total: Int
        var id: Int { status.rawValue }
    }

    private func shown(_ all: [HubAgent]) -> [HubAgent] {
        all.filter { agent in
            (filter == nil || agent.place == filter)
                && (vendorFilter == nil || agent.vendor == vendorFilter)
                && agent.matches(query)
        }
    }

    private func shelves(of all: [HubAgent]) -> [Shelf] {
        let shown = shown(all)
        return HubAgent.Status.allCases.compactMap { status in
            var agents = shown.filter { $0.status == status }
            guard !agents.isEmpty else { return nil }
            let total = agents.count
            if status == .done {
                agents.sort { ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture) }
                if !showsAllDone { agents = Array(agents.prefix(Self.doneShown)) }
            }
            return Shelf(status: status, agents: agents, total: total)
        }
    }

    /// The rows in the order they're drawn, for ↑ and ↓.
    private var ordered: [HubAgent] { shelves(of: AgentsHubList.agents(store: store)).flatMap(\.agents) }

    private func step(_ offset: Int) {
        let rows = ordered
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == selected }) else {
            selected = (offset > 0 ? rows.first : rows.last)?.id
            return
        }
        selected = rows[min(rows.count - 1, max(0, index + offset))].id
    }

    /// A search or filter that hides the chosen agent moves the choice to
    /// the first one still showing.
    private func keepSelectionVisible() {
        let rows = ordered
        if !rows.contains(where: { $0.id == selected }) { selected = rows.first?.id }
    }

    // MARK: - List

    private func list(all: [HubAgent], shelves: [Shelf]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(crumbs: crumbs(all), dropdowns: dropdowns, close: close) {
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh") {
                    claude.refresh()
                    codex.refresh()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                OctetTextField(placeholder: "Search agents", text: $query) {
                    if let agent = all.first(where: { $0.id == selected }) { focus(agent) }
                }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                OctetSegmented(selection: $filter,
                               items: [(nil, "All")] + HubAgent.Place.allCases.map { (Optional($0), $0.title) })
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            rows(all: all, shelves: shelves)
            Rectangle().fill(Theme.divider).frame(height: 1)
            composer
        }
        .background(Theme.sidebar)
    }

    /// "Agents / All agents": the second crumb narrows to one vendor.
    private func crumbs(_ all: [HubAgent]) -> [Breadcrumb] {
        let present = Set(all.compactMap(\.vendor)).union(vendors)
        let ids = present.sorted { UsagePalette.order($0) < UsagePalette.order($1) }
        let options = [OctetDropdownOption(id: Self.allVendors, title: "All agents")]
            + ids.map { OctetDropdownOption(id: $0, title: AgentBrand.forAgent($0)?.displayName ?? $0) }
        let mark = vendorFilter.flatMap(AgentBrand.forAgent).map { AnyView(AgentLogo(brand: $0, size: 13)) }
        let label = vendorFilter.map { AgentBrand.forAgent($0)?.displayName ?? $0 } ?? "All agents"
        return [.title("Agents"),
                .picker(spec: OctetDropdownSpec(id: "agents.vendor", options: options, selected: vendorFilter ?? Self.allVendors) { id in
                    vendorFilter = id == Self.allVendors ? nil : id
                }, label: label, mark: mark)]
    }

    private static let allVendors = "all"

    @ViewBuilder
    private func rows(all: [HubAgent], shelves: [Shelf]) -> some View {
        let errors = [claude.lastError, codex.lastError].compactMap { $0 }
        if shelves.isEmpty {
            VStack(spacing: 0) {
                if all.isEmpty {
                    HubEmptyState(icon: "sparkle", title: "No agents yet",
                                  message: "Describe a task below to start one in the background, or open an agent from the + menu.")
                } else {
                    HubEmptyState(icon: "magnifyingglass", title: "No agents match",
                                  message: "Nothing here fits the search and filters.") {
                        OctetButton(title: "Clear Filters", kind: .secondary, compact: true) {
                            query = ""
                            filter = nil
                            vendorFilter = nil
                        }
                    }
                }
                ForEach(errors, id: \.self) { error in errorLine(error) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shelves) { shelf in
                            OctetShelfHeader(icon: shelf.status.icon, title: shelf.status.shelf, count: shelf.total,
                                             tint: shelf.status == .done ? nil : shelf.status.color)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(shelf.agents) { agent in
                                HubRow(agent: agent, selected: selected == agent.id,
                                       focus: { focus(agent) }, stop: { agent.stop() })
                                    .id(agent.id)
                                    .onTapGesture {
                                        // The second click of a double-click
                                        // goes to it; the first just shows it.
                                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { focus(agent) } else { select(agent) }
                                    }
                            }
                            if shelf.status == .done, shelf.total > Self.doneShown {
                                OctetButton(title: showsAllDone ? "Show fewer" : "Show all \(shelf.total)", kind: .ghost, compact: true) {
                                    motion.perform(.sidebar) { showsAllDone.toggle() }
                                }
                                .padding(.leading, 4)
                                .padding(.top, 4)
                            }
                        }
                        ForEach(errors, id: \.self) { error in errorLine(error) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .octetScrollIndicators()
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.return) {
                    guard let agent = all.first(where: { $0.id == selected }) else { return .ignored }
                    focus(agent)
                    return .handled
                }
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func errorLine(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            OctetIcon("exclamationmark.triangle.fill", size: 11)
            Text(error).font(Theme.captionFont).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - New task

    private var vendors: [String] { ["claude", "codex"].filter(installed) }

    private func installed(_ id: String) -> Bool {
        discovery.agents.contains { $0.id == id && $0.executablePath != nil }
    }

    /// Starts an agent on a task: T3 Code's composer, at the foot of the
    /// list. Claude Code runs in the background or the cloud; Codex in the
    /// background.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OctetTextField(placeholder: vendors.isEmpty ? "Install Claude Code or Codex to start tasks here"
                                                            : "Describe a task for a new agent", text: $task) { start() }
                OctetButton(title: "Start", icon: "arrow.up", kind: .primary, compact: true) { start() }
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || vendors.isEmpty)
            }
            if !vendors.isEmpty {
                HStack(spacing: 8) {
                    if vendors.count > 1 {
                        OctetSegmented(selection: Binding(get: { taskVendor }, set: { vendor in
                            taskVendor = vendor
                            if vendor != "claude" { taskPlace = .background }
                        }), items: vendors.map { ($0, Self.shortName($0)) })
                    } else if let brand = AgentBrand.forAgent(taskVendor) {
                        HStack(spacing: 5) {
                            AgentLogo(brand: brand, size: 12)
                            Text(brand.displayName).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    OctetSegmented(selection: $taskPlace,
                                   items: taskVendor == "claude" ? [(.background, "Background"), (.cloud, "Cloud")]
                                                                 : [(.background, "Background")])
                        .help(taskPlace == .cloud ? "Runs in Anthropic's cloud, streamed into a new tab (claude --cloud)"
                                                  : "Runs on this Mac with no tab: claude --bg, or codex exec")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
    }

    private static func shortName(_ vendor: String) -> String {
        switch vendor {
        case "claude": "Claude"
        case "codex": "Codex"
        default: AgentBrand.forAgent(vendor)?.displayName ?? vendor
        }
    }

    private func start() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cwd = window.focusedWorkspace.flatMap { store.snapshot.directory(ofWorkspace: $0.workspaceId) } ?? NSHomeDirectory()
        switch (taskVendor, taskPlace) {
        case ("claude", .cloud):
            guard let agent = discovery.agents.first(where: { $0.id == "claude" && $0.executablePath != nil }) else { return }
            close()
            window.newCloudTab(agent, task: text)
        case ("claude", _):
            AgentsStore.shared.dispatch(task: text, cwd: cwd, model: AgentSession.defaultModel, effort: nil,
                                        mode: AgentSession.PermissionMode.auto.rawValue)
        default:
            CodexAgentsStore.shared.start(task: text, cwd: cwd)
        }
        task = ""
    }

    // MARK: - Opening

    private func select(_ agent: HubAgent) {
        selected = agent.id
        listFocused = true
    }

    /// Goes to the agent where it runs. A background session has nowhere to
    /// go, so it shows here.
    private func focus(_ agent: HubAgent) {
        switch agent.target {
        case .chat(let session):
            close()
            window.focusWorkspace(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        case .terminal(let tab):
            close()
            AgentCenter.shared.setActive(nil, in: tab.workspaceId)
            window.focusTabAnywhere(tab)
        case .claudeBackground, .codexBackground:
            selected = agent.id
        }
    }

    @ViewBuilder
    private func detailPane(_ agent: HubAgent?, any: Bool) -> some View {
        ZStack {
            if let agent {
                Group {
                    switch agent.target {
                    case .claudeBackground(let background): AgentDetail(agent: background, store: store)
                    case .codexBackground(let background): CodexDetail(agent: background, store: store)
                    case .chat(let session): ChatHubDetail(agent: agent, session: session) { focus(agent) }
                    case .terminal: TerminalHubDetail(agent: agent, tracker: tracker) { focus(agent) }
                    }
                }
                .id(agent.id)
                .transition(motion.animates(.sidebar) ? .opacity : .identity)
            } else if any {
                HubEmptyState(icon: "list", title: "Select an agent",
                              message: "Its status, context and latest output show here. ↑ ↓ to move, Return to go to it.")
            } else {
                HubEmptyState(icon: "sparkles", title: "Nothing running",
                              message: "Agents from chats, terminal tabs, the background and the cloud all gather here.")
            }
        }
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.12)), value: agent?.id)
    }

    private func close() {
        AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
    }

    #if DEBUG
    /// Verification hook: OCTET_OPEN_WINDOW=agents:<option>… — "down" and
    /// "up" press the arrow keys and "return" Return through the window's
    /// key dispatch; "chat", "terminal", "background", "cloud" pick a
    /// filter; "search=<text>" searches.
    private func applyDebugOptions() {
        guard let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("agents:") else { return }
        var delay = 2.5
        for part in open.split(separator: ":").dropFirst().map(String.init) {
            if let place = HubAgent.Place(rawValue: part) { filter = place }
            if part.hasPrefix("search=") { query = String(part.dropFirst(7)) }
            let key: (String, UInt16)? = switch part {
            case "down": ("\u{F701}", 125)
            case "up": ("\u{F700}", 126)
            case "return": ("\r", 36)
            default: nil
            }
            guard let key else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.1 == 36 ? [] : [.numericPad, .function],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: key.0, charactersIgnoringModifiers: key.0,
                                                   isARepeat: false, keyCode: key.1) else { return }
                window.sendEvent(event)
            }
            delay += 0.4
        }
    }
    #endif
}

// MARK: - Row

/// One agent in the list, after T3 Code's thread rows: its mark and name,
/// what it last said, and where it is; on the right its state, or how long
/// ago it settled, giving way on hover to what can be done with it.
private struct HubRow: View {
    let agent: HubAgent
    let selected: Bool
    let focus: () -> Void
    let stop: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark.frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.title)
                        .font(Theme.interfaceFont(13, weight: agent.status == .done ? .regular : .medium))
                        .foregroundStyle(agent.status == .done && !selected ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    trailing.frame(height: 18)
                }
                // A session named after its task says it twice: skip the echo.
                if let detail = agent.detail, !detail.isEmpty, !detail.hasPrefix(String(agent.title.prefix(24))) {
                    Text(detail)
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 5) {
                    OctetIcon(agent.place.icon, size: 11)
                    Text(agent.place.title)
                    if let location = agent.location {
                        Text("·")
                        Text(location).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(agent.opensInPlace ? "Click to show, double-click to go to it" : "Show its conversation")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.title), \(agent.status.title), \(agent.place.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if agent.opensInPlace { Button("Go to It", action: focus) }
            if agent.canStop { Button("Stop", action: stop) }
        }
    }

    /// The agent's mark, so a glance says whose it is.
    @ViewBuilder private var mark: some View {
        if let brand = AgentBrand.forAgent(agent.vendor) {
            AgentLogo(brand: brand, size: 14)
        } else {
            OctetIcon("sparkle", size: 14).foregroundStyle(Theme.textTertiary)
        }
    }

    /// State while it matters, time once it's settled; actions on hover.
    private var trailing: some View {
        let actions = agent.opensInPlace || agent.canStop
        return ZStack(alignment: .trailing) {
            status
                .opacity(hovered && actions ? 0 : 1)
            if actions {
                HStack(spacing: 2) {
                    if agent.canStop {
                        OctetIconButton(icon: "pause.circle", help: "Stop", compact: true, action: stop)
                    }
                    if agent.opensInPlace {
                        OctetIconButton(icon: "arrow.up.right", help: "Go to it (Return)", compact: true, action: focus)
                    }
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch agent.status {
        case .needsInput, .working:
            HStack(spacing: 5) {
                if agent.status == .working {
                    LoadingLine(width: 12)
                } else {
                    Circle().fill(agent.status.color).frame(width: 7, height: 7)
                }
                Text(agent.status.title)
            }
            .font(Theme.interfaceFont(11.5, weight: .medium))
            .foregroundStyle(agent.status.color)
            .fixedSize()
        case .done:
            if let date = agent.date {
                Text(UsageMeter.relative(date))
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Resizing

/// An invisible strip over the hub's divider: drag to resize the list,
/// double-click to go back to its default width.
private struct HubResizeHandle: View {
    @Binding var width: Double
    let total: CGFloat
    @State private var start: Double?
    @State private var hovering = false

    private var range: ClosedRange<Double> {
        Double(HubStyle.listMinWidth)...Double(max(HubStyle.listMinWidth, min(640, total * 0.6)))
    }

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? min(range.upperBound, max(range.lowerBound, width))
                        start = from
                        width = min(range.upperBound, max(range.lowerBound, (from + drag.translation.width).rounded()))
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = Double(HubStyle.listDefaultWidth) }
            .help("Drag to resize the list. Double-click to reset.")
            .accessibilityLabel("List width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let delta: Double = direction == .increment ? 16 : -16
                width = min(range.upperBound, max(range.lowerBound, width + delta))
            }
    }
}

// MARK: - Agents button

/// The tab bar's Agents button: opens the hub, and counts every agent that
/// needs you, whichever vendor and wherever it runs.
struct AgentsHubButton: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var claude = AgentsStore.shared
    @ObservedObject private var codex = CodexAgentsStore.shared
    @State private var hovered = false

    var body: some View {
        let waiting = AgentsHubList.waitingCount(store: store)
        let workspace = window.focusedWorkspace?.workspaceId
        let showing = center.board(in: workspace) != nil
        Button { center.setBoard(showing ? nil : .all, in: workspace) } label: {
            // An icon button like those beside it: a 14pt line icon in a
            // 24pt square, with how many agents wait on you as a badge.
            OctetIcon("brain", size: 14)
                .accessibilityHidden(true)
                .foregroundStyle(showing || hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(showing ? Theme.cardSelected : hovered ? Theme.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Text("\(waiting)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.terminalBackground)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(HubStyle.waiting))
                            .offset(x: 4, y: -2)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("Agents (⌘⇧A)" + (waiting > 0 ? ": \(waiting) waiting on you" : ""))
        .accessibilityLabel("Agents" + (waiting > 0 ? ", \(waiting) need input" : ""))
    }
}
