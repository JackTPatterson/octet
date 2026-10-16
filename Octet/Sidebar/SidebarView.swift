import AppKit
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
    /// Groups showing all their workspaces, past the first few.
    @State private var expandedGroups: Set<String> = []
    @State private var query = ""
    /// The project the sidebar is narrowed to, by its folder; empty for all.
    @AppStorage("octet.sidebar.project") private var projectFilter = ""
    /// The result the arrow keys are on, by position in the results.
    @State private var highlighted = 0
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
                        ForEach(shownGroups) { group in
                            groupSection(group)
                        }
                    }
                    if window.ownWorkspaces.isEmpty {
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
                .animation(motion.animation(.sidebar), value: window.activeGroups)
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
            if !searching, !window.idleWorkspaces.isEmpty || !idle.sleeping.isEmpty {
                IdleDock(store: store)
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion.animation(.sidebar), value: window.idleWorkspaces.isEmpty)
        .animation(motion.animation(.sidebar), value: waits.waiting.isEmpty)
        .frame(width: width)
        .background(Theme.sidebar)
        // Peeks come back once the pointer has left the sidebar.
        .onHover { if !$0 { HoverIntent.navigating = false } }
        .onReceive(window.ui.$sidebarSearchRequest.dropFirst()) { _ in searchFocused = true }
    }

    /// Two quiet rows, after T3 Code's: search with a button for a new
    /// workspace, then which project the sidebar shows with a button to
    /// start one in another folder.
    private var controlBar: some View {
        VStack(spacing: 2) {
            searchField
            projectRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            OctetIcon("magnifyingglass", size: 14)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .focused($searchFocused)
                .onSubmit(openHighlighted)
                .onExitCommand(perform: clearSearch)
                // Up and down move through the results; Return opens one.
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onChange(of: query) { _, _ in highlighted = 0 }
                .help("Search workspaces (\(OctetShortcut.searchWorkspaces.display))")
            if !query.isEmpty {
                Button(action: clearSearch) {
                    OctetIcon("xmark.circle.fill", size: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Clear the search")
            }
            SidebarIconButton(icon: "pencil", help: newWorkspaceHelp) { newWorkspaceHere() }
                .accessibilityLabel("New workspace")
        }
        .padding(.leading, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(searchFocused ? Theme.hover : Color.clear))
    }

    /// "All projects", or the one project the sidebar is narrowed to.
    private var projectRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button { projectFilter = "" } label: {
                    if projectFilter.isEmpty { Label("All projects", systemImage: "checkmark") } else { Text("All projects") }
                }
                Divider()
                ForEach(window.activeGroups.filter { $0.id != ProjectGroup.otherId }) { group in
                    Button { projectFilter = group.id } label: {
                        if projectFilter == group.id { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let group = filteredGroup {
                        ProjectMonogram(name: group.name).frame(width: 18)
                    } else {
                        OctetIcon("folder", size: 14).foregroundStyle(Theme.textTertiary).frame(width: 18)
                    }
                    Text(filteredGroup?.name ?? "All projects")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    OctetIcon("chevron.down", size: 11).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("Show every project's workspaces, or one project's")
            .accessibilityLabel("Project: \(filteredGroup?.name ?? "All projects")")
            SidebarIconButton(icon: "folder.badge.plus", help: "New workspace in a folder…") { pickFolder() }
                .accessibilityLabel("New workspace in a folder")
        }
        .padding(.leading, 6)
        .frame(height: 30)
    }

    /// The project the sidebar is narrowed to, while it still has workspaces.
    private var filteredGroup: ProjectGroup? {
        guard !projectFilter.isEmpty else { return nil }
        return window.activeGroups.first { $0.id == projectFilter }
    }

    /// The groups the sidebar lists: all, or the one picked.
    private var shownGroups: [ProjectGroup] {
        guard let filteredGroup else { return window.activeGroups }
        return [filteredGroup]
    }

    private var newWorkspaceHelp: String {
        if let filteredGroup { return "New workspace in \(filteredGroup.name) (⌘N)" }
        return "New workspace (⌘N)"
    }

    /// A new workspace, in the project the sidebar is narrowed to.
    private func newWorkspaceHere() {
        window.newWorkspace(cwd: filteredGroup?.id)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to start a workspace in"
        if let filteredGroup { panel.directoryURL = URL(fileURLWithPath: filteredGroup.id) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        window.newWorkspace(cwd: url.path)
    }

    /// The workspaces the query finds, under their groups' names, then the
    /// idle ones it finds; groups aren't collapsed while searching. A
    /// workspace is found by its names and folders, or by what was said in
    /// its conversations, which then shows under it.
    private var matches: (groups: [ProjectGroup], idle: [EngineWorkspace], snippets: [String: SidebarSearch.Snippet]) {
        var snippets: [String: SidebarSearch.Snippet] = [:]
        func hit(_ workspace: EngineWorkspace, group: String?) -> Bool {
            if found(workspace, group: group) { return true }
            guard let snippet = SidebarSearch.snippet(query, in: messages(in: workspace.workspaceId)) else { return false }
            snippets[workspace.workspaceId] = snippet
            return true
        }
        let groups = window.activeGroups.compactMap { group -> ProjectGroup? in
            let hits = group.workspaces.filter { hit($0, group: group.name) }
            return hits.isEmpty ? nil : ProjectGroup(id: group.id, name: group.name, workspaces: hits)
        }
        let idle = window.idleWorkspaces.filter { hit($0, group: nil) }
        return (groups, idle, snippets)
    }

    /// What was said in a workspace's conversations, oldest first.
    private func messages(in workspaceId: String) -> [(fromYou: Bool, text: String)] {
        AgentCenter.shared.sessions(in: workspaceId).flatMap { session in
            session.conversation.items.compactMap { item -> (fromYou: Bool, text: String)? in
                switch item.kind {
                case .user(let text): return (true, text)
                case .text(let text) where item.parent == nil: return (false, text)
                default: return nil
                }
            }
        }
    }

    /// The results in the order shown, for the arrow keys.
    private func results(_ matches: (groups: [ProjectGroup], idle: [EngineWorkspace], snippets: [String: SidebarSearch.Snippet])) -> [EngineWorkspace] {
        matches.groups.flatMap(\.workspaces) + matches.idle
    }

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        guard searching else { return .ignored }
        let count = results(matches).count
        guard count > 0 else { return .handled }
        highlighted = (highlighted + step + count) % count
        return .handled
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
        let order = results(matches).map(\.workspaceId)
        ForEach(matches.groups) { group in
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader(group.name)
                ForEach(group.workspaces) { workspace in
                    result(workspace, snippet: matches.snippets[workspace.workspaceId], at: order.firstIndex(of: workspace.workspaceId))
                }
            }
        }
        if !matches.idle.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader("Idle")
                ForEach(matches.idle) { workspace in
                    result(workspace, snippet: matches.snippets[workspace.workspaceId], at: order.firstIndex(of: workspace.workspaceId))
                }
            }
        }
        if matches.groups.isEmpty, matches.idle.isEmpty, !window.ownWorkspaces.isEmpty {
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
    /// A result: the workspace's card, ringed while the arrow keys are on
    /// it, and what was said that matched, when that's how it was found.
    private func result(_ workspace: EngineWorkspace, snippet: SidebarSearch.Snippet?, at index: Int?) -> some View {
        let on = index == highlighted
        return VStack(alignment: .leading, spacing: 3) {
            WorkspaceCard(store: store, workspace: workspace)
            if let snippet { SnippetLine(snippet: snippet).padding(.horizontal, 10) }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 2)
            .strokeBorder(on ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .onHover { if $0, let index { highlighted = index } }
        .padding(.horizontal, 8)
    }

    /// Return in the search: the result the arrow keys are on.
    private func openHighlighted() {
        guard searching else { return }
        let found = results(matches)
        guard !found.isEmpty else { return }
        let pick = found[min(max(highlighted, 0), found.count - 1)]
        clearSearch()
        window.focusWorkspace(pick.workspaceId)
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
    }

    /// A project's workspaces show this many before "Show more".
    private static let shownPerGroup = 6

    @ViewBuilder
    private func groupSection(_ group: ProjectGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        let showsAll = expandedGroups.contains(group.id) || group.workspaces.count <= Self.shownPerGroup + 1
        let shown = showsAll ? group.workspaces : Array(group.workspaces.prefix(Self.shownPerGroup))
        VStack(alignment: .leading, spacing: 4) {
            ProjectGroupHeader(
                group: group, collapsed: collapsed, isRepository: Self.isRepository(group), help: Self.groupHelp(group),
                toggle: {
                    motion.perform(.sidebar) {
                        if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
                    }
                },
                newWorkspace: group.id == ProjectGroup.otherId ? nil : { window.newWorkspace(cwd: group.id) }
            )

            if !collapsed {
                // Workspaces on the same branch stack together under one chip.
                ForEach(BranchRuns.make(shown, branch: { store.branches[$0.workspaceId] },
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
                if group.workspaces.count > Self.shownPerGroup + 1 {
                    let hidden = group.workspaces.count - Self.shownPerGroup
                    Button(expandedGroups.contains(group.id) ? "Show fewer" : "Show \(hidden) more") {
                        motion.perform(.sidebar) {
                            if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14)
                }
            }
        }
    }

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
        if window.idleWorkspaces.contains(where: { $0.workspaceId == id }) {
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
                        Text("\(window.idleWorkspaces.count)")
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
                    .animation(motion.animation(.sidebar), value: window.idleWorkspaces)
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
        return window.idleWorkspaces.count + headers + (idle.sleeping.isEmpty ? 0 : idle.sleeping.count + 1)
    }

    private struct Section: Identifiable {
        let name: String
        let workspaces: [EngineWorkspace]
        var id: String { name }
    }

    /// One unnamed section, or one per project once there are many.
    private var sections: [Section] {
        let all = window.idleWorkspaces
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
        let picked = window.idleWorkspaces.filter { idle.selection.contains($0.workspaceId) }
        if !picked.isEmpty {
            Button("Close \(picked.count) Picked…") { idle.close(picked) }
            Button("Sleep \(picked.count) Picked") { idle.sleep(picked) }
            Button("Clear Picks") { idle.selection = [] }
            Divider()
        }
        Button("Close All Idle…") { idle.close(window.idleWorkspaces) }
            .disabled(window.idleWorkspaces.isEmpty)
        Button("Sleep All Idle") { idle.sleep(window.idleWorkspaces) }
            .disabled(window.idleWorkspaces.isEmpty)
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

/// A project's header in the sidebar: its badge and name, and on hover a
/// count and a button for a new workspace there; collapsed, it keeps the
/// count so you know what's folded away.
private struct ProjectGroupHeader: View {
    let group: ProjectGroup
    let collapsed: Bool
    let isRepository: Bool
    let help: String
    let toggle: () -> Void
    let newWorkspace: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if group.id == ProjectGroup.otherId {
                        OctetIcon("folder", size: 11).foregroundStyle(Theme.textTertiary).frame(width: 16, height: 16)
                    } else {
                        ProjectMonogram(name: group.name)
                    }
                    Text(group.name.uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if isRepository {
                        OctetIcon("arrow.triangle.branch", size: 10).foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    if collapsed || hovered {
                        Text("\(group.workspaces.count)")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .help(group.workspaces.count == 1 ? "1 workspace" : "\(group.workspaces.count) workspaces")
                    }
                    OctetIcon("chevron.down", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            if let newWorkspace, hovered {
                Button(action: newWorkspace) {
                    OctetIcon("plus", size: 11).foregroundStyle(Theme.textSecondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New workspace in \(group.name)")
                .accessibilityLabel("New workspace in \(group.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }
}

/// A project's initials on a tile of its own colour, the same each launch.
struct ProjectMonogram: View {
    let name: String
    var size: CGFloat = 16

    private static let palette: [KeyPath<ThemePalette, String>] = [
        \.syntaxBuiltin, \.syntaxFlag, \.syntaxString, \.syntaxPath, \.syntaxVariable,
    ]

    var body: some View {
        let color = Theme.palette.color(Self.palette[SidebarSearch.colorIndex(name, count: Self.palette.count)])
        Text(SidebarSearch.monogram(name))
            .font(.system(size: size * 0.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(color.opacity(0.16)))
            .accessibilityHidden(true)
    }
}

/// What was said that a search found: who said it, then the words around
/// the match, the match in bold.
private struct SnippetLine: View {
    let snippet: SidebarSearch.Snippet

    var body: some View {
        (Text(snippet.fromYou ? "You: " : "Agent: ")
            .foregroundColor(snippet.fromYou ? Theme.accent : Color(hex: AgentStateColor.done))
         + Text(snippet.before).foregroundColor(Theme.textTertiary)
         + Text(snippet.match).bold().foregroundColor(Theme.textPrimary)
         + Text(snippet.after).foregroundColor(Theme.textTertiary))
            .font(Theme.captionFont)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A small icon button at the end of a sidebar header row.
private struct SidebarIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon(icon, size: 14)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
