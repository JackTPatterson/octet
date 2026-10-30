import SwiftUI

/// Horizontal tabs for the focused workspace's tabs. Tabs
/// that run an agent show its state glyph and vendor mark; subagent viewer
/// tabs are named after the subagent.
struct TabBarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject var focusOwner: WindowContext
    var embedded = false
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var agents = AgentCenter.shared
    @Namespace private var selection
    /// Where a dragged tab would land in the strip.
    @State private var dropGap: StripDrop?

    var body: some View {
        let _ = RenderCounter.note("TabBarView")
        let workspaceId = window.focusedWorkspace?.workspaceId
        let conversations = agents.sessions(in: workspaceId)
        let tabs = window.displayedTabs.filter {
            !window.hidesAsConversationBackingTab($0.tabId, sessions: conversations)
        }
        // In split presentation the editor belongs to the terminal tab in
        // front. Give it an outer tab only when it occupies the full surface
        // or is parked for later; otherwise the same split appears twice.
        let showsEditorTab = !window.editor.documents.isEmpty &&
            (!window.editor.isPresented || window.editor.presentation == .full)
        let currentIds = tabs.map { "terminal:\($0.tabId)" }
            + conversations.map { "conversation:\($0.id)" }
            + (showsEditorTab ? ["editor:\(window.id.uuidString)"] : [])
            + window.workspaceContainerLogs.map(\.visualID)
        let orderedIds = window.orderedVisualTabs(currentIds)
        // The terminal tabs the strip shows, in its order: what the tab menu
        // moves among and closes, hidden backing tabs left alone.
        let shownTabIds = orderedIds.compactMap { id -> String? in
            guard id.hasPrefix("terminal:") else { return nil }
            let tabId = String(id.dropFirst("terminal:".count))
            return tabs.contains { $0.tabId == tabId } ? tabId : nil
        }
        let showingConversation = agents.active(in: workspaceId) != nil
        let surfaceFocused = focusOwner.splitContext == nil || focusOwner.panelContext === window
        // A conversation in front means no terminal tab is.
        let focusedId = (showingConversation || (window.editor.isPresented && window.editor.presentation == .full)
                         || window.activeContainerLog != nil) ? nil : window.displayedFocusedTabId

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(orderedIds.enumerated()), id: \.element) { position, id in
                            Group {
                                if id.hasPrefix("terminal:"),
                                   let tab = tabs.first(where: { "terminal:\($0.tabId)" == id }) {
                                    // With container logs showing, ⌘-numbers count every
                                    // tab in the strip, as selectTab(number:) does.
                                    let countsAll = !window.workspaceContainerLogs.isEmpty
                                    let index = countsAll ? position : tabs.firstIndex(of: tab) ?? 0
                                    TabItem(store: store, tab: tab, index: index, count: countsAll ? orderedIds.count : tabs.count,
                                            isActive: tab.tabId == focusedId, surfaceFocused: surfaceFocused,
                                            selection: selection,
                                            handoffTitle: window.agentUIHandoffTabId == tab.tabId
                                                ? window.agentUIHandoffTitle : nil,
                                            paneOver: dropGap.map { $0 == .into(position) } ?? false,
                                            shownTabIds: shownTabIds)
                                        .id(tab.tabId)
                                } else if id.hasPrefix("conversation:"),
                                          let session = conversations.first(where: { "conversation:\($0.id)" == id }) {
                                    ConversationTab(session: session,
                                                    isActive: window.activeContainerLog == nil && agents.active(in: workspaceId)?.id == session.id,
                                                    surfaceFocused: surfaceFocused,
                                                    selection: selection)
                                        .stripDragSource(id, window: window)
                                        .id(session.id)
                                } else if let log = window.workspaceContainerLogs.first(where: { $0.visualID == id }) {
                                    ContainerLogWorkspaceTab(tab: log, isActive: window.activeContainerLog?.id == log.id,
                                                         surfaceFocused: surfaceFocused, selection: selection)
                                        .stripDragSource(id, window: window)
                                        .id(id)
                                } else if id.hasPrefix("editor:") {
                                    EditorOuterTab(workspace: window.editor,
                                                   isActive: window.activeContainerLog == nil && window.editor.isPresented,
                                                   surfaceFocused: surfaceFocused,
                                                   selection: selection)
                                        .stripDragSource(id, window: window)
                                        .id(id)
                                }
                            }
                            .onDrop(of: OctetDragKind.layout, delegate: StripDropDelegate(
                                window: window, position: position, strip: orderedIds, tabs: tabs, gap: $dropGap))
                            .overlay(alignment: .leading) { insertionBar(visible: dropGap == .before(position)) }
                            .overlay(alignment: .trailing) {
                                insertionBar(visible: position == orderedIds.count - 1 && dropGap == .before(orderedIds.count))
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
            // Only what acts on this tab: its thread, its project, its
            // drawer. The agents and the panel are the window's, in its header.
            WorkspaceTabActions(target: window, targetUI: ui)
        }
        .padding(.trailing, 8)
        .frame(height: Theme.tabBarHeight)
        // The rest of the strip takes a tab too, onto the end, as a
        // browser's does; the tabs' own targets sit above this one.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: OctetDragKind.layout, delegate: StripDropDelegate(
                    window: window, position: nil, strip: orderedIds, tabs: tabs, gap: $dropGap))
        }
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        // A drag that ends off the strip never calls dropExited, which would
        // leave the insertion bar showing.
        .onReceive(TabDrag.shared.$item) { if $0 == nil { dropGap = nil } }
    }

    @ViewBuilder
    private func insertionBar(visible: Bool) -> some View {
        if visible {
            Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 5).allowsHitTesting(false)
        }
    }
}

