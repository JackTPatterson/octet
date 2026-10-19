import SwiftUI

/// Horizontal tabs for the focused workspace's tabs. Tabs
/// that run an agent show its state glyph and vendor mark; subagent viewer
/// tabs are named after the subagent.
struct TabBarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var agents = AgentCenter.shared
    @Namespace private var selection
    /// Where a dragged tab would land: the gap before this index.
    @State private var dropGap: Int?
    var body: some View {
        let workspaceId = window.focusedWorkspace?.workspaceId
        let conversations = agents.sessions(in: workspaceId)
        let tabs = window.displayedTabs.filter {
            !window.hidesAsConversationBackingTab($0.tabId, sessions: conversations)
        }
        let currentIds = tabs.map { "terminal:\($0.tabId)" }
            + conversations.map { "conversation:\($0.id)" }
            + (window.editor.documents.isEmpty ? [] : ["editor:\(window.id.uuidString)"])
            + window.workspaceContainerLogs.map(\.visualID)
        let orderedIds = window.orderedVisualTabs(currentIds)
        let showingConversation = agents.active(in: workspaceId) != nil
        // A conversation in front means no terminal tab is.
        let focusedId = (showingConversation || window.editor.isPresented || window.activeContainerLog != nil) ? nil : window.displayedFocusedTabId

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(orderedIds, id: \.self) { id in
                            if id.hasPrefix("terminal:"),
                               let tab = tabs.first(where: { "terminal:\($0.tabId)" == id }) {
                                let index = tabs.firstIndex(of: tab) ?? 0
                                TabItem(store: store, tab: tab, index: index, count: tabs.count,
                                        isActive: tab.tabId == focusedId, selection: selection,
                                        handoffTitle: window.agentUIHandoffTabId == tab.tabId
                                            ? window.agentUIHandoffTitle : nil)
                                    .onDrag {
                                        // Dropped on the terminal, the tab becomes a split.
                                        TabDrag.shared.begin(tab.tabId, store: store)
                                        return NSItemProvider(object: tab.tabId as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: TabDropDelegate(
                                        window: window, index: index, tabs: tabs, gap: $dropGap))
                                    .overlay(alignment: .leading) { insertionBar(visible: dropGap == index) }
                                    .overlay(alignment: .trailing) {
                                        insertionBar(visible: index == tabs.count - 1 && dropGap == tabs.count)
                                    }
                                    .id(tab.tabId)
                            } else if id.hasPrefix("conversation:"),
                                      let session = conversations.first(where: { "conversation:\($0.id)" == id }) {
                                ConversationTab(session: session,
                                                isActive: window.activeContainerLog == nil && agents.active(in: workspaceId)?.id == session.id,
                                                selection: selection)
                                    .id(session.id)
                            } else if let log = window.workspaceContainerLogs.first(where: { $0.visualID == id }) {
                                ContainerLogWorkspaceTab(tab: log, isActive: window.activeContainerLog?.id == log.id, selection: selection)
                                    .id(id)
                            } else if id.hasPrefix("editor:") {
                                EditorOuterTab(workspace: window.editor,
                                               isActive: window.activeContainerLog == nil && window.editor.isPresented,
                                               selection: selection)
                                    .id(id)
                            }
                        }
                        NewTabButton(newTab: { window.newTab() },
                                     newConversation: { window.newConversation(engine: $0) },
                                     newAgentTab: { window.newTab(running: $0) },
                                     newCloudTab: { window.newCloudTab($0, task: $1) },
                                     teleport: { window.teleportCloudSession($0) })
                    }
                }
                // Never a scroller, even with "Always show scroll bars".
                .scrollIndicators(.never)
                // The selection surface slides to the new tab, as the planes
                // strip's does, however the focus changed.
                .animation(MotionPreferences.shared.animation(.tabs, .smooth(duration: 0.2)), value: focusedId)
                .animation(MotionPreferences.shared.animation(.tabs, .smooth(duration: 0.2)), value: agents.active(in: workspaceId)?.id)
                .animation(MotionPreferences.shared.animation(.tabs, .smooth(duration: 0.2)), value: window.editor.isPresented)
                .onChange(of: window.activeContainerLog?.id) { _, id in
                    if let tab = window.workspaceContainerLogs.first(where: { $0.id == id }) { proxy.scrollTo(tab.visualID) }
                }
                .onChange(of: focusedId) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: agents.active(in: workspaceId)?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: orderedIds) { _, _ in
                    // Newly inserted tabs must exist in the scroll layout
                    // before a selection jump can reach them.
                    if let id = agents.active(in: workspaceId)?.id ?? focusedId {
                        proxy.scrollTo(id)
                    }
                }
            }
            Spacer(minLength: 0)
            // Every agent, from any tab: at the far right.
            AgentsHubButton(store: store).padding(.trailing, 4)
            // T3 Code's thread-details toggle.
            OctetIconButton(icon: "menucard", help: OctetShortcut.details.help("Toggle details"),
                            active: ui.detailsVisible) { ui.detailsVisible.toggle() }
                .padding(.trailing, 4)
            // One button for the right panel: Todos, Git, the agents' runtime
            // and plugins' panels are its tabs and sections, not buttons here.
            if !ui.sidePanelVisible {
                SidePanelButton(ui: ui)
            }
        }
        .padding(.trailing, 8)
        .frame(height: Theme.tabBarHeight)
        // The rest of the strip takes a tab too, onto the end, as a
        // browser's does; the tabs' own targets sit above this one.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: TabDropDelegate(
                    window: window, index: tabs.count, tabs: tabs, gap: $dropGap, fixedGap: tabs.count))
        }
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    @ViewBuilder
    private func insertionBar(visible: Bool) -> some View {
        if visible {
            Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 5).allowsHitTesting(false)
        }
    }
}

