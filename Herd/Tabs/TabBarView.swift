import SwiftUI

/// Horizontal tabs for the focused workspace's tabs. Tabs
/// that run an agent show its state glyph and vendor mark; subagent viewer
/// tabs are named after the subagent.
struct TabBarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var agents = AgentCenter.shared
    @Namespace private var selection
    /// Where a dragged tab would land: the gap before this index.
    @State private var dropGap: Int?

    /// One spring for every tab change so moves, opens, and closes stay in step.
    static let spring = Animation.spring(response: 0.26, dampingFraction: 0.88)

    var body: some View {
        let tabs = store.displayedTabs
        let workspaceId = store.focusedWorkspace?.workspaceId
        let conversations = agents.sessions(in: workspaceId)
        let showingConversation = agents.active(in: workspaceId) != nil
        // A conversation in front means no terminal tab is.
        let focusedId = showingConversation ? nil : store.displayedFocusedTabId

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            let index = tabs.firstIndex(of: tab) ?? 0
                            TabItem(store: store, tab: tab, index: index, count: tabs.count,
                                    isActive: tab.tabId == focusedId, selection: selection)
                                .onDrag { NSItemProvider(object: tab.tabId as NSString) }
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    store: store, index: index, tabs: tabs, gap: $dropGap))
                                .overlay(alignment: .leading) { insertionBar(visible: dropGap == index) }
                                .overlay(alignment: .trailing) {
                                    insertionBar(visible: index == tabs.count - 1 && dropGap == tabs.count)
                                }
                                .id(tab.tabId)
                                .transition(motion.animates(.tabs) ? .tabCollapse : .identity)
                        }
                        ForEach(conversations) { session in
                            ConversationTab(session: session, isActive: agents.activeId == session.id, selection: selection)
                                .id(session.id)
                                .transition(motion.animates(.tabs) ? .tabCollapse : .identity)
                        }
                        NewTabButton(newTab: { store.newTab() },
                                     newConversation: { store.newConversation(engine: $0) },
                                     newAgentTab: { store.newTab(running: $0) })
                    }
                    .animation(motion.animation(.tabs, Self.spring), value: tabs.map(\.tabId))
                    .animation(motion.animation(.tabs, Self.spring), value: focusedId)
                    .animation(motion.animation(.tabs, Self.spring), value: conversations.map(\.id))
                    .animation(motion.animation(.tabs, Self.spring), value: agents.activeId)
                }
                .onChange(of: focusedId) { _, id in
                    guard let id else { return }
                    motion.perform(.tabs, Self.spring) { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
            // The agents boards sit at the far right, for the tab in front.
            if showsAgentsButton { AgentsButton().padding(.trailing, 8) }
            if showsCodexButton { CodexAgentsButton().padding(.trailing, 8) }
        }
        .frame(height: Theme.tabBarHeight)
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
        if let board = agents.board { return board == (engine == .codex ? .codex : .claude) }
        if let conversation = agents.active(in: store.focusedWorkspace?.workspaceId) {
            return conversation.engine == engine
        }
        return focusedTabAgent == engine.agent
    }

    private var focusedTabAgent: String? {
        guard let tabId = store.displayedFocusedTabId else { return nil }
        return AgentBrand.forAgent(store.primaryAgent(in: store.snapshot.agents(inTab: tabId))?.agent)?.id
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
    let store: SessionStore
    let index: Int
    let tabs: [EngineTab]
    @Binding var gap: Int?

    private func gap(for info: DropInfo) -> Int {
        info.location.x < Theme.tabWidth / 2 ? index : index + 1
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
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { store.moveTab(id, toGap: landing) }
        }
        return true
    }
}

private struct TabItem: View {
    @ObservedObject var store: SessionStore
    let tab: EngineTab
    let index: Int
    let count: Int
    let isActive: Bool
    let selection: Namespace.ID
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false
    @State private var renaming = false

    private var title: String { TabAutoName.display(label: tab.label, number: tab.number) }