/// What acts on the tab in front: its thread's details, its project's
/// actions and its terminal drawer. Each split's strip has its own.
private struct WorkspaceTabActions: View {
    @ObservedObject var target: WindowContext
    @ObservedObject var targetUI: UIState

    var body: some View {
        OctetIconButton(icon: "menucard", help: OctetShortcut.details.help("Toggle details"),
                        active: targetUI.detailsVisible) { targetUI.detailsVisible.toggle() }
            .padding(.trailing, 4)
        ProjectActionsControl(ui: targetUI, directory: target.focusedDirectory)
            .environmentObject(target)
        TerminalDrawerButton(ui: targetUI)
    }
}

/// Where a drag over the strip would land: in the gap before a position
/// of the strip, or, for a pane, into the terminal tab at a position.
enum StripDrop: Equatable {
    case before(Int)
    case into(Int)
}

/// Drag a tab onto another: dropping on its left half lands before it, on
/// its right half after it. Gaps count places in the strip as it shows, so
/// tabs it hides, and Octet's own tabs between terminal tabs, don't shift
/// where a tab lands. A pane dragged by its handle lands as a tab of its
/// own in a gap, as Warp's, or, over a terminal tab's middle, joins that tab;
/// held there a moment, the tab comes forward so its edges can be aimed at.
private struct StripDropDelegate: DropDelegate {
    /// The window this bar is in: a tab from another window moves into it.
    let window: WindowContext
    /// This item's place in the strip; nil for the empty strip past the tabs.
    let position: Int?
    let strip: [String]
    let tabs: [EngineTab]
    @Binding var gap: StripDrop?

    /// How long a pane held over a tab takes to bring it forward.
    static let springDelay: TimeInterval = 0.5

    private var drag: TabDrag { .shared }

    /// The terminal tab at this position, if that's what's here.
    private var terminalTab: String? {
        guard let position, strip.indices.contains(position), TabStripOrder.isTerminal(strip[position]) else { return nil }
        return String(strip[position].dropFirst(TabStripOrder.terminalPrefix.count))
    }

    private func target(for info: DropInfo) -> StripDrop {
        guard let position else { return .before(strip.count) }
        let x = info.location.x / Theme.tabWidth
        // A pane over a terminal tab: its outer quarters are gaps, its middle
        // half the tab itself.
        if drag.paneId != nil, terminalTab != nil {
            return x < 0.25 ? .before(position) : x > 0.75 ? .before(position + 1) : .into(position)
        }
        return x < 0.5 ? .before(position) : .before(position + 1)
    }

