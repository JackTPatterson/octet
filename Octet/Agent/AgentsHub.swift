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

    enum Status: Int, Comparable {
        case needsInput, working, done
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
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
    /// What it last said, or where it is.
    let detail: String?
    let place: Place
    let status: Status
    let cwd: String?
    let date: Date?
    let target: Target

    var opensInPlace: Bool {
        switch target {
        case .chat, .terminal: true
        case .claudeBackground, .codexBackground: false
        }
    }
}

/// Every agent from every source, for the hub and the Agents button.
@MainActor
enum AgentsHubList {
    static func agents(store: SessionStore) -> [HubAgent] {
        chats() + terminals(store: store) + claudeBackground() + codexBackground()
    }

    /// How many are waiting on you, across all of them.
    static func waitingCount(store: SessionStore) -> Int {
        agents(store: store).filter { $0.status == .needsInput }.count
    }

    private static func chats() -> [HubAgent] {
        AgentCenter.shared.sessions.map { session in
            let status: HubAgent.Status = session.pendingPermission != nil || session.pendingQuestion != nil ? .needsInput
                : session.conversation.isRunning ? .working : .done
            return HubAgent(id: "chat:" + session.id, vendor: session.engine.agent, title: session.title,
                            detail: lastText(session.conversation), place: .chat, status: status,
                            cwd: session.cwd, date: nil, target: .chat(session))
        }
    }

    private static func terminals(store: SessionStore) -> [HubAgent] {
        let snapshot = store.snapshot
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
                            title: label, detail: workspace.map { "in \($0)" },
                            place: label.hasPrefix("☁") ? .cloud : .terminal, status: status,
                            cwd: agent.effectiveCwd, date: nil, target: .terminal(tab))
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

