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
        let orderedIds = window.orderedVisualTabs(currentIds)
        let showingConversation = agents.active(in: workspaceId) != nil
        // A conversation in front means no terminal tab is.
        let focusedId = (showingConversation || window.editor.isPresented) ? nil : window.displayedFocusedTabId

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
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
                                                isActive: agents.active(in: workspaceId)?.id == session.id,
                                                selection: selection)
                                    .id(session.id)
                            } else if id.hasPrefix("editor:") {
                                EditorOuterTab(workspace: window.editor,
                                               isActive: window.editor.isPresented,
                                               selection: selection)
                                    .id(id)
                            }
                        }
                        NewTabButton(newTab: { window.newTab() },
                                     newConversation: { window.newConversation(engine: $0) },
                                     newAgentTab: { window.newTab(running: $0) })
                    }
                }
                .onChange(of: focusedId) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            Spacer(minLength: 0)
            // The agents boards sit at the far right, for the tab in front.
            if showsAgentsButton { AgentsButton().padding(.trailing, 8) }
            if showsCodexButton { CodexAgentsButton().padding(.trailing, 8) }
            // Each panel's button shows only when it has something to show,
            // or while its panel is open so it can still be closed.
            HStack(spacing: 2) {
                TodoPanelButton(model: window.todos, isShowing: $ui.todoPanelVisible)
                if ui.runtimeHasEntries || ui.runtimePanelVisible {
                    RuntimePanelButton(isShowing: $ui.runtimePanelVisible)
                }
            }
            .padding(.trailing, 8)
        }
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

    /// The Claude agents button belongs to Claude tabs: a native Claude
    /// conversation, or a terminal tab running Claude Code (or the board).
    private var showsAgentsButton: Bool { showsBoardButton(.claude) }

    /// The Codex board's button belongs to Codex tabs (or the open board).
    private var showsCodexButton: Bool { showsBoardButton(.codex) }

    /// A board button belongs to whichever vendor is in front: the open
    /// board, else the conversation showing, else the focused tab's agent.
    private func showsBoardButton(_ engine: AgentSession.Engine) -> Bool {
        let workspaceId = window.focusedWorkspace?.workspaceId
        if let board = agents.board(in: workspaceId) { return board == (engine == .codex ? .codex : .claude) }
        if let conversation = agents.active(in: workspaceId) {
            return conversation.engine == engine
        }
        return focusedTabAgent == engine.agent
    }

    private var focusedTabAgent: String? {
        guard let tabId = window.displayedFocusedTabId else { return nil }
        return AgentBrand.forAgent(store.primaryAgent(in: store.snapshot.agents(inTab: tabId))?.agent)?.id
    }

    @ViewBuilder
    private func insertionBar(visible: Bool) -> some View {
        if visible {
            Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 5).allowsHitTesting(false)
        }
    }
}