    func validateDrop(info: DropInfo) -> Bool {
        if drag.stripTabId != nil { return drag.sourceWindow === window }
        return drag.tabId != nil || drag.paneId != nil
    }

    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) {
        gap = nil
        drag.springLoad(nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    private func update(_ info: DropInfo) {
        let found = target(for: info)
        // Only a change redraws the strip: the pointer moves many times a frame.
        if found != gap { gap = found }
        if case .into = found, let tab = terminalTab {
            drag.springLoad(tab, after: Self.springDelay) { window.focusTab(tab) }
        } else {
            drag.springLoad(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let landing = target(for: info)
        gap = nil
        drag.springLoad(nil)
        switch (drag.item, landing) {
        case (.pane(let pane)?, .into):
            guard let tab = terminalTab else { return false }
            window.store.movePane(pane, intoTab: tab)
        case (.pane(let pane)?, .before(let at)):
            WindowActions.movePane(pane, toNewTabIn: window, atStripGap: at)
        case (.tab(let id)?, .before(let at)):
            WindowActions.moveTab(id, into: window, atStripGap: at)
        case (.stripTab(let id)?, .before(let at)):
            // Back onto the strip from beside the terminal: a tab again.
            if window.isBeside(id) { window.stopShowingBeside() }
            window.moveVisualTab(id, toGap: at)
        default:
            return false
        }
        return true
    }
}

extension View {
    /// One of Octet's own tabs, which drags along the strip and beside the
    /// terminal, but stays in its window.
    func stripDragSource(_ id: String, window: WindowContext) -> some View {
        octetDragSource(.stripTab, began: {
            TabDrag.shared.begin(stripTab: id, from: window)
            return true
        }, moved: { TabDrag.shared.moved(to: $0) }, ended: { TabDrag.shared.ended($0) })
    }
}

private struct TabItem: View {
    @ObservedObject var store: SessionStore
    @EnvironmentObject private var window: WindowContext
    let tab: EngineTab
    let index: Int
    let count: Int
    let isActive: Bool
    let surfaceFocused: Bool
    let selection: Namespace.ID
    let handoffTitle: String?
    /// A pane dragged by its handle is over this tab's middle: it would join it.
    var paneOver = false
    /// The strip's terminal tabs in order, for the menu's moves and closes.
    var shownTabIds: [String] = []
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var prompts = PromptQueueCenter.shared
    /// Holding ⌘ shows each tab's ⌘-number; rebinding redraws the labels.
    @ObservedObject private var commandHold = CommandHold.shared
    @ObservedObject private var shortcuts = ShortcutOverrides.shared
    @State private var hovered = false
    @State private var renaming = false

    /// The key that jumps here: ⌘1 to ⌘8, or Last Tab's for the last.
    private var jumpKeys: String? { TabJump.shortcut(index: index, count: count)?.keys }

    /// Prompts waiting for this tab's agents to finish their turn.
    private var queued: Int {
        let panes = Set(store.snapshot.panes.filter { $0.tabId == tab.tabId }.map(\.paneId))
        return prompts.queue.items.filter { panes.contains($0.paneId) }.count
    }

    private var title: String { TabAutoName.display(label: tab.label, number: tab.number) }

    /// Ends of the shown terminal tabs, which the menu's moves stop at.
    private var isFirstShown: Bool { shownTabIds.first.map { $0 == tab.tabId } ?? true }
    private var isLastShown: Bool { shownTabIds.last.map { $0 == tab.tabId } ?? true }

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
        // Only a colour picked by hand (here, on the root agent's tab or the
        // workspace) tints the tab; the agent's vendor colour never does.
        let picked = store.tabColor(tab)
        let hue = picked?.hex

        HStack(spacing: 6) {
            if let agent, handoffTitle == nil {
                AgentStateGlyph(status: agent.agentStatus, size: 9)
                    .frame(width: 10)
            }
            if let brand, agent?.isSubagentViewer == true {
                // A subagent's tab: the agent icon, so it reads as a helper
                // rather than another session.
                OctetIcon("tool.agent", size: 11)
                    .foregroundStyle(Theme.textSecondary)
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
                    Text("\(queued)").font(Theme.interfaceFont(10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.08)))
                .help(queued == 1 ? "1 prompt queued for when the agent finishes" : "\(queued) prompts queued for when the agent finishes")
                .accessibilityLabel("\(queued) queued")
            }
            if tab.paneCount > 1, !renaming {
                // One tab holding several panes: say so, so a dropped tab
                // doesn't just seem to vanish.
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 9, weight: .semibold))
                    Text("\(tab.paneCount)").font(Theme.interfaceFont(10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.08)))
                .help("Split into \(tab.paneCount) panes")
                .accessibilityLabel("Split into \(tab.paneCount) panes")
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
                .opacity((hovered || isActive) && !commandHold.revealed ? 1 : 0)
                .overlay(alignment: .trailing) {
                    if commandHold.revealed, let jumpKeys {
                        Keycap(text: jumpKeys, prominent: true)
                            .fixedSize()
                            .transition(motion.animates(.tabs) ? .opacity.combined(with: .scale(scale: 0.85)) : .identity)
                            .accessibilityHidden(true)
                    }
                }
                .animation(motion.animation(.tabs, .easeOut(duration: 0.12)), value: commandHold.revealed)
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
                            .fill((picked?.color ?? Theme.selectionMark).opacity(surfaceFocused ? 1 : 0.28))
                            .frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
            .animation(motion.animation(.tabs, .easeOut(duration: 0.12)), value: hovered)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay {
            if paneOver {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.accent, lineWidth: 1.5).padding(2).allowsHitTesting(false)
            }
        }
        .overlay { MiddleClickCatcher { window.closeTab(tab.tabId) } }
        // Dropped on the terminal, the tab becomes a split; let go outside
        // every window, it gets one of its own.
        .octetDragSource(.tab, enabled: !renaming, began: {
            TabDrag.shared.begin(tab.tabId, store: store, from: window)
            return true
        }, moved: { TabDrag.shared.moved(to: $0) }, ended: { TabDrag.shared.ended($0) })
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
            Button("Move Tab Left") { store.moveTab(tab.tabId, by: -1, among: shownTabIds) }.disabled(isFirstShown)
            Button("Move Tab Right") { store.moveTab(tab.tabId, by: 1, among: shownTabIds) }.disabled(isLastShown)
            Divider()
            Button("Separate Tabs") { window.separatePanes(ofTab: tab.tabId) }
                .disabled(store.snapshot.panes.filter { $0.tabId == tab.tabId }.count < 2)
            Button("Move Tab to New Workspace") { WindowActions.tabToWorkspace(tab.tabId, in: window) }
                .disabled(store.onlyPane(ofTab: tab.tabId) == nil)
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
                store.closeTabs(except: tab.tabId, among: shownTabIds)
            }.disabled(shownTabIds.count < 2)
            Button("Close Tabs to the Right") { store.closeTabs(rightOf: tab.tabId, among: shownTabIds) }.disabled(isLastShown)
        }
        .help(jumpKeys.map { "\(handoffTitle ?? title)  \($0)" } ?? handoffTitle ?? title)
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(OctetShortcut.closeTab.help("Close Tab"))
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
            OctetIconButton(icon: "plus", help: OctetShortcut.newTab.help("New Tab"), action: newTab)
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
                .font(Theme.interfaceFont(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8).padding(.top, 5)
            NewMenuRow(mark: .icon("terminal"), title: "Terminal", keys: OctetShortcut.newTab.keys) { choose(newTab) }
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
                                   keys: launchMode == .chat && entry.engine == AgentSession.Engine.preferred ? OctetShortcut.newConversation.keys : nil) {
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
    let surfaceFocused: Bool
    let selection: Namespace.ID
    @State private var hovered = false
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        let brand = AgentBrand.forAgent(session.engine.agent)
        HStack(spacing: 6) {
            if session.conversation.isRunning {
                LoadingLine(width: 12)
            } else if session.pendingPermission != nil || session.pendingQuestion != nil {
                // Needs you: the shared vocabulary's colour, as in the sidebar.
                Circle().fill(session.agentState.color).frame(width: 6, height: 6).frame(width: 10)
                    .help(session.agentState.title)
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
                .hoverReveal(hovered || isActive)
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
                        Rectangle().fill(Theme.selectionMark.opacity(surfaceFocused ? 1 : 0.28)).frame(height: 2)
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
            // Beside the terminal, it's already in view.
            guard !window.isBeside("conversation:" + session.id) else { return }
            window.showConversation(session.id)
        }
        .contextMenu {
            ConversationActionsMenu(session: session)
            Divider()
            BesideTerminalMenu(stripId: "conversation:" + session.id)
            Divider()
            Button("Close Conversation") { AgentCenter.shared.close(session) }
        }
        .help(session.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.engine.displayName) conversation, \(session.title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.showConversation(session.id) }
        .accessibilityAction(named: "Close") { AgentCenter.shared.close(session) }
    }
}