    private static func status(_ agent: BackgroundAgent) -> HubAgent.Status {
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

/// Every agent in one place, grouped by what needs you: the ones waiting on
/// an answer first, then the ones working, then the finished. Chats and
/// terminal agents open where they run; a background session shows its
/// transcript here. A task can start from here in the background or the
/// cloud.
struct AgentsHub: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var claude = AgentsStore.shared
    @ObservedObject private var codex = CodexAgentsStore.shared
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var selected: String?
    @State private var filter: HubAgent.Place?
    @State private var showsAllDone = false
    @State private var task = ""
    @State private var taskVendor = "claude"
    @State private var taskPlace: HubAgent.Place = .background
    private static let doneShown = 12

    var body: some View {
        let all = AgentsHubList.agents(store: store)
        let shown = all.filter { filter == nil || $0.place == filter }
        HStack(spacing: 0) {
            list(all: all, shown: shown)
                .frame(width: 420)
                .zIndex(1)
            Rectangle().fill(Theme.divider).frame(width: 1).zIndex(1)
            ZStack {
                if let agent = all.first(where: { $0.id == selected }) {
                    detail(agent)
                        .id(agent.id)
                        .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                } else {
                    VStack(spacing: 6) {
                        Text("Select a background session").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        Text("Its conversation shows here, live. Chats and terminal agents open where they run.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(motion.animation(.sidebar), value: selected)
        }
        .background(Theme.terminalBackground)
        .onExitCommand { close() }
        .onAppear {
            if selected == nil { selected = all.filter { !$0.opensInPlace }.sorted { $0.status < $1.status }.first?.id }
            if !installed(taskVendor), let first = vendors.first { taskVendor = first }
        }
    }

    // MARK: - List

    private func list(all: [HubAgent], shown: [HubAgent]) -> some View {
        let waiting = all.filter { $0.status == .needsInput }.count
        let working = all.filter { $0.status == .working }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(waiting) need you · \(working) working · \(all.count - waiting - working) done")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                OctetButton(title: "Close", kind: .ghost, compact: true) { close() }
                    .help("Back (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            newTask
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            filters
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Needs you", shown.filter { $0.status == .needsInput })
                    section("Working", shown.filter { $0.status == .working })
                    let done = shown.filter { $0.status == .done }
                        .sorted { ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture) }
                    section("Done", showsAllDone ? done : Array(done.prefix(Self.doneShown)))
                    if done.count > Self.doneShown {
                        Button(showsAllDone ? "Show fewer" : "Show all \(done.count)") { showsAllDone.toggle() }
                            .buttonStyle(.plain)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                    if shown.isEmpty {
                        Text(filter == nil ? "No agents yet. Start a task above, or open an agent from the + menu."
                                           : "No \(filter!.title.lowercased()) agents.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(14)
                    }
                    ForEach([claude.lastError, codex.lastError].compactMap { $0 }, id: \.self) { error in
                        Text(error).font(Theme.captionFont).foregroundStyle(Theme.danger).padding(.horizontal, 14).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.sidebar)
    }

    private var filters: some View {
        HStack(spacing: 4) {
            FilterChip(title: "All", selected: filter == nil) { filter = nil }
            ForEach(HubAgent.Place.allCases) { place in
                FilterChip(title: place.title, selected: filter == place) { filter = filter == place ? nil : place }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ agents: [HubAgent]) -> some View {
        if !agents.isEmpty {
            Text(title.uppercased())
                .font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            ForEach(agents) { agent in
                HubRow(agent: agent, selected: selected == agent.id)
                    .onTapGesture { open(agent) }
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - New task

    private var vendors: [String] { ["claude", "codex"].filter(installed) }

    private func installed(_ id: String) -> Bool {
        discovery.agents.contains { $0.id == id && $0.executablePath != nil }
    }

    private var newTask: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                OctetTextField(placeholder: "Describe a task for a new agent", text: $task) { start() }
                OctetButton(title: "Start", kind: .primary, compact: true) { start() }
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || vendors.isEmpty)
            }
            HStack(spacing: 6) {
                ForEach(vendors, id: \.self) { vendor in
                    FilterChip(title: AgentBrand.forAgent(vendor)?.displayName ?? vendor, brand: vendor,
                               selected: taskVendor == vendor) {
                        taskVendor = vendor
                        if vendor != "claude" { taskPlace = .background }
                    }
                }
                Rectangle().fill(Theme.divider).frame(width: 1, height: 14)
                FilterChip(title: "Background", selected: taskPlace == .background) { taskPlace = .background }
                    .help("Runs on this Mac with no tab: claude --bg, or codex exec")
                FilterChip(title: "Cloud", selected: taskPlace == .cloud) { taskPlace = .cloud }
                    .disabled(taskVendor != "claude")
                    .opacity(taskVendor == "claude" ? 1 : 0.4)
                    .help(taskVendor == "claude" ? "Runs in Anthropic's cloud, streamed into a new tab (claude --cloud)"
                                                 : "Only Claude Code starts a cloud session with a task")
                Spacer(minLength: 0)
            }
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

    private func open(_ agent: HubAgent) {
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
    private func detail(_ agent: HubAgent) -> some View {
        switch agent.target {
        case .claudeBackground(let background): AgentDetail(agent: background, store: store)
        case .codexBackground(let background): CodexDetail(agent: background, store: store)
        case .chat, .terminal: EmptyView()
        }
    }

    private func close() {
        AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
    }
}

/// One agent in the hub: state, mark, name, what it last said, and where.
private struct HubRow: View {
    let agent: HubAgent
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark.frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let brand = AgentBrand.forAgent(agent.vendor) { AgentLogo(brand: brand, size: 11) }
                    Text(agent.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if let detail = agent.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    OctetIcon(agent.place.icon, size: 10)
                    Text(agent.place.title)
                    if let cwd = agent.cwd {
                        Text("·")
                        Text(abbreviateHome(cwd)).lineLimit(1).truncationMode(.middle)
                    }
                    if let date = agent.date {
                        Text("·")
                        Text(UsageMeter.relative(date))
                    }
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if agent.opensInPlace {
                OctetIcon("arrow.right", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered ? 1 : 0)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(agent.opensInPlace ? "Go to it" : "Show its conversation")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var mark: some View {
        switch agent.status {
        case .needsInput:
            Circle().fill(Color(hex: "FFC107")).frame(width: 8, height: 8).padding(.top, 4)
        case .working:
            LoadingLine(width: 12).padding(.top, 6)
        case .done:
            OctetIcon("checkmark", size: 13).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// A small toggle in the hub's filter and new-task rows.
private struct FilterChip: View {
    let title: String
    var brand: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let brand = AgentBrand.forAgent(brand) { AgentLogo(brand: brand, size: 10) }
                Text(title).font(Theme.captionFont.weight(.medium))
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(selected ? Theme.textTertiary.opacity(0.5) : Theme.border.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

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
            HStack(spacing: 5) {
                Text("Agents").font(Theme.uiFontMedium)
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.terminalBackground)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Color(hex: "FFC107")))
                }
            }
            .foregroundStyle(showing ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(showing ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Agents (⌘⇧A)" + (waiting > 0 ? ": \(waiting) waiting on you" : ""))
        .accessibilityLabel("Agents" + (waiting > 0 ? ", \(waiting) need input" : ""))
    }
}