    var body: some View {
        let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tab.tabId))
        let brand = AgentBrand.forAgent(agent?.agent)

        HStack(spacing: 6) {
            if let agent {
                AgentStateGlyph(status: agent.agentStatus, size: 9)
                    .frame(width: 10)
            }
            if let brand {
                AgentLogo(brand: brand, size: 11)
            }
            if renaming {
                InlineRenameField(initial: TabAutoName.isUnnamed(tab.label) ? "" : tab.label, placeholder: title) { label in
                    renaming = false
                    if let label { store.renameTab(tab.tabId, to: label) }
                }
            } else {
                Text(title)
                    .font(Theme.uiFont)
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            TabCloseButton { store.closeTab(tab.tabId) }
                .opacity(hovered || isActive ? 1 : 0)
        }
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
                            .fill(brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent)
                            .frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
            .animation(motion.animation(.tabs, .easeOut(duration: 0.12)), value: hovered)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { store.closeTab(tab.tabId) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.focusTab(tab.tabId) }
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
            Button("Close Tab") { store.closeTab(tab.tabId) }
            Button("Close Other Tabs") { store.closeTabs(except: tab.tabId) }.disabled(count < 2)
            Button("Close Tabs to the Right") { store.closeTabs(rightOf: tab.tabId) }.disabled(index >= count - 1)
        }
        .help(index < 9 ? "\(title)  ⌘\(index + 1)" : title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.map { "\(title), \(brand?.displayName ?? "agent") \(stateLabel($0.agentStatus))" } ?? title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.focusTab(tab.tabId) }
        .accessibilityAction(named: "Rename") { renaming = true }
        .accessibilityAction(named: "Close") { store.closeTab(tab.tabId) }
    }
}

private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HerdIcon("xmark", size: 15)
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

/// Opening a tab grows it from zero width and closing shrinks it away, so
/// neighbors glide instead of jumping.
private struct WidthCollapse: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)) ?? .zero
        return CGSize(width: ideal.width * progress, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: ideal.width, height: bounds.height))
    }
}

private struct TabCollapseModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        WidthCollapse(progress: progress) {
            content.opacity(progress)
        }
        .clipped()
    }
}

private extension AnyTransition {
    static var tabCollapse: AnyTransition {
        .modifier(active: TabCollapseModifier(progress: 0), identity: TabCollapseModifier(progress: 1))
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
                HerdIcon("plus", size: 15)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New tab")
            Button { menuOpen = true } label: {
                HerdIcon("chevron.down", size: 9)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .accessibilityLabel("New conversation")
            // A menu of Herd's own, so each agent is named by its mark
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
            NewMenuRow(mark: .agent("claude"), title: "New Claude Conversation", keys: "⌘⇧N") {
                choose { newConversation(.claude) }
            }
            NewMenuRow(mark: .agent("codex"), title: "New Codex Conversation") {
                choose { newConversation(.codex) }
            }
            // Every agent found on this machine can have a terminal tab,
            // whether or not Herd knows how to drive it itself.
            if !runnable.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
                Text("Open a tab running")
                    .font(Theme.headerFont)
                    .kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                ForEach(runnable) { agent in
                    NewMenuRow(mark: .agent(agent.id), title: agent.displayName) {
                        choose { newAgentTab(agent) }
                    }
                }
            }
        }
        // Enough inset that a row's highlight clears the popover's own
        // rounded corner; any less and the corner clips it square.
        .padding(8)
        .frame(width: 292)
        .background(Theme.chrome)
    }

    /// Agents with an executable to run. One whose config folder is all
    /// that's left can't open a tab.
    private var runnable: [DiscoveredAgent] { discovery.agents.filter { $0.executablePath != nil } }

    private func choose(_ action: () -> Void) {
        menuOpen = false
        action()
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
                        HerdIcon(name, size: 13).foregroundStyle(Theme.textSecondary)
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
                        Rectangle().fill(brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent).frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { AgentCenter.shared.close(session) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { AgentCenter.shared.activeId = session.id }
        .contextMenu {
            Button("Close Conversation") { AgentCenter.shared.close(session) }
        }
        .help(session.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.engine.displayName) conversation, \(session.title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { AgentCenter.shared.activeId = session.id }
        .accessibilityAction(named: "Close") { AgentCenter.shared.close(session) }
    }
}


/// Opens the Claude agents board; a count shows sessions waiting on you.
private struct AgentsButton: View {
    @ObservedObject private var agents = AgentsStore.shared
    @ObservedObject private var center = AgentCenter.shared
    @State private var hovered = false

    var body: some View {
        let waiting = agents.needsInput.count
        Button { center.showingBoard.toggle() } label: {
            HStack(spacing: 4) {
                if let brand = AgentBrand.forAgent("claude") { AgentLogo(brand: brand, size: 12) }
                HerdIcon("tool.agent", size: 14)
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.terminalBackground)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Color(hex: "FFC107")))
                }
            }
            .foregroundStyle(center.showingBoard ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(center.showingBoard ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Claude agents (⌘⇧A)" + (waiting > 0 ? ": \(waiting) waiting on you" : ""))
        .accessibilityLabel("Claude agents" + (waiting > 0 ? ", \(waiting) need input" : ""))
    }
}