/// The editor is one outer tab even when it contains several files. Its inner
/// tabs carry the individual buffer names, matching the grouped viewer model.
private struct EditorOuterTab: View {
    @ObservedObject var workspace: EditorWorkspace
    let isActive: Bool
    let surfaceFocused: Bool
    let selection: Namespace.ID
    @EnvironmentObject private var window: WindowContext
    @State private var hovered = false

    /// The only open file, when there is just one.
    private var single: EditorDocument? { workspace.documents.count == 1 ? workspace.activeDocument : nil }

    var body: some View {
        HStack(spacing: 7) {
            // One file is named for itself; several are just "the editor", as
            // the file tabs below it already name each one.
            if let single, let logo = LanguageLogo(path: single.url.path, size: 13) {
                logo.frame(width: 13, height: 13)
            } else {
                OctetIcon(single.map { FileIcons.symbol(forName: $0.name) } ?? "tool.edit", size: 13)
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            }
            Text(single?.name ?? "Editor")
                .font(Theme.uiFont)
                .fontWeight(isActive ? .medium : .regular)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if workspace.documents.count > 1 {
                // Several files in one tab: the count, badged like a split's.
                HStack(spacing: 2) {
                    Image(systemName: "doc.on.doc").font(.system(size: 9, weight: .semibold))
                    Text("\(workspace.documents.count)").font(Theme.interfaceFont(10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.08)))
                .help("\(workspace.documents.count) files open")
                .accessibilityLabel("\(workspace.documents.count) files open")
            }
            Spacer(minLength: 4)
            if !workspace.dirtyDocuments.isEmpty {
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
            }
            TabCloseButton { workspace.closeEditor() }
                .hoverReveal(hovered || isActive)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(width: Theme.tabWidth).frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Theme.selectionMark.opacity(surfaceFocused ? 1 : 0.28)).frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !window.isBeside("editor:" + window.id.uuidString) else { return }
            window.showEditor()
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Save") { workspace.save() }.disabled(workspace.activeDocument?.isDirty != true)
            Button("Save All") { workspace.saveAll() }.disabled(workspace.dirtyDocuments.isEmpty)
            Divider()
            BesideTerminalMenu(stripId: "editor:" + window.id.uuidString)
            Divider()
            Button("Close Editor") { workspace.closeEditor() }
        }
        .help(single?.url.path ?? "Editor")
        .accessibilityLabel("Editor")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.showEditor() }
        .accessibilityAction(named: "Close") { workspace.closeEditor() }
    }
}