/// Drag a tab onto another: dropping on its left half lands before it, on
/// its right half after it. The session server's `tab.move` does the reorder.
private struct TabDropDelegate: DropDelegate {
    /// The window this bar is in: a tab from another window moves into it.
    let window: WindowContext
    let index: Int
    let tabs: [EngineTab]
    @Binding var gap: Int?
    /// Where anything dropped lands, for the empty strip past the tabs.
    var fixedGap: Int?

    private func gap(for info: DropInfo) -> Int {
        fixedGap ?? (info.location.x < Theme.tabWidth / 2 ? index : index + 1)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { gap = gap(for: info) }
    func dropExited(info: DropInfo) { gap = nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        gap = gap(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let landing = gap(for: info)
        gap = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        TabDrag.shared.landed()
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { WindowActions.moveTab(id, into: window, at: landing) }
        }
        return true
    }
}

private struct TabItem: View {
    @ObservedObject var store: SessionStore
    @EnvironmentObject private var window: WindowContext
    let tab: EngineTab
    let index: Int
    let count: Int
    let isActive: Bool
    let selection: Namespace.ID
    let handoffTitle: String?
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var prompts = PromptQueueCenter.shared
    @State private var hovered = false
    @State private var renaming = false

    /// Prompts waiting for this tab's agents to finish their turn.
    private var queued: Int {
        let panes = Set(store.snapshot.panes.filter { $0.tabId == tab.tabId }.map(\.paneId))
        return prompts.queue.items.filter { panes.contains($0.paneId) }.count
    }

    private var title: String { TabAutoName.display(label: tab.label, number: tab.number) }

    /// What a plugin says the tab is running: its focused pane's, else the
    /// first pane that's running something it knows.
    private var runtime: RuntimeBadge? {
        let panes = store.snapshot.panes.filter { $0.tabId == tab.tabId }
        let ordered = panes.filter(\.focused) + panes.filter { !$0.focused }
        return ordered.lazy.compactMap { store.paneRuntimes[$0.paneId] }.first
    }

    /// The machine this tab's focused pane, or any of its panes, is logged into.
    private var ssh: SSHTarget? {
        let panes = store.snapshot.panes.filter { $0.tabId == tab.tabId }
        let ordered = panes.filter(\.focused) + panes.filter { !$0.focused }
        return ordered.lazy.compactMap { store.paneSSH[$0.paneId] }.first
    }

