import Combine
import SwiftUI

/// Vertical tabs: project groups with uppercase headers and
/// bordered workspace cards tinted by the running agent's vendor hue.
struct SidebarView: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    var width: CGFloat = Theme.sidebarWidth
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var waits = WaitCenter.shared
    @ObservedObject private var idle = IdleCenter.shared
    @State private var collapsedGroups: Set<String> = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if searching {
                        searchResults
                    } else {
                        ReadyWaits()
                        ForEach(store.activeGroups) { group in
                            groupSection(group)
                        }
                    }
                    if store.snapshot.workspaces.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.isConnected ? "No workspaces" : "Starting the terminal…")
                                .font(Theme.uiFont)
                                .foregroundStyle(Theme.textTertiary)
                            if store.isConnected {
                                Text("Press ⌘N or double-click here to start one.")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                }
                .padding(.vertical, 8)
                .animation(motion.animation(.sidebar), value: store.activeGroups)
            }
            .scrollIndicators(.hidden)
            // Double-click empty sidebar space for a new workspace.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { window.newWorkspace() }
            }
            // While searching, idle workspaces are among the results.
            if !searching {
                TipCard(store: store)
            }
            if !searching, !waits.waiting.isEmpty {
                WaitsDock()
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
            }
            if !searching, !store.idleWorkspaces.isEmpty || !idle.sleeping.isEmpty {
                IdleDock(store: store)
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion.animation(.sidebar), value: store.idleWorkspaces.isEmpty)
        .animation(motion.animation(.sidebar), value: waits.waiting.isEmpty)
        .frame(width: width)
        .background(Theme.sidebar)
        // Peeks come back once the pointer has left the sidebar.
        .onHover { if !$0 { HoverIntent.navigating = false } }
        .onReceive(window.ui.$sidebarSearchRequest.dropFirst()) { _ in searchFocused = true }
    }

    private var controlBar: some View {
        VStack(spacing: 6) {
            searchField
            ControlButton(title: "New workspace", icon: "plus", shortcut: "⌘N") {
                window.newWorkspace()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            OctetIcon("magnifyingglass", size: 13)
                .foregroundStyle(Theme.textTertiary)
            TextField("Search workspaces", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .focused($searchFocused)
                .onSubmit(openFirstResult)
                .onExitCommand(perform: clearSearch)
            if !query.isEmpty {
                Button(action: clearSearch) {
                    OctetIcon("xmark.circle.fill", size: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Clear the search")
            } else if !searchFocused {
                Text(OctetShortcut.searchWorkspaces.display)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(searchFocused ? Theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
            .strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
    }

    /// The workspaces the query finds, under their groups' names, then the
    /// idle ones it finds; groups aren't collapsed while searching.
    private var matches: (groups: [ProjectGroup], idle: [EngineWorkspace]) {
        let groups = store.activeGroups.compactMap { group -> ProjectGroup? in
            let hits = group.workspaces.filter { found($0, group: group.name) }
            return hits.isEmpty ? nil : ProjectGroup(id: group.id, name: group.name, workspaces: hits)
        }
        return (groups, store.idleWorkspaces.filter { found($0, group: nil) })
    }

    private func found(_ workspace: EngineWorkspace, group: String?) -> Bool {
        let titles = AgentCenter.shared.sessions(in: workspace.workspaceId).map(\.title)
        let fields = SidebarSearch.fields(of: workspace, in: store.snapshot, group: group,
                                          branch: store.branches[workspace.workspaceId], extra: titles)
        return SidebarSearch.matches(query, fields: fields)
    }

    @ViewBuilder
    private var searchResults: some View {
        let matches = matches
        ForEach(matches.groups) { group in
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader(group.name)
                ForEach(group.workspaces) { workspace in
                    WorkspaceCard(store: store, workspace: workspace).padding(.horizontal, 8)
                }
            }
        }
        if !matches.idle.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader("Idle")
                ForEach(matches.idle) { workspace in
                    WorkspaceCard(store: store, workspace: workspace).padding(.horizontal, 8)
                }
            }
        }
        if matches.groups.isEmpty, matches.idle.isEmpty, !store.snapshot.workspaces.isEmpty {
            Text("No workspace matches “\(query.trimmingCharacters(in: .whitespaces))”")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }

    private func resultsHeader(_ name: String) -> some View {
        Text(name.uppercased())
            .font(Theme.headerFont)
            .kerning(0.4)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    /// Return opens the first workspace found and gives the terminal back
    /// the keyboard.
    private func openFirstResult() {
        guard searching else { return }
        let matches = matches
        guard let first = matches.groups.first?.workspaces.first ?? matches.idle.first else { return }
        clearSearch()
        window.focusWorkspace(first.workspaceId)
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
    }

    @ViewBuilder
    private func groupSection(_ group: ProjectGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                motion.perform(.sidebar) {
                    if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    OctetIcon(Self.isRepository(group) ? "arrow.triangle.branch" : "folder", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                    Text(group.name.uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(group.workspaces.count == 1 ? "1 workspace" : "\(group.workspaces.count) workspaces")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    OctetIcon("chevron.down", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .help(Self.groupHelp(group))

            if !collapsed {
                // Workspaces on the same branch stack together under one chip.
                ForEach(BranchRuns.make(group.workspaces, branch: { store.branches[$0.workspaceId] },
                                        worktree: { $0.worktree })) { run in
                    VStack(spacing: 4) {
                        ForEach(run.workspaces) { workspace in
                            WorkspaceCard(store: store, workspace: workspace)
                        }
                        if !run.isBare {
                            BranchChip(run: run)
                        }
                    }
                    .padding(.horizontal, 8)
                    .transition(motion.animates(.sidebar)
                        ? .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
                        : .identity)
                }
            }
        }
    }
}

extension SidebarView {
    /// Whether a group is a git repository, rather than a plain folder.
    static func isRepository(_ group: ProjectGroup) -> Bool {
        group.id != ProjectGroup.otherId && FileManager.default.fileExists(atPath: group.id + "/.git")
    }

    /// What a group header stands for: workspaces are grouped by the project
    /// their tab's folder is in, and move when that folder does.
    static func groupHelp(_ group: ProjectGroup) -> String {
        guard group.id != ProjectGroup.otherId else {
            return "Workspaces whose folder isn't in a repository or project folder."
        }
        let kind = isRepository(group) ? "repository" : "project folder"
        return "Workspaces in the \(kind) \(abbreviateHome(group.id)). A workspace joins the group of the folder its tab is in, and moves if you cd elsewhere."
    }
}

/// The branch (and worktree) a run of workspaces shares, as a small card
/// tucked under them.
private struct BranchChip: View {
    let run: BranchRun
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            OctetIcon(run.worktreePath == nil ? "arrow.triangle.branch" : "square.stack.3d.up", size: 12)
                .foregroundStyle(Theme.textTertiary)
            if let branch = run.branch {
                Text(branch)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let worktree = run.worktreeName {
                Text(run.branch == nil ? worktree : "worktree \(worktree)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if run.workspaces.count > 1 {
                Text("\(run.workspaces.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .help("\(run.workspaces.count) workspaces on this branch")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Theme.hover : Theme.card.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border.opacity(0.5), lineWidth: 1))
        .onHover { hovered = $0 }
        .help(run.worktreePath.map { "Worktree at \($0)" } ?? "Branch \(run.branch ?? "")")
    }
}

/// How much of the model's window the conversation is using.
/// How much of the model's window the conversation is using, as a ring
/// that fills clockwise; the number is a hover away.
private struct ContextChip: View {
    let usage: TwinUsage
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        Group {
            if let fraction = usage.contextFraction {
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .animation(motion.animation(.connections, .easeOut(duration: 0.4)), value: fraction)
            } else {
                // No window to measure against: just how much is in play.
                Text(usage.label)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .help(detail)
        .accessibilityElement()
        .accessibilityLabel("Context")
        .accessibilityValue(usage.label)
    }

    /// Quiet until it matters, then increasingly not.
    private var colour: Color {
        switch usage.contextFraction ?? 0 {
        case ..<0.7: Theme.textSecondary
        case ..<0.9: Color(hex: "e0af68")
        default: Color(hex: "e5484d")
        }
    }

    private var detail: String {
        let used = TwinUsage.compact(usage.currentContextTokens)
        guard let window = usage.effectiveContextWindow else { return "\(used) of context in play" }
        return "\(usage.label) of context used · \(used) of \(TwinUsage.compact(window))"
    }
}

private struct WorkspaceCard: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    @State private var hovered = false
    @State private var renaming = false
    @StateObject private var peek = HoverIntent()
    @ObservedObject private var conversations = AgentCenter.shared
    @ObservedObject private var portsWatcher = PortsWatcher.shared
    @ObservedObject private var workspaceIcons = WorkspaceIconStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Servers running here, e.g. each worktree's dev server.
        let ports = portsWatcher.ports(inWorkspace: workspace.workspaceId, snapshot: store.snapshot)
        VStack(spacing: 4) {
            card
            if !ports.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(ports, id: \.self) { port in
                            PortButton(port: port, service: portsWatcher.services[port],
                                       owners: portsWatcher.listeners[port] ?? []) {
                                if let url = URL(string: "http://localhost:" + String(port)) { openURL(url) }
                            }
                        }
                    }
                }
                // Hidden even with "Show scroll bars: Always" or a mouse
                // attached, which showsIndicators: false doesn't cover.
                .scrollIndicators(.never)
                .transition(motion.animates(.sidebar) ? .opacity : .identity)
            }
        }
        .animation(motion.animation(.sidebar), value: ports)
    }

    @ViewBuilder private var card: some View {
        let snapshot = store.snapshot
        let isSelected = workspace.workspaceId == window.focusedWorkspace?.workspaceId
        // Open in another window: a click brings that window forward.
        let elsewhere = WindowRegistry.shared.window(showing: workspace.workspaceId).map { $0 !== window } ?? false
        let agents = snapshot.agents(inWorkspace: workspace.workspaceId)
        let agent = store.primaryAgent(in: agents)
        let session = conversations.active(in: workspace.workspaceId)
            ?? conversations.sessions(in: workspace.workspaceId).first
        let handoffAgent = window.agentUIHandoffWorkspaceId == workspace.workspaceId
            ? window.agentUIHandoff : nil
        // Once a native agent starts moving into Octet, the workspace adopts
        // conversation styling immediately and keeps it after the terminal
        // process disappears.
        let brand = handoffAgent.flatMap(AgentBrand.forAgent)
            ?? session.flatMap { AgentBrand.forAgent($0.engine.agent) }
            ?? AgentBrand.forAgent(agent?.agent)
        let status = handoffAgent != nil ? (agent?.agentStatus ?? .working)
            : session.map(Self.status) ?? agent?.agentStatus ?? workspace.agentStatus
        let directory = snapshot.directory(ofWorkspace: workspace.workspaceId)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // With no agent here, a running server's logo takes the
                // empty state's place.
                // A plugin's picture of the project (its favicon or app
                // icon), with the agent's state as a dot on its corner.
                if let projectIcon = workspaceIcons.image(for: directory) {
                    WorkspaceProjectIcon(image: projectIcon, status: status)
                        .frame(width: 12)
                } else if status == .unknown,
                   let logo = LanguageLogo(service: portsWatcher.service(inWorkspace: workspace.workspaceId, snapshot: snapshot), size: 11) {
                    logo.frame(width: 12)
                        .help("Serving on localhost")
                } else {
                    AgentStateGlyph(status: status)
                        .frame(width: 12)
                }
                if renaming {
                    InlineRenameField(initial: workspace.label, placeholder: "Workspace name") { label in
                        renaming = false
                        store.renameWorkspace(workspace.workspaceId, to: label, from: workspace.label)
                    }
                } else {
                    Text(workspace.label)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                let agentCount = session == nil ? agents.count : 1
                if !renaming, agentCount > 1 {
                    AgentCountBadge(count: agentCount)
                }
                if store.isPinned(workspace.workspaceId) {
                    OctetIcon("pin.fill", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Pinned: never moves to Idle")
                }
                Spacer(minLength: 0)
                if elsewhere {
                    OctetIcon("rectangle.on.rectangle", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Open in another window. Click to bring it forward.")
                        .accessibilityLabel("Open in another window")
                }
                // Room for the close button, which floats over the card so
                // its appearing can never move or resize anything.
                Color.clear.frame(width: 18, height: 1)
            }
            .frame(minHeight: 18)
            // Always shown: the folder is what decides the card's group.
            if let directory {
                Text(abbreviateHome(directory))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let from = store.movedWorkspaces[workspace.workspaceId] {
                HStack(spacing: 4) {
                    OctetIcon("arrow.right", size: 11)
                    Text("Moved here from \(from)")
                        .font(Theme.captionFont)
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.accent)
                .help("Its tab's folder is now in this project, so the workspace moved with it.")
                .transition(.opacity)
            }
            HStack(spacing: 5) {
                if let brand {
                    AgentLogo(brand: brand, size: 11)
                    Text(agentLine(status: status, brand: brand))
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    // How full this agent's context is, before it bites.
                    if let usage = store.usageTracker.usage(forTerminal: agent?.terminalId),
                       !usage.label.isEmpty {
                        Spacer(minLength: 4)
                        ContextChip(usage: usage)
                    }
                } else if workspace.tabCount > 1 {
                    OctetIcon("terminal", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(workspace.tabCount) tabs")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            // Subagents that left for a worktree, repo or folder of their own.
            let locations = store.agentLocations(inWorkspace: workspace.workspaceId)
            if !locations.isEmpty {
                AgentLocationRow(locations: locations)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(isSelected: isSelected,
                                   hue: store.workspaceColor(workspace.workspaceId)?.hex ?? brand?.hueHex))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(isSelected ? Theme.textTertiary.opacity(0.55)
                    : (hovered ? Theme.border : Theme.border.opacity(0.6)), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay(alignment: .topTrailing) {
            let showsClose = hovered && !renaming
            WorkspaceCloseButton { store.closeWorkspace(workspace.workspaceId) }
                .padding(.top, 8)
                .padding(.trailing, 10)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            // Not for the workspace already showing, nor while renaming or
            // dragging a tab over it.
            peek.source(hovering && !isSelected && !renaming
                        && TabDrag.shared.tabId == nil && TabDrag.shared.workspaceId == nil)
        }
        .popover(isPresented: $peek.isShown, arrowEdge: .trailing) {
            WorkspacePeek(store: store, workspace: workspace) { peek.close() }
                .environmentObject(window)
                .onHover { peek.card($0) }
        }
        .onTapGesture {
            peek.close()
            HoverIntent.navigating = true
            window.focusWorkspace(workspace.workspaceId)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        // Dragged out of the window, the workspace gets a window of its own.
        .onDrag {
            peek.close()
            TabDrag.shared.begin(workspace: workspace.workspaceId, from: window)
            return NSItemProvider(object: workspace.workspaceId as NSString)
        }
        .contextMenu {
            WorkspaceOrganizeMenu(store: store, workspace: workspace) { renaming = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusWorkspace(workspace.workspaceId) }
        .accessibilityAction(named: "Rename") { renaming = true }
        .accessibilityAction(named: "Close") { store.closeWorkspace(workspace.workspaceId) }
    }

    private func cardBackground(isSelected: Bool, hue: String?) -> some View {
        ZStack {
            (isSelected ? Theme.cardSelected : (hovered ? Theme.hover : Theme.card))
            if let hue {
                Color(hex: hue).opacity(hovered ? Theme.tabColorHoverOpacity : Theme.tabColorOpacity)
            }
        }
    }

    private static func status(_ session: AgentSession) -> EngineAgentStatus {
        if session.pendingPermission != nil || session.pendingQuestion != nil { return .blocked }
        return session.conversation.isRunning ? .working : .idle
    }

    private func agentLine(status: EngineAgentStatus, brand: AgentBrand) -> String {
        "\(brand.displayName) \(stateLabel(status))"
    }
}

func stateLabel(_ status: EngineAgentStatus) -> String {
    switch status {
    case .working: return "working"
    case .blocked: return "needs input"
    case .done: return "done"
    case .idle: return "idle"
    case .unknown: return ""
    }
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

struct ControlButton: View {
    let title: String
    let icon: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OctetIcon(icon, size: 15)
                Text(title).font(Theme.uiFontMedium)
                if let shortcut {
                    Text(shortcut).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Context menu items shared by workspace cards and idle rows.
struct WorkspaceOrganizeMenu: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    /// Starts renaming where the workspace is shown.
    let rename: () -> Void

    var body: some View {
        let id = workspace.workspaceId
        Button("Rename Workspace…", action: rename)
        if store.isWorkspaceManuallyNamed(id), SettingsStore.shared.values.autoNameWorkspaces {
            Button("Name After Its Work") { store.resumeWorkspaceAutoNaming(id) }
        }
        PluginMenuItems(place: .workspace, directory: store.snapshot.directory(ofWorkspace: id), workspaceId: id)
        Divider()
        TabColorPicker(title: "Workspace Color", selection: Binding(
            get: { store.workspaceColor(id) },
            set: { store.setWorkspaceColor(id, $0) }))
        Divider()
        let agents = store.snapshot.agents(inWorkspace: id).filter { AgentOffer.agentId($0) != nil }
        if agents.count == 1, let agent = agents.first {
            Button("Open on Octet UI") { window.openOnOctetUI(agent) }
            Divider()
        } else if agents.count > 1 {
            Menu("Open on Octet UI") {
                ForEach(agents, id: \.paneId) { agent in
                    Button(label(for: agent)) { window.openOnOctetUI(agent) }
                }
            }
            Divider()
        }
        if store.isPinned(id) {
            Button("Unpin") { store.setPinned(id, false) }
        } else {
            Button("Pin to Keep in View") { store.setPinned(id, true) }
        }
        if store.idleWorkspaces.contains(where: { $0.workspaceId == id }) {
            Button("Keep in View Now") {
                WaitCenter.shared.cancelSnooze(of: id)
                store.keepInView(id)
                window.focusWorkspace(id)
            }
        } else {
            Button("Move to Idle") { store.markIdle(id) }
        }
        IdleUntilMenu(workspaceId: id)
        Button("Wait for Something…") { WaitCenter.shared.compose(workspaceId: id) }
        Button("Sleep") { IdleCenter.shared.sleep([workspace]) }
            .help("Closes its terminals and keeps a note to bring it back as it was, agents resumed")
        if IdleCenter.shared.work[id]?.mergedWorktree == true {
            Button("Close and Remove Worktree…") { IdleCenter.shared.removeMergedWorktree(workspace, window: window) }
        }
        // The workspace's Claude Code conversations, carried on in another
        // folder; see ConversationMover.
        let movable = AgentCenter.shared.sessions(in: id).filter(\.canMove)
        Button(movable.count > 1 ? "Move \(movable.count) Conversations To…" : "Move Conversation To…") {
            let from = store.snapshot.directory(ofWorkspace: id) ?? NSHomeDirectory()
            ConversationMover.moveAfterPicking(movable, from: from, window: window)
        }
        .disabled(movable.isEmpty)
        .help(movable.isEmpty
              ? "Moves this workspace's Claude Code conversations to another folder; none here can move now"
              : "Carry on with this workspace's Claude Code conversations in another folder")
        if AgentDiscoveryStore.shared.agents.contains(where: { $0.id == "claude" && $0.executablePath != nil }) {
            Button("New Cloud Session Here…") {
                // In the window showing it, which the session will open in.
                let target = WindowRegistry.shared.window(showing: id) ?? window
                target.focusWorkspace(id)
                target.ui.paletteStart = [PaletteCatalog.claudeCloudItemId]
                target.ui.paletteVisible = true
            }
        }
        Divider()
        if let other = WindowRegistry.shared.window(showing: id), other !== window {
            Button("Show Window") { other.bringForward() }
        } else {
            Button("Move Workspace to New Window") { WindowActions.moveWorkspaceToNewWindow(id, from: window) }
        }
        Divider()
        Button("Close Workspace") { store.closeWorkspace(id) }
    }

    /// The agent's name and its tab, to tell several apart.
    private func label(for agent: EngineAgent) -> String {
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        guard let tab = store.snapshot.tabs.first(where: { $0.tabId == agent.tabId }) else { return name }
        return "\(name) · \(TabAutoName.display(label: tab.label, number: tab.number))"
    }
}

/// "Keep in Idle Until": out of the way until a time, or until something
/// happens (a wait with no step, that only brings it back).
struct IdleUntilMenu: View {
    let workspaceId: String

    var body: some View {
        let center = WaitCenter.shared
        Menu("Keep in Idle Until") {
            Button("In an Hour") { center.snooze(workspaceId: workspaceId, until: .date(Date().addingTimeInterval(3600)), title: "in an hour") }
            if let morning = Self.morning(daysAhead: 1) {
                Button("Tomorrow Morning") { center.snooze(workspaceId: workspaceId, until: .date(morning), title: "tomorrow morning") }
            }
            if let monday = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                                       matchingPolicy: .nextTime) {
                Button("Monday Morning") { center.snooze(workspaceId: workspaceId, until: .date(monday), title: "Monday morning") }
            }
            Divider()
            Button("Something Happens…") { center.compose(workspaceId: workspaceId, snooze: true) }
        }
    }

    static func morning(daysAhead: Int) -> Date? {
        Calendar.current.date(byAdding: .day, value: daysAhead, to: Date())
            .flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
    }
}

/// Bottom dock of workspaces that haven't been used in a while: compact
/// one-line rows so active work stays in view, what each still holds, and
/// those put to sleep.
struct IdleDock: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var idle = IdleCenter.shared
    @EnvironmentObject private var window: WindowContext
    @AppStorage("octet.idleDock.collapsed") private var collapsed = false

    /// Past this many rows, idle workspaces are grouped by project.
    private static let groupAfter = 6

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 6) {
                Button {
                    motion.perform(.sidebar) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        OctetIcon("chevron.down", size: 12)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                        Text("IDLE").font(Theme.headerFont).kerning(0.4)
                        Text("\(store.idleWorkspaces.count)")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                        Text("· unused \(IdleDock.thresholdLabel(store.idleAfter))+")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !idle.selection.isEmpty {
                    Text("\(idle.selection.count) picked").font(Theme.captionFont).foregroundStyle(Theme.accent)
                }
                Menu {
                    actions
                } label: {
                    OctetIcon("xmark.bin", size: 14)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.textTertiary)
                .help("Close, sleep or stop idle workspaces")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if !collapsed {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            if !section.name.isEmpty {
                                Text(section.name.uppercased()).font(Theme.captionFont.weight(.semibold)).kerning(0.3)
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 8).padding(.top, 4)
                            }
                            ForEach(section.workspaces) { workspace in
                                IdleRow(store: store, workspace: workspace)
                                    .transition(motion.animates(.sidebar) ? .move(edge: .top).combined(with: .opacity) : .identity)
                            }
                        }
                        if !idle.sleeping.isEmpty {
                            Text("ASLEEP").font(Theme.captionFont.weight(.semibold)).kerning(0.3)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8).padding(.top, 6)
                            ForEach(idle.sleeping) { record in SleepingRow(record: record) }
                        }
                    }
                    .animation(motion.animation(.sidebar), value: store.idleWorkspaces)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(rowCount) * 25 + 6, 240))
                .transition(motion.animates(.sidebar) ? .opacity : .identity)
            }
        }
        .background(Theme.chrome)
        .onAppear { idle.refresh() }
    }

    private var rowCount: Int {
        let headers = sections.filter { !$0.name.isEmpty }.count
        return store.idleWorkspaces.count + headers + (idle.sleeping.isEmpty ? 0 : idle.sleeping.count + 1)
    }

    private struct Section: Identifiable {
        let name: String
        let workspaces: [EngineWorkspace]
        var id: String { name }
    }

    /// One unnamed section, or one per project once there are many.
    private var sections: [Section] {
        let all = store.idleWorkspaces
        let projects = Dictionary(grouping: all) { store.projectName(of: $0.workspaceId) ?? "Other" }
        guard all.count > Self.groupAfter, projects.count > 1 else { return [Section(name: "", workspaces: all)] }
        // In the order their newest workspace went idle.
        var order: [String] = []
        for workspace in all {
            let name = store.projectName(of: workspace.workspaceId) ?? "Other"
            if !order.contains(name) { order.append(name) }
        }
        return order.map { Section(name: $0, workspaces: projects[$0] ?? []) }
    }

    @ViewBuilder private var actions: some View {
        let picked = store.idleWorkspaces.filter { idle.selection.contains($0.workspaceId) }
        if !picked.isEmpty {
            Button("Close \(picked.count) Picked…") { idle.close(picked) }
            Button("Sleep \(picked.count) Picked") { idle.sleep(picked) }
            Button("Clear Picks") { idle.selection = [] }
            Divider()
        }
        Button("Close All Idle…") { idle.close(store.idleWorkspaces) }
            .disabled(store.idleWorkspaces.isEmpty)
        Button("Sleep All Idle") { idle.sleep(store.idleWorkspaces) }
            .disabled(store.idleWorkspaces.isEmpty)
        let ports = idle.idlePorts
        if !ports.isEmpty {
            Button("Stop \(ports.count == 1 ? "the Server" : "\(ports.count) Servers") in Idle…") { idle.stopIdleServers() }
        }
        if !idle.sleeping.isEmpty {
            Divider()
            Button("Forget \(Recap.count(idle.sleeping.count, "Sleeping Workspace"))") {
                for record in idle.sleeping { idle.forget(record.id) }
            }
        }
        Divider()
        Text("⌘-click rows to pick several")
    }

    static func thresholdLabel(_ seconds: TimeInterval) -> String {
        seconds >= 86_400 ? "\(Int(seconds / 86_400))d"
            : seconds >= 3600 ? "\(Int(seconds / 3600))h"
            : "\(Int(seconds / 60))m"
    }
}

private struct IdleRow: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    @ObservedObject private var idle = IdleCenter.shared
    @ObservedObject private var waits = WaitCenter.shared
    @State private var hovered = false
    @State private var renaming = false
    @StateObject private var peek = HoverIntent()

    var body: some View {
        let id = workspace.workspaceId
        let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: id))
        let brand = AgentBrand.forAgent(agent?.agent)
        let work = idle.work[id]
        let picked = idle.selection.contains(id)
        let snooze = waits.snooze(of: id)
        HStack(spacing: 6) {
            Group {
                if let brand {
                    AgentLogo(brand: brand, size: 10).saturation(0.2).opacity(0.8)
                } else {
                    OctetIcon("terminal", size: 12)
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 12)
            if renaming {
                InlineRenameField(initial: workspace.label, placeholder: "Workspace name") { label in
                    renaming = false
                    store.renameWorkspace(id, to: label, from: workspace.label)
                }
            } else {
                Text(workspace.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(hovered || picked ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            if !renaming, let project = store.projectName(of: id),
               project.caseInsensitiveCompare(workspace.label) != .orderedSame {
                Text(project)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !renaming {
                if snooze != nil {
                    OctetIcon("clock", size: 11).foregroundStyle(Theme.textTertiary)
                        .help("Comes back " + (snooze.map { $0.isManual ? "when you say" : "when " + $0.condition.description } ?? ""))
                }
                if work?.mergedWorktree == true {
                    Text("merged").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4).frame(height: 14)
                        .background(Capsule().fill(Theme.cardSelected))
                        .help("A worktree whose branch is merged; its menu can remove it")
                }
                if let port = work?.ports.first {
                    Text(":\(String(port))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        .help("A server is still listening here")
                }
                if let work, work.uncommitted > 0 || work.unpushed > 0 {
                    Circle().fill(Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                        .help(work.risks.map { "Not saved anywhere else: " + $0 } ?? "")
                }
            }
            // The age and the close button share a spot; the button floats
            // over it, so swapping them never changes the row.
            let showsClose = hovered && !renaming
            Text(WorkspaceActivity.ageLabel(since: store.activity.lastActive(id)))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .opacity(showsClose ? 0 : 1)
                .overlay(alignment: .trailing) {
                    WorkspaceCloseButton { idle.close([workspace]) }
                        .opacity(showsClose ? 1 : 0)
                        .allowsHitTesting(showsClose)
                        .accessibilityHidden(!showsClose)
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
            .fill(picked ? Theme.cardSelected : hovered ? Theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(picked ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            peek.source(hovering && !renaming)
        }
        .onTapGesture {
            peek.close()
            if NSEvent.modifierFlags.contains(.command) {
                if picked { idle.selection.remove(id) } else { idle.selection.insert(id) }
            } else {
                idle.selection = []
                window.focusWorkspace(id)
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        .onDrag {
            TabDrag.shared.begin(workspace: id, from: window)
            return NSItemProvider(object: id as NSString)
        }
        .popover(isPresented: $peek.isShown, arrowEdge: .trailing) {
            IdlePeek(store: store, workspace: workspace) { peek.close() }
                .onHover { peek.card($0) }
        }
        .contextMenu { WorkspaceOrganizeMenu(store: store, workspace: workspace) { renaming = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.label), idle, last used \(WorkspaceActivity.ageLabel(since: store.activity.lastActive(id))) ago"
                            + (work?.risks.map { ", holds \($0)" } ?? ""))
    }
}

/// What an idle workspace was doing and still holds, on hover: where it
/// left off, so it needn't be opened to find out.
private struct IdlePeek: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    let close: () -> Void
    @ObservedObject private var idle = IdleCenter.shared

    var body: some View {
        let id = workspace.workspaceId
        let work = idle.work[id]
        let sessions = AgentCenter.shared.sessions(in: id)
        let latest = sessions.max { ($0.conversation.items.last?.createdAt ?? .distantPast) < ($1.conversation.items.last?.createdAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.label).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Text(place).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            if let latest, let reply = HandoffBrief.lastReply(in: latest.conversation.items) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(latest.engine.displayName) last said").font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textTertiary)
                    Text(HandoffBrief.clip(reply, 280)).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let files = HandoffBrief.changedFiles(in: latest.conversation.items, cwd: latest.cwd)
                    if !files.isEmpty {
                        Text("Changed " + Recap.count(files.count, "file")).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if let check = Verification.assess(latest.conversation.items).message {
                        Text(check).font(Theme.captionFont).foregroundStyle(Color.orange)
                    }
                }
            } else if let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: id)) {
                Text("\(AgentBrand.forAgent(agent.agent)?.displayName ?? "Agent") · \(agent.agentStatus.rawValue)")
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
            if let wait = WaitCenter.shared.waits.first(where: { $0.origin.workspaceId == id && $0.state == .waiting }) {
                Text((wait.isSnooze ? "Back when " : "Waiting for ") + wait.title)
                    .font(Theme.captionFont).foregroundStyle(Theme.accent).lineLimit(2)
            }
            if let risks = work?.risks {
                Text("Not saved anywhere else: " + risks).font(Theme.captionFont).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if work != nil {
                Text("Nothing unsaved").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                OctetButton(title: "Open", kind: .primary, compact: true) {
                    close()
                    window.focusWorkspace(id)
                }
                OctetButton(title: "Sleep", kind: .secondary, compact: true) {
                    close()
                    idle.sleep([workspace])
                }
                if work?.mergedWorktree == true {
                    OctetButton(title: "Remove Worktree…", kind: .secondary, compact: true) {
                        close()
                        idle.removeMergedWorktree(workspace, window: window)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Theme.chrome)
    }

    private var place: String {
        let id = workspace.workspaceId
        var parts: [String] = []
        if let directory = store.snapshot.directory(ofWorkspace: id) { parts.append(HandoffBrief.abbreviate(directory)) }
        if let branch = idle.work[id]?.branch ?? store.branches[id] { parts.append(branch) }
        parts.append("used " + WorkspaceActivity.ageLabel(since: store.activity.lastActive(id)) + " ago")
        return parts.joined(separator: " · ")
    }
}

/// A workspace put to sleep: click to wake it as it was.
private struct SleepingRow: View {
    @EnvironmentObject private var window: WindowContext
    let record: SleepingWorkspace
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            OctetIcon("moon.zzz", size: 12).foregroundStyle(Theme.textTertiary).frame(width: 12)
            Text(record.label).font(.system(size: 11.5)).foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 4)
            Text(hovered ? "Wake" : WorkspaceActivity.ageLabel(since: record.sleptAt))
                .font(hovered ? Theme.captionFont.weight(.medium) : .system(size: 10.5, design: .monospaced))
                .foregroundStyle(hovered ? Theme.accent : Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { IdleCenter.shared.wake(record.id, in: window) }
        .contextMenu {
            Button("Wake") { IdleCenter.shared.wake(record.id, in: window) }
            Button("Forget") { IdleCenter.shared.forget(record.id) }
        }
        .help("\(record.summary)\n" + HandoffBrief.abbreviate(record.cwd) + (record.branch.map { " on \($0)" } ?? "")
              + "\nAsleep since \(WaitSchedule.dateLabel(record.sleptAt)). Click to wake it as it was.")
    }
}

/// How many agents a workspace has, as a small pill beside its name.
private struct AgentCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(Theme.cardSelected))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .help("\(count) agents in this workspace")
            .accessibilityLabel("\(count) agents")
    }
}

/// A port a workspace's servers listen on, in the row under its card: a
/// little taller than the branch chip below, so it's easy to hit on purpose.
private struct PortButton: View {
    let port: Int
    /// What serves it, for its logo; a network glyph when unknown.
    let service: String?
    /// What listens on it, for stopping from its menu.
    let owners: [ListeningPorts.Listener]
    let action: () -> Void
    @State private var hovered = false

    private var url: String { "http://localhost:" + String(port) }

    /// "node (4312)", or the pids when several processes share it.
    private var ownerName: String {
        guard let first = owners.first else { return "server" }
        return owners.count == 1 ? "\(first.command) (\(first.pid))" : "\(first.command) and \(owners.count - 1) more"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let logo = LanguageLogo(service: service, size: 11) {
                    logo
                } else {
                    Image(systemName: "network").font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(":" + String(port))
                    .font(Theme.monoFont)
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(hovered ? Theme.hover : Theme.card.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(Theme.border.opacity(hovered ? 1 : 0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open http://localhost:" + String(port) + (service.map { " (\(ServiceKind.name($0)))" } ?? ""))
        .contextMenu {
            Button("Open in Browser", action: action)
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            Divider()
            Button("Stop \(ownerName)") { PortsWatcher.shared.stop(port: port) }
                .disabled(owners.isEmpty)
            Button("Force Quit \(ownerName)") { PortsWatcher.shared.stop(port: port, force: true) }
                .disabled(owners.isEmpty)
        }
    }
}

/// An x that appears on a hovered workspace, closing it in one click.
struct WorkspaceCloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon("xmark", size: 12)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 18, height: 18)
                .background(hovered ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close workspace")
        .accessibilityLabel("Close workspace")
    }
}

/// A workspace's project icon in the sidebar, and its agent's state as a dot
/// on the corner: accent while working, amber when it needs you, green when
/// it's done.
private struct WorkspaceProjectIcon: View {
    let image: NSImage
    let status: EngineAgentStatus

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
            .overlay(alignment: .bottomTrailing) {
                if let color = dot {
                    Circle().fill(color)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Theme.sidebar, lineWidth: 1.2))
                        .offset(x: 2.5, y: 2.5)
                }
            }
            .help(help)
    }

    private var dot: Color? {
        switch status {
        case .working: Theme.accent
        case .blocked: Color(hex: AgentStateColor.blocked)
        case .done: Color(hex: AgentStateColor.done)
        default: nil
        }
    }

    private var help: String {
        switch status {
        case .working: "Agent working"
        case .blocked: "Agent needs you"
        case .done: "Agent done"
        default: "Project icon"
        }
    }
}