/// Uses the same outer-tab chrome as the editor and conversations.
private struct ContainerLogWorkspaceTab: View {
    let tab: WorkspaceContainerLog
    let isActive: Bool
    let surfaceFocused: Bool
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
            TabCloseButton { window.closeContainerLogs(tab.id) }.hoverReveal(hovered || isActive)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(width: Theme.tabWidth).frame(maxHeight: .infinity)
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Theme.selectionMark.opacity(surfaceFocused ? 1 : 0.28)).frame(height: 2)
                    }.matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .overlay { MiddleClickCatcher { window.closeContainerLogs(tab.id) } }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !window.isBeside(tab.visualID) else { return }
            window.focusContainerLogs(tab.id)
        }
        .onHover { hovered = $0 }
        .contextMenu {
            BesideTerminalMenu(stripId: tab.visualID)
            Divider()
            Button("Close Logs") { window.closeContainerLogs(tab.id) }
        }
        .help("\(tab.name) · \(tab.context)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusContainerLogs(tab.id) }
        .accessibilityAction(named: "Close") { window.closeContainerLogs(tab.id) }
    }
}

/// The menu way to put one of Octet's own tabs beside the terminal, and
/// back, for when it isn't dragged there.
private struct BesideTerminalMenu: View {
    let stripId: String
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        Menu("Show Beside Terminal") {
            ForEach([SplitEdge.left, .right, .top, .bottom], id: \.self) { edge in
                Button(edge == .top ? "Above" : edge == .bottom ? "Below" : edge.sideName) {
                    window.showBeside(stripId, edge: edge)
                }
                .disabled(window.companion?.stripId == stripId && window.companion?.edge == edge)
            }
        }
        if window.isBeside(stripId) {
            Button("Show Over Terminal") { window.stopShowingBeside() }
        }
    }
}