private struct RuntimePanelButton: View {
    @Binding var isShowing: Bool
    @State private var hovered = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Text("Runtime").font(Theme.uiFontMedium)
            .foregroundStyle(isShowing ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(isShowing ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show runtimes created by this tab's agent")
        .accessibilityLabel(isShowing ? "Hide runtime panel" : "Show runtime panel")
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
    @State private var hovered = false
    @State private var renaming = false

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
                if let hue = brand?.hueHex, !isActive {
                    Color(hex: hue).opacity(hovered ? Theme.tabColorHoverOpacity : Theme.tabColorOpacity)
                }
                // A single selection surface slides between tabs.
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        if let hue = brand?.hueHex { Color(hex: hue).opacity(0.08) }
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
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
            Button("Move Tab Left") { store.moveTab(tab.tabId, by: -1) }.disabled(index == 0)
            Button("Move Tab Right") { store.moveTab(tab.tabId, by: 1) }.disabled(index >= count - 1)
            Divider()
            Button("Move Tab to New Window") {
                WindowActions.tearOff(tabId: tab.tabId, store: store, frame: WindowActions.cascaded(from: window))
            }
            .disabled(store.onlyPane(ofTab: tab.tabId) == nil)
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
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var hovered = false
    @State private var menuOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: newTab) {
                OctetIcon("plus", size: 15)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New tab")
            Button { menuOpen = true } label: {
                OctetIcon("chevron.down", size: 9)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .accessibilityLabel("New conversation")
            // A menu of Octet's own, so each agent is named by its mark
            // rather than by a word in a system font.
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) { menu }
        }
        .background(hovered || menuOpen ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .onHover { hovered = $0 }
        .padding(.horizontal, 4)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 1) {
            NewMenuRow(mark: .icon("terminal"), title: "New Tab", keys: "⌘T") { choose(newTab) }
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
            // One row per agent, each with what it can open: Octet's own chat
            // view, or a terminal tab running its CLI.
            ForEach(entries) { entry in
                AgentMenuRow(
                    entry: entry,
                    chat: entry.engine.map { engine in { choose { newConversation(engine) } } },
                    terminal: entry.agent.map { agent in { choose { newAgentTab(agent) } } }
                )
            }
        }
        // Enough inset that a row's highlight clears the popover's own
        // rounded corner; any less and the corner clips it square.
        .padding(8)
        .frame(width: 320)
        .background(Theme.chrome)
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

/// An agent in the new-tab menu: its mark and name, then a button for each
/// way it can open. Clicking the row takes the first.
private struct AgentMenuRow: View {
    let entry: AgentMenuEntry
    let chat: (() -> Void)?
    let terminal: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let brand = AgentBrand.forAgent(entry.id) { AgentLogo(brand: brand, size: 13) }
            }
            .frame(width: 16)
            Text(entry.name)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let chat {
                OpenChip(icon: "text.bubble", title: "Chat",
                         help: "New \(entry.engine?.displayName ?? entry.name) conversation"
                            + (entry.engine == .claude ? " (⌘⇧N)" : ""),
                         action: chat)
            }
            if let terminal {
                OpenChip(icon: "terminal", title: "Terminal",
                         help: "New tab running \(entry.name)", action: terminal)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
        .contentShape(Rectangle())
        .onTapGesture { (chat ?? terminal)?() }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.name)
    }
}

/// One way to open an agent, as a small labeled button.
private struct OpenChip: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                OctetIcon(icon, size: 11)
                Text(title).font(Theme.uiFont)
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(hovered ? Theme.accent.opacity(0.22) : Theme.terminalBackground.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(hovered ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    switch mark {
                    case .icon(let name):
                        OctetIcon(name, size: 13).foregroundStyle(Theme.textSecondary)
                    case .agent(let agent):
                        if let brand = AgentBrand.forAgent(agent) { AgentLogo(brand: brand, size: 13) }
                    }
                }
                .frame(width: 16)
                Text(title)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                if let keys { Keycap(text: keys) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
            AgentCenter.shared.activeId = session.id
        }
        .contextMenu {
            Button("Close Conversation") { AgentCenter.shared.close(session) }
        }
        .help(session.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.engine.displayName) conversation, \(session.title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            window.editor.dismiss()
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


/// Opens the Claude agents board; a count shows sessions waiting on you.
private struct AgentsButton: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var agents = AgentsStore.shared
    @ObservedObject private var center = AgentCenter.shared
    @State private var hovered = false

    var body: some View {
        let waiting = agents.needsInput.count
        let showing = center.board(in: window.focusedWorkspace?.workspaceId) == .claude
        Button { center.setBoard(showing ? nil : .claude, in: window.focusedWorkspace?.workspaceId) } label: {
            HStack(spacing: 4) {
                if let brand = AgentBrand.forAgent("claude") { AgentLogo(brand: brand, size: 12) }
                OctetIcon("tool.agent", size: 14)
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
        .help("Claude agents (⌘⇧A)" + (waiting > 0 ? ": \(waiting) waiting on you" : ""))
        .accessibilityLabel("Claude agents" + (waiting > 0 ? ", \(waiting) need input" : ""))
    }
}