    var body: some View {
        let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tab.tabId))
        let brand = AgentBrand.forAgent(agent?.agent)
        // A colour picked by hand, here or on the root agent's tab or the
        // workspace, outranks the vendor's.
        let picked = store.tabColor(tab)
        let hue = picked?.hex ?? brand?.hueHex

        HStack(spacing: 6) {
            if let agent, handoffTitle == nil {
                AgentStateGlyph(status: agent.agentStatus, size: 9)
                    .frame(width: 10)
            }
            if let brand, agent?.isSubagentViewer == true {
                // A subagent's tab: the agent icon in its vendor's colour,
                // so it reads as a helper rather than another session.
                OctetIcon("tool.agent", size: 11)
                    .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? Theme.textPrimary)
                    .help("\(brand.displayName) subagent")
            } else if let brand {
                AgentLogo(brand: brand, size: 11)
            } else if let runtime = runtime {
                RuntimeIcon(badge: runtime, size: 11)
                    .help(runtime.name)
            } else {
                OctetIcon("terminal", size: 11).foregroundStyle(Theme.textSecondary)
            }
            if renaming {
                InlineRenameField(initial: TabAutoName.isUnnamed(tab.label) ? "" : tab.label, placeholder: title) { label in
                    renaming = false
                    if let label { store.renameTab(tab.tabId, to: label) }
                }
            } else {
                Text(handoffTitle ?? title)
                    .font(Theme.uiFont)
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if queued > 0, !renaming {
                HStack(spacing: 2) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 9, weight: .semibold))
                    Text("\(queued)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.08)))
                .help(queued == 1 ? "1 prompt queued for when the agent finishes" : "\(queued) prompts queued for when the agent finishes")
                .accessibilityLabel("\(queued) queued")
            }
            if let location = store.agentLocation(inTab: tab.tabId), handoffTitle == nil, !renaming {
                // The subagent is off in a worktree or folder of its own.
                OctetIcon(location.icon, size: 10)
                    .foregroundStyle(location.tint.opacity(isActive || hovered ? 1 : 0.75))
                    .help(location.help(abbreviate: abbreviateHome))
                    .accessibilityLabel("In \(location.phrase)")
                    .transition(motion.animates(.connections) ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
            if let ssh, handoffTitle == nil, !renaming {
                SSHHostChip(target: ssh, compact: true)
                    .frame(maxWidth: 84)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(-1)
                    .transition(motion.animates(.connections) ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
            Spacer(minLength: 4)
            TabCloseButton { window.closeTab(tab.tabId) }
                .opacity(hovered || isActive ? 1 : 0)
        }
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)), value: ssh)
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)),
                   value: store.agentLocation(inTab: tab.tabId))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        // One width for every tab, so after a close the next tab's close
        // button slides under the pointer.
        .frame(width: Theme.tabWidth)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if let hue, !isActive {
                    Color(hex: hue).opacity(hovered ? Theme.tabColorHoverOpacity : Theme.tabColorOpacity)
                }
                // A single selection surface slides between tabs.
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        if let hue { Color(hex: hue).opacity(picked == nil ? 0.08 : 0.12) }
                        Rectangle()
                            .fill(picked?.color ?? Color.white.opacity(0.9))
                            .frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
            .animation(motion.animation(.tabs, .easeOut(duration: 0.12)), value: hovered)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { window.closeTab(tab.tabId) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { window.focusTab(tab.tabId) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        .contextMenu {
            Button("Rename Tab…") { renaming = true }
            if TabAutoName.isUnnamed(tab.label) == false {
                Button("Reset Tab Name") { store.renameTab(tab.tabId, to: "") }
            }
            Divider()
            TabColorPicker(title: "Tab Color", selection: Binding(
                get: { store.ownTabColor(tab) },
                set: { store.setTabColor(tab, $0) }))
            Divider()
            Button("Move Tab Left") { store.moveTab(tab.tabId, by: -1) }.disabled(index == 0)
            Button("Move Tab Right") { store.moveTab(tab.tabId, by: 1) }.disabled(index >= count - 1)
            Divider()
            Button("Move Tab to New Window") {
                WindowActions.tearOff(tabId: tab.tabId, store: store, frame: WindowActions.cascaded(from: window))
            }
            .disabled(store.onlyPane(ofTab: tab.tabId) == nil)
            PluginMenuItems(place: .tab,
                            directory: store.snapshot.panes.first { $0.tabId == tab.tabId && $0.focused }?.effectiveCwd
                                ?? store.snapshot.panes.first { $0.tabId == tab.tabId }?.effectiveCwd,
                            workspaceId: tab.workspaceId)
            Divider()
            Button("Close Tab") { window.closeTab(tab.tabId) }
            Button("Close Other Tabs") {
                window.focusTab(tab.tabId)
                store.closeTabs(except: tab.tabId)
            }.disabled(count < 2)
            Button("Close Tabs to the Right") { store.closeTabs(rightOf: tab.tabId) }.disabled(index >= count - 1)
        }
        .help(index < 9 ? "\(handoffTitle ?? title)  ⌘\(index + 1)" : handoffTitle ?? title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.map { "\(title), \(brand?.displayName ?? "agent")\($0.isSubagentViewer ? " subagent" : "") \(stateLabel($0.agentStatus))" } ?? title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusTab(tab.tabId) }
        .accessibilityAction(named: "Rename") { renaming = true }
        .accessibilityAction(named: "Close") { window.closeTab(tab.tabId) }
    }
}

private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon("xmark", size: 15)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(hovered ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close Tab (⌘W)")
        .accessibilityLabel("Close tab")
    }
}

/// One control for anything new: a click opens a terminal tab, and the
/// conversations are a press away. A standing button for one vendor beside
/// this one would claim a precedence neither has.
private struct NewTabButton: View {
    let newTab: () -> Void
    let newConversation: (AgentSession.Engine) -> Void
    let newAgentTab: (DiscoveredAgent) -> Void
    /// A cloud session for the agent, with the task typed for it.
    let newCloudTab: (DiscoveredAgent, String?) -> Void
    /// `claude --teleport`: a cloud session brought into this folder.
    let teleport: (DiscoveredAgent) -> Void
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var hovered = false
    @State private var menuOpen = false
    /// The agent whose Cloud button was pressed, while its task is typed.
    private enum LaunchMode: String, CaseIterable { case chat = "Chat", terminal = "Terminal", cloud = "Cloud" }
    @State private var launchMode = LaunchMode.chat
    @State private var cloudAgentId: String?
    @State private var cloudTask = ""
    @State private var cloudTaskFocusRequest = 0

    var body: some View {
        HStack(spacing: 0) {
            OctetIconButton(icon: "plus", help: "New Tab (⌘T)", action: newTab)
            OctetIconButton(icon: "chevron.down", help: "Choose a new tab", active: menuOpen, compact: true) {
                menuOpen.toggle()
            }
            // A menu of Octet's own, so each agent is named by its mark
            // rather than by a word in a system font.
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) { menu }
            .onChange(of: menuOpen) { _, open in
                if !open {
                    cloudAgentId = nil
                    cloudTask = ""
                }
            }
        }
        .background(hovered || menuOpen ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .onHover { hovered = $0 }
        .padding(.horizontal, 4)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New tab")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8).padding(.top, 5)
            NewMenuRow(mark: .icon("terminal"), title: "Terminal", keys: "⌘T") { choose(newTab) }
                .help("Open a shell in this workspace")
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 3)
            HStack {
                Text("Start an agent").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Spacer()
            }.padding(.horizontal, 8)
            OctetSegmented(selection: $launchMode,
                           items: LaunchMode.allCases.map { (value: $0, title: $0.rawValue) })
                .accessibilityLabel("Open agent in")
                .padding(.horizontal, 5)
            .onChange(of: launchMode) { _, _ in cloudAgentId = nil; cloudTask = "" }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleEntries) { entry in
                        NewMenuRow(mark: .agent(entry.id), title: entry.name,
                                   keys: launchMode == .chat && entry.engine == .claude ? "⌘⇧N" : nil) {
                            switch launchMode {
                            case .chat:
                                if let engine = entry.engine { choose { newConversation(engine) } }
                            case .terminal:
                                if let agent = entry.agent { choose { newAgentTab(agent) } }
                            case .cloud: cloudAction(for: entry)?()
                            }
                        }
                        if cloudAgentId == entry.id, let agent = entry.agent { cloudTaskField(agent) }
                    }
                    if visibleEntries.isEmpty {
                        Text("No installed agents support this mode.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            .padding(8)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(300, CGFloat(max(1, visibleEntries.count)) * 28 + (cloudAgentId == nil ? 0 : 38)))
            if launchMode == .cloud, let claude = entries.first(where: { $0.id == "claude" })?.agent {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 3)
                NewMenuRow(mark: .icon("cloud"), title: "Resume cloud session") { choose { teleport(claude) } }
                    .help("Bring a Claude Code cloud session into this folder")
            }
        }
        .padding(8)
        .frame(width: 300)
        .octetGlass(cornerRadius: Theme.popoverRadius)
        .onExitCommand { menuOpen = false }
    }

    private var visibleEntries: [AgentMenuEntry] {
        entries.filter { entry in
            switch launchMode {
            case .chat: entry.engine != nil
            case .terminal: entry.agent != nil
            case .cloud: entry.agent != nil && CloudAgents.start(for: entry.id) != nil
            }
        }
    }

    /// The Cloud button: asks for the task first when the agent takes one,
    /// else opens the agent's own list of cloud tasks.
    private func cloudAction(for entry: AgentMenuEntry) -> (() -> Void)? {
        guard let agent = entry.agent, let start = CloudAgents.start(for: entry.id) else { return nil }
        switch start {
        case .withTask:
            return {
                cloudAgentId = cloudAgentId == entry.id ? nil : entry.id
                cloudTask = ""
                if cloudAgentId != nil {
                    cloudTaskFocusRequest += 1
                }
            }
        case .browser:
            return { choose { newCloudTab(agent, nil) } }
        }
    }

    /// Where the task for a cloud session is typed, under the agent's row.
    private func cloudTaskField(_ agent: DiscoveredAgent) -> some View {
        HStack(spacing: 6) {
            OctetTextField(placeholder: "Task for the cloud agent", text: $cloudTask,
                           onSubmit: { submitCloudTask(agent) }, focusRequest: cloudTaskFocusRequest)
            OctetButton(title: "Start", kind: .primary, compact: true) { submitCloudTask(agent) }
                .disabled(cloudTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func submitCloudTask(_ agent: DiscoveredAgent) {
        let task = cloudTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        choose { newCloudTab(agent, task) }
    }

    /// Native conversation agents first, then every
    /// other agent found with an executable to run.
    private var entries: [AgentMenuEntry] {
        let runnable = discovery.agents.filter { $0.executablePath != nil }
        // Additional native agents are offered once their CLI is installed.
        let chat: [AgentSession.Engine] = [.claude, .codex]
            + [.opencode, .pi, .qwen].filter { engine in runnable.contains { $0.id == engine.agent } }
        let driven = chat.map { engine in
            AgentMenuEntry(id: engine.agent, name: engine == .claude ? "Claude Code" : engine.displayName, engine: engine,
                           agent: runnable.first { $0.id == engine.agent })
        }
        let others = runnable.filter { agent in !chat.contains { $0.agent == agent.id } }
            .map { AgentMenuEntry(id: $0.id, name: $0.displayName, engine: nil, agent: $0) }
        return driven + others
    }

    private func choose(_ action: () -> Void) {
        menuOpen = false
        action()
    }
}

private struct AgentMenuEntry: Identifiable {
    let id: String
    let name: String
    /// Set when Octet has a chat view for this agent.
    let engine: AgentSession.Engine?
    /// Set when its CLI is installed, so it can run in a terminal tab.
    let agent: DiscoveredAgent?
}

/// A row of the new-tab menu: the agent's own mark, what it opens, and the
/// keys that do it without the menu.
private struct NewMenuRow: View {
    enum Mark {
        case icon(String)
        case agent(String)
    }

    let mark: Mark
    let title: String
    var keys: String?
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let item = menuItem
        OctetMenuRow(item: item, highlighted: hovered || focused, open: false,
                     hover: { hovered = true }, activate: action)
            .onHover { hovered = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
    }

    private var menuItem: OctetMenuItem {
        var item = OctetMenuItem.action(title, shortcut: keys, action)
        switch mark {
        case .icon(let name): item.icon = name
        case .agent(let agent): item.agent = agent
        }
        return item
    }
}

/// A native conversation, alongside the terminal tabs, marked with the
/// vendor driving it.
private struct ConversationTab: View {
    @ObservedObject var session: AgentSession
    let isActive: Bool
    let selection: Namespace.ID
    @State private var hovered = false
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        let brand = AgentBrand.forAgent(session.engine.agent)
        HStack(spacing: 6) {
            if session.conversation.isRunning {
                LoadingLine(width: 12)
            } else if session.pendingPermission != nil {
                Circle().fill(Theme.accent).frame(width: 6, height: 6).frame(width: 10)
            }
            if let brand { AgentLogo(brand: brand, size: 11) }
            Text(session.title)
                .font(Theme.uiFont)
                .fontWeight(isActive ? .medium : .regular)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            TabCloseButton { AgentCenter.shared.close(session) }
                .opacity(hovered || isActive ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: Theme.tabWidth)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Color.white.opacity(0.9)).frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { AgentCenter.shared.close(session) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            window.editor.dismiss()
            window.containerLogs.activeID = nil
            AgentCenter.shared.activeId = session.id
        }
        .contextMenu {
            ConversationActionsMenu(session: session)
            Divider()
            Button("Close Conversation") { AgentCenter.shared.close(session) }
        }
        .help(session.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.engine.displayName) conversation, \(session.title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            window.editor.dismiss()
            window.containerLogs.activeID = nil
            AgentCenter.shared.activeId = session.id
        }
        .accessibilityAction(named: "Close") { AgentCenter.shared.close(session) }
    }
}

/// The editor is one outer tab even when it contains several files. Its inner
/// tabs carry the individual buffer names, matching the grouped viewer model.
private struct EditorOuterTab: View {
    @ObservedObject var workspace: EditorWorkspace
    let isActive: Bool
    let selection: Namespace.ID
    @EnvironmentObject private var window: WindowContext
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            OctetIcon("tool.edit", size: 13)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            Text(workspace.activeDocument?.name ?? "Editor")
                .font(Theme.uiFont)
                .fontWeight(isActive ? .medium : .regular)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !workspace.dirtyDocuments.isEmpty {
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
            }
            TabCloseButton { workspace.closeEditor() }
                .opacity(hovered || isActive ? 1 : 0)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(width: Theme.tabWidth).frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Color.white.opacity(0.9)).frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { window.showEditor() }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Save") { workspace.save() }.disabled(workspace.activeDocument?.isDirty != true)
            Button("Save All") { workspace.saveAll() }.disabled(workspace.dirtyDocuments.isEmpty)
            Divider()
            Button("Close Editor") { workspace.closeEditor() }
        }
        .help(workspace.activeDocument?.url.path ?? "Editor")
        .accessibilityLabel("Editor")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.showEditor() }
    }
}

/// Uses the same outer-tab chrome as the editor and conversations.
private struct ContainerLogWorkspaceTab: View {
    let tab: WorkspaceContainerLog
    let isActive: Bool
    let selection: Namespace.ID
    @EnvironmentObject private var window: WindowContext
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            OctetIcon("tool.read", size: 13)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            Text(tab.title).font(Theme.uiFont).fontWeight(isActive ? .medium : .regular)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            TabCloseButton { window.closeContainerLogs(tab.id) }.opacity(hovered || isActive ? 1 : 0)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(width: Theme.tabWidth).frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Color.white.opacity(0.9)).frame(height: 2)
                    }.matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { window.closeContainerLogs(tab.id) } }
        .contentShape(Rectangle())
        .onTapGesture { window.focusContainerLogs(tab.id) }
        .onHover { hovered = $0 }
        .octetContextMenu { [.action("Close Logs", icon: "xmark") { window.closeContainerLogs(tab.id) }] }
        .help("\(tab.name) · \(tab.context)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusContainerLogs(tab.id) }
        .accessibilityAction(named: "Close") { window.closeContainerLogs(tab.id) }
    }
}
