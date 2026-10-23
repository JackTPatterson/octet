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
    @ObservedObject private var checkIns = CheckInCenter.shared
    @ObservedObject private var idle = IdleCenter.shared
    @ObservedObject private var tabDrag = TabDrag.shared
    @State private var newWorkspaceDropTargeted = false
    @State private var collapsedGroups: Set<String> = []
    /// Groups showing all their workspaces, past the first few.
    @State private var expandedGroups: Set<String> = []
    @State private var query = ""
    /// The project the sidebar is narrowed to, by its folder; empty for all.
    @AppStorage("octet.sidebar.project") private var projectFilter = ""
    @StateObject private var dropdowns = OctetDropdownState()
    /// The result the arrow keys are on, by its workspace: a position would
    /// land on another workspace as the results change. Nil is the first.
    @State private var highlightedId: String?
    /// What the query finds, worked out when it changes (after a short
    /// pause) and every few seconds while searching, not on every redraw:
    /// it reads every conversation.
    @State private var searchMatches = SearchMatches.none
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let _ = RenderCounter.note("SidebarView")
        VStack(spacing: 0) {
            controlBar
            if tabDrag.tabId != nil {
                HStack(spacing: 7) {
                    OctetIcon("plus.square", size: 14)
                    Text("New workspace from tab").font(Theme.uiFontMedium)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(newWorkspaceDropTargeted ? Theme.cardSelected : Theme.hover,
                            in: RoundedRectangle(cornerRadius: Theme.rowRadius))
                .padding(.horizontal, 8)
                .onDrop(of: [OctetDragKind.tab.type], isTargeted: $newWorkspaceDropTargeted) { _ in
                    guard let tabId = tabDrag.tabId else { return false }
                    WindowActions.tabToWorkspace(tabId, in: window)
                    return true
                }
            }
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
                                let keys = OctetShortcut.newWorkspace.display
                                Text(keys.isEmpty ? "Double-click here to start one." : "Press \(keys) or double-click here to start one.")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                }
                .padding(.vertical, 8)
                .animation(motion.animation(.sidebar), value: window.activeGroups.map { ($0.id + $0.workspaces.map(\.workspaceId).joined(separator: ",")) })
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
            if !searching, !waits.waits.filter(\.isCheckIn).isEmpty || !checkIns.stalls.isEmpty {
                CheckInsDock()
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
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
        // The dock comes and goes with its first workspace or sleeper, not
        // only its first idle one, so waking the last sleeper slides it away too.
        .animation(motion.animation(.sidebar, IdleDock.spring), value: window.idleWorkspaces.isEmpty && idle.sleeping.isEmpty)
        .animation(motion.animation(.sidebar), value: waits.waiting.isEmpty)
        .frame(width: width)
        .background(Theme.sidebar)
        .octetDropdownHost(dropdowns)
        // Peeks come back once the pointer has left the sidebar.
        .onHover { if !$0 { HoverIntent.navigating = false } }
        .onReceive(window.ui.$sidebarSearchRequest.dropFirst()) { _ in searchFocused = true }
        .task(id: query) {
            guard searching else { return searchMatches = .none }
            try? await Task.sleep(for: .milliseconds(120))
            // Kept fresh while searching, for what agents say meanwhile.
            while !Task.isCancelled {
                refreshMatches()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // A workspace opened or closed shows (or goes) straight away.
        .onChange(of: window.ownWorkspaces.map(\.workspaceId)) { _, _ in
            if searching { refreshMatches() }
        }
    }

    /// Search, the onboarding checklist, and project filtering: search with a button for a new
    /// workspace, then which project the sidebar shows with a button to
    /// start one in another folder.
    private var controlBar: some View {
        VStack(spacing: 2) {
            OnboardingChecklistRow(openProject: pickFolder)
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
                .onChange(of: query) { _, _ in highlightedId = nil }
                .help(OctetShortcut.searchWorkspaces.help("Search workspaces"))
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
            OctetDropdownAnchor(spec: projectSpec, state: dropdowns) { open in
                HStack(spacing: 8) {
                    if let group = filteredGroup {
                        ProjectMonogram(name: group.name).frame(width: 18)
                    } else {
                        OctetIcon("folder", size: 14).foregroundStyle(Theme.textTertiary).frame(width: 18)
                    }
                    Text(filteredGroup?.name ?? "All projects")
                        .font(Theme.uiFont)
                        .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    OctetIcon("chevron.down", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.trailing, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(open ? Theme.hover : .clear))
            }
            .help("Show every project's workspaces, or one project's")
            .accessibilityLabel("Project")
            .accessibilityValue(filteredGroup?.name ?? "All projects")
            .accessibilityHint("Opens a menu")
            SidebarIconButton(icon: "folder.badge.plus", help: "New workspace in a folder…") { pickFolder() }
                .accessibilityLabel("New workspace in a folder")
        }
        .padding(.leading, 6)
        .frame(height: 30)
    }

    /// The project picker, drawn by the sidebar's dropdown host as Octet's
    /// own panel: each project by its badge and workspace count.
    private var projectSpec: OctetDropdownSpec {
        let groups = window.activeGroups.filter { $0.id != ProjectGroup.otherId }
        let selected = filteredGroup?.id ?? ""
        let total = window.activeGroups.reduce(0) { $0 + $1.workspaces.count }
        // From the row's inset (14) to just short of the sidebar's edge.
        let panelWidth = width - 22
        return OctetDropdownSpec(
            id: "project",
            options: [OctetDropdownOption(id: "", title: "All projects")]
                + groups.map { OctetDropdownOption(id: $0.id, title: $0.name) },
            selected: selected,
            select: { projectFilter = $0 },
            panel: { close in
                AnyView(ProjectPickerPanel(groups: groups, total: total, selected: selected, width: panelWidth,
                                           select: { projectFilter = $0; close() }, close: close))
            }
        )
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
        let keys = OctetShortcut.newWorkspace.display
        let suffix = keys.isEmpty ? "" : " (\(keys))"
        if let filteredGroup { return "New workspace in \(filteredGroup.name)\(suffix)" }
        return "New workspace\(suffix)"
    }

    /// A new workspace, in the project the sidebar is narrowed to.
    private func newWorkspaceHere() {
        window.newWorkspace(cwd: filteredGroup?.id)
    }

    private func pickFolder() {
        PathPickerCenter.shared.pick("New Workspace", message: "Choose a folder to start a workspace in",
                                     start: filteredGroup?.id, in: window.nsWindow) { urls in
            guard let url = urls.first else { return }
            window.newWorkspace(cwd: url.path)
        }
    }

    /// The workspaces the query finds, under their groups' names, then the
    /// idle ones it finds; groups aren't collapsed while searching. A
    /// workspace is found by its names and folders, or by what was said in
    /// its conversations, which then shows under it.
    private func computeMatches() -> SearchMatches {
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
        return SearchMatches(query: query, groups: groups, idle: idle, snippets: snippets)
    }

    private func refreshMatches() {
        searchMatches = computeMatches()
    }

    /// The matches for what's typed now: worked out here when the keys come
    /// faster than the pause before a search.
    private func currentMatches() -> SearchMatches {
        if searchMatches.query != query { refreshMatches() }
        return searchMatches
    }

    /// The workspace the arrow keys are on, while it's still a result.
    private var highlightedResult: String? {
        guard let highlightedId else { return searchMatches.order.first }
        return searchMatches.position[highlightedId] != nil ? highlightedId : nil
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

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        guard searching else { return .ignored }
        let order = currentMatches().order
        guard !order.isEmpty else { return .handled }
        let current = highlightedResult.flatMap { searchMatches.position[$0] }
        // From none, down goes to the first and up to the last.
        let next = current.map { ($0 + step + order.count) % order.count } ?? (step > 0 ? 0 : order.count - 1)
        highlightedId = order[next]
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
        let matches = searchMatches
        let on = highlightedResult
        ForEach(matches.groups) { group in
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader(group.name)
                ForEach(group.workspaces) { workspace in
                    result(workspace, snippet: matches.snippets[workspace.workspaceId], highlighted: workspace.workspaceId == on)
                }
            }
        }
        if !matches.idle.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                resultsHeader("Idle")
                ForEach(matches.idle) { workspace in
                    result(workspace, snippet: matches.snippets[workspace.workspaceId], highlighted: workspace.workspaceId == on)
                }
            }
        }
        // Only once the search for what's typed has run, not in the pause before.
        if matches.query == query, matches.groups.isEmpty, matches.idle.isEmpty, !window.ownWorkspaces.isEmpty {
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
    private func result(_ workspace: EngineWorkspace, snippet: SidebarSearch.Snippet?, highlighted on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            WorkspaceCard(store: store, workspace: workspace)
            if let snippet { SnippetLine(snippet: snippet).padding(.horizontal, 10) }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 2)
            .strokeBorder(on ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .onHover { if $0 { highlightedId = workspace.workspaceId } }
        .padding(.horizontal, 8)
    }

    /// Return in the search: the result the arrow keys are on.
    private func openHighlighted() {
        guard searching else { return }
        _ = currentMatches()
        // The workspace ringed, or nothing when that one has gone.
        guard let pick = highlightedResult else { return }
        clearSearch()
        window.focusWorkspace(pick)
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
        // The keys go back to the terminal, as the palette's do.
        OctetTerminalRuntime.focusTerminal()
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
                iconDirectories: [group.id] + group.workspaces.compactMap { store.snapshot.projectDirectory(ofWorkspace: $0.workspaceId) }.sorted(),
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
                    VStack(spacing: 2) {
                        ForEach(run.workspaces) { workspace in
                            WorkspaceCard(store: store, workspace: workspace, groupFolder: group.id)
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
        guard group.id != ProjectGroup.otherId else { return false }
        let now = Date()
        if let known = repositoryChecks[group.id], now.timeIntervalSince(known.at) < 60 { return known.isRepository }
        let isRepository = FileManager.default.fileExists(atPath: group.id + "/.git")
        repositoryChecks[group.id] = (isRepository, now)
        return isRepository
    }

    /// Whether each group's folder is a repository, looked up on disk once a
    /// minute rather than at every redraw of every header.
    private static var repositoryChecks: [String: (isRepository: Bool, at: Date)] = [:]

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
        // A quiet line under its workspaces, as T3 Code puts the branch.
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.hover : .clear))
        .onHover { hovered = $0 }
        .help(run.worktreePath.map { "Worktree at \($0)" } ?? "Branch \(run.branch ?? "")")
    }
}

/// How much of the model's window the conversation is using.
/// How much of the model's window the conversation is using, as a ring
/// that fills clockwise; the number is a hover away.
private struct ContextChip: View {
    let usage: TwinUsage

    var body: some View {
        Group {
            if let fraction = usage.contextFraction {
                // The shared ring and thresholds (ContextLevel), as the composer's.
                ContextRing(fraction: fraction)
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
    /// The folder of the group the card is listed under: its own folder line
    /// is left out when it says only that. Nil where there's no group (search).
    var groupFolder: String?
    @State private var hovered = false
    @State private var renaming = false
    @StateObject private var peek = HoverIntent()
    @ObservedObject private var conversations = AgentCenter.shared
    @ObservedObject private var portsWatcher = PortsWatcher.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Servers running here, e.g. each worktree's dev server.
        let ports = portsWatcher.ports(inWorkspace: workspace.workspaceId, snapshot: store.snapshot)
        VStack(spacing: 4) {
            card(ports: ports)
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

    @ViewBuilder private func card(ports: [Int]) -> some View {
        let snapshot = store.snapshot
        let isSelected = workspace.workspaceId == window.panelContext.focusedWorkspace?.workspaceId
        // Open in another window: a click brings that window forward.
        let elsewhere = WindowRegistry.shared.window(showing: workspace.workspaceId)
            .map { $0 !== window && $0 !== window.splitContext } ?? false
        let agents = snapshot.agents(inWorkspace: workspace.workspaceId)
        let agent = store.primaryAgent(in: agents)
        // Looked up once: each lookup walks every conversation in Octet.
        let sessions = conversations.sessions(in: workspace.workspaceId)
        let session = conversations.active(in: workspace.workspaceId) ?? sessions.first
        let handoffAgent = window.agentUIHandoffWorkspaceId == workspace.workspaceId
            ? window.agentUIHandoff : nil
        // Once a native agent starts moving into Octet, the workspace adopts
        // conversation styling immediately and keeps it after the terminal
        // process disappears.
        let brand = handoffAgent.flatMap(AgentBrand.forAgent)
            ?? session.flatMap { AgentBrand.forAgent($0.engine.agent) }
            ?? AgentBrand.forAgent(agent?.agent)
        // The loudest of the workspace's agents speaks for it, in the shared
        // vocabulary (approval > input > failed > working > … > done).
        let status: AgentState = handoffAgent != nil ? AgentState(agent?.agentStatus ?? .working)
            : AgentState.rollUp(sessions.map(\.agentState)
                + agents.filter { !$0.isSubagentViewer }.map { AgentState($0.agentStatus) }
                + [AgentState(workspace.agentStatus)])
        let directory = snapshot.directory(ofWorkspace: workspace.workspaceId)
        // Different agents across this workspace's tabs: the primary one
        // first, then the rest, each vendor once.
        var seenBrands = Set<String>()
        let brands = ([brand]
            + agents.map { AgentBrand.forAgent($0.agent) }
            + sessions.map { AgentBrand.forAgent($0.engine.agent) })
            .compactMap { $0 }.filter { seenBrands.insert($0.displayName).inserted }

        let receded = !isSelected && (status == .idle || status == .unknown)
        // The agent's state; with no agent here, a running server's logo
        // takes the empty state's place. The project's favicon is on the
        // group's header, not on each of its workspaces.
        // Only a state that needs a look (a question, a failure, done) takes
        // the gutter; otherwise the title sits flush and the mark slides in.
        let serviceLogo = status == .unknown
            ? LanguageLogo(service: ports.lazy.compactMap { portsWatcher.services[$0] }.first, size: 13) : nil
        let showsMark: Bool = {
            if serviceLogo != nil { return true }
            switch status {
            case .needsInput, .needsApproval, .failed, .planReady, .done: return true
            default: return false
            }
        }()
        let mark = Group {
            if let serviceLogo {
                serviceLogo.help("Serving on localhost")
            } else {
                AgentStateGlyph(state: status)
            }
        }
        .frame(width: 16)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if showsMark {
                    mark.transition(motion.animates(.sidebar)
                        ? .move(edge: .leading).combined(with: .opacity) : .identity)
                }
                if renaming {
                    InlineRenameField(initial: workspace.label, placeholder: "Workspace name") { label in
                        renaming = false
                        store.renameWorkspace(workspace.workspaceId, to: label, from: workspace.label)
                    }
                } else {
                    Text(workspace.label)
                        .font(Theme.interfaceFont(13, weight: receded ? .regular : .medium))
                        .foregroundStyle(receded ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if store.isPinned(workspace.workspaceId) {
                    OctetIcon("pin.fill", size: 11).foregroundStyle(Theme.textMuted)
                        .help("Pinned: never moves to Idle")
                }
                if elsewhere {
                    OctetIcon("rectangle.on.rectangle", size: 12).foregroundStyle(Theme.textTertiary)
                        .help("Open in another window. Click to bring it forward.")
                }
            }
            // The folder decides the card's group, so it shows where it says
            // more than the group's header does: a subfolder, or another folder.
            if let directory, directory != groupFolder, abbreviateHome(directory) != workspace.label {
                Text(abbreviateHome(directory))
                    .font(Theme.Text.mono(11))
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
            WorkspaceAgentsList(store: store, workspaceId: workspace.workspaceId, brands: brands)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(motion.animation(.sidebar, .smooth(duration: 0.25)), value: showsMark)
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            // Not for the workspace already showing, nor while renaming or
            // dragging a tab over it.
            peek.source(hovering && !isSelected && !renaming
                        && TabDrag.shared.item == nil)
        }
        .hoverPopover(isPresented: $peek.isShown) {
            WorkspacePeek(store: store, workspace: workspace) { peek.close() }
                .environmentObject(window)
                .onHover { peek.card($0) }
        }
        #if DEBUG
        // Verification hook (OCTET_OPEN_WINDOW=peek): the first workspace's card.
        .onReceive(NotificationCenter.default.publisher(for: WorkspacePeek.debugOpen)) { _ in
            if window.ownWorkspaces.first?.workspaceId == workspace.workspaceId { peek.show() }
        }
        #endif
        .onTapGesture {
            peek.close()
            HoverIntent.navigating = true
            window.focusWorkspace(workspace.workspaceId)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        // Dragged out of the window, the workspace gets a window of its own.
        .octetDragSource(.workspace, enabled: !renaming, began: {
            peek.close()
            TabDrag.shared.begin(workspace: workspace.workspaceId, from: window)
            return true
        }, moved: { TabDrag.shared.moved(to: $0) }, ended: { TabDrag.shared.ended($0) })
        .octetContextMenu {
            WorkspaceMenu.items(store: store, workspace: workspace, window: window) { renaming = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusWorkspace(workspace.workspaceId) }
        .accessibilityAction(named: "Rename") { renaming = true }
        .accessibilityAction(named: "Close") { store.closeWorkspace(workspace.workspaceId) }
        // The peek opens on hover; this is the way to it without a pointer.
        .accessibilityAction(named: "Show Details") { peek.show() }
    }

    /// Nothing at rest, a fill under the pointer and a stronger one for the
    /// workspace in front, as T3 Code's rows; a workspace's colour tints it.
    private func cardBackground(isSelected: Bool, hue: String?) -> some View {
        ZStack {
            (isSelected ? Theme.cardSelected : (hovered ? Theme.hover : Color.clear))
            if let hue {
                // A hint of the colour, not a wash: the fill says which is in front.
                Color(hex: hue).opacity(hovered ? Theme.tabColorOpacity : isSelected ? Theme.tabColorOpacity * 0.7 : Theme.tabColorOpacity * 0.4)
            }
        }
    }

}

/// The session server's status in a sentence ("needs input"), from the
/// shared vocabulary so every surface says it the same way.
func stateLabel(_ status: EngineAgentStatus) -> String {
    AgentState(status).label
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

/// A workspace's right-click menu, in Octet's own menu rather than the
/// system's: renaming, colour, pinning, idling and snoozing, agents,
/// windows and closing.
@MainActor
enum WorkspaceMenu {
    static func items(store: SessionStore, workspace: EngineWorkspace, window: WindowContext,
                      rename: @escaping () -> Void) -> [OctetMenuItem] {
        let id = workspace.workspaceId
        var items: [OctetMenuItem] = [.action("Rename Workspace…", icon: "pencil", rename)]
        if store.isWorkspaceManuallyNamed(id), SettingsStore.shared.values.autoNameWorkspaces {
            items.append(.action("Name After Its Work", icon: "sparkles") { store.resumeWorkspaceAutoNaming(id) })
        }
        if let directory = store.snapshot.directory(ofWorkspace: id) {
            let host = OctetPluginHost.shared
            let plugins = host.menuItems(for: .workspace, directory: directory)
            if !plugins.isEmpty {
                items.append(.divider)
                items += plugins.map { entry in
                    .action(entry.item.title, icon: "puzzlepiece") {
                        host.perform(entry, directory: directory, workspaceId: id, in: window)
                    }
                }
            }
        }
        items.append(.divider)
        items.append(.swatches("Color", OctetMenuSwatches(
            options: TabColor.allCases.map { .init(id: $0.rawValue, name: $0.name, color: $0.color) },
            selected: store.workspaceColor(id)?.rawValue,
            select: { store.setWorkspaceColor(id, $0.flatMap(TabColor.init(rawValue:))) })))
        items.append(.divider)
        let agents = store.snapshot.agents(inWorkspace: id).filter { AgentOffer.agentId($0) != nil }
        if agents.count == 1, let agent = agents.first {
            items.append(.action("Open on Octet UI", icon: "bubble.left.and.bubble.right") { window.openOnOctetUI(agent) })
            items.append(.divider)
        } else if agents.count > 1 {
            items.append(.submenu("Open on Octet UI", icon: "bubble.left.and.bubble.right", agents.map { agent in
                .action(label(for: agent, store: store), icon: nil) { window.openOnOctetUI(agent) }
            }))
            items.append(.divider)
        }
        items.append(store.isPinned(id)
            ? .action("Unpin", icon: "pin.slash") { store.setPinned(id, false) }
            : .action("Pin to Keep in View", icon: "pin") { store.setPinned(id, true) })
        if window.idleWorkspaces.contains(where: { $0.workspaceId == id }) {
            // Back to the list, as the row's Wake does; a click opens it.
            items.append(.action("Wake", icon: "sun.max") { store.keepInView(id) })
        } else {
            items.append(.action("Move to Idle", icon: "moon") { store.markIdle(id) })
        }
        items.append(.submenu("Snooze", icon: "clock", snoozeItems(store: store, workspaceId: id)))
        items.append(.action("Wait for Something…", icon: "hourglass") { WaitCenter.shared.compose(workspaceId: id) })
        items.append(.action("Check Back…", icon: "clock.arrow.circlepath",
                             help: "For work that takes days or weeks: Octet brings it back on a schedule, even if the session has ended") {
            CheckInCenter.shared.compose(workspaceId: id, session: AgentCenter.shared.active(in: id))
        })
        items.append(.action("Sleep", icon: "powersleep",
                             help: "Closes its terminals and keeps a note to bring it back as it was, agents resumed") {
            IdleCenter.shared.sleep([workspace])
        })
        if IdleCenter.shared.work[id]?.mergedWorktree == true {
            items.append(.action("Close and Remove Worktree…", icon: "trash", destructive: true) {
                IdleCenter.shared.removeMergedWorktree(workspace, window: window)
            })
        }
        // The workspace's Claude Code conversations, carried on in another
        // folder; see ConversationMover.
        let movable = AgentCenter.shared.sessions(in: id).filter(\.canMove)
        items.append(.action(movable.count > 1 ? "Move \(movable.count) Conversations To…" : "Move Conversation To…",
                             icon: "folder", enabled: !movable.isEmpty,
                             help: movable.isEmpty
                                ? "Moves this workspace's Claude Code conversations to another folder; none here can move now"
                                : "Carry on with this workspace's Claude Code conversations in another folder") {
            let from = store.snapshot.directory(ofWorkspace: id) ?? NSHomeDirectory()
            ConversationMover.moveAfterPicking(movable, from: from, window: window)
        })
        if AgentDiscoveryStore.shared.agents.contains(where: { $0.id == "claude" && $0.executablePath != nil }) {
            items.append(.action("New Cloud Session Here…", icon: "cloud") {
                // In the window showing it, which the session will open in.
                let target = WindowRegistry.shared.window(showing: id) ?? window
                target.focusWorkspace(id)
                target.ui.paletteStart = [PaletteCatalog.claudeCloudItemId]
                target.ui.paletteVisible = true
            })
        }
        items.append(.divider)
        if let other = WindowRegistry.shared.window(showing: id), other !== window {
            items.append(.action("Show Window", icon: "macwindow") { other.bringForward() })
        } else {
            items.append(.action("Move Workspace to New Window", icon: "macwindow.badge.plus") {
                WindowActions.moveWorkspaceToNewWindow(id, from: window)
            })
        }
        items.append(.divider)
        items.append(.action("Close Workspace", icon: "xmark", destructive: true) { store.closeWorkspace(id) })
        return items
    }

    /// The snooze choices, as SnoozeMenuItems offers them.
    static func snoozeItems(store: SessionStore, workspaceId: String) -> [OctetMenuItem] {
        // Read when the menu opens, so "This Evening" drops out once the
        // evening is close.
        var items: [OctetMenuItem] = SnoozeChoice.offered().filter { $0 != .untilUsed }.map { choice in
            .action(choice.title) { store.snooze(workspaceId, choice) }
        }
        items.append(pickSnoozeTime(store: store, workspaceId: workspaceId))
        items.append(.divider)
        items.append(.action(SnoozeChoice.untilUsed.title) { store.snooze(workspaceId, .untilUsed) })
        items.append(.action("Until Something Happens…") { WaitCenter.shared.compose(workspaceId: workspaceId, snooze: true) })
        return items
    }

    /// The agent's name and its tab, to tell several apart.
    private static func label(for agent: EngineAgent, store: SessionStore) -> String {
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        guard let tab = store.snapshot.tabs.first(where: { $0.tabId == agent.tabId }) else { return name }
        return "\(name) · \(TabAutoName.display(label: tab.label, number: tab.number))"
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close workspace")
        .accessibilityLabel("Close workspace")
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
    /// Folders to look in for the project's favicon: the group's own, then
    /// where its workspaces are.
    let iconDirectories: [String]
    let toggle: () -> Void
    let newWorkspace: (() -> Void)?
    @ObservedObject private var workspaceIcons = WorkspaceIconStore.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if group.id == ProjectGroup.otherId {
                        OctetIcon("folder", size: 11).foregroundStyle(Theme.textTertiary).frame(width: 16, height: 16)
                    } else if let icon = iconDirectories.lazy.compactMap({ workspaceIcons.image(for: $0) }).first {
                        // A plugin's picture of the project (its favicon or app icon).
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 16 * 0.22))
                            .accessibilityHidden(true)
                    } else {
                        ProjectMonogram(name: group.name)
                    }
                    Text(group.name)
                        .font(Theme.Text.transcriptMedium)
                        .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    if isRepository {
                        OctetIcon("arrow.triangle.branch", size: 10).foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    if collapsed || (hovered && newWorkspace == nil) {
                        Text("\(group.workspaces.count)")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .help(group.workspaces.count == 1 ? "1 workspace" : "\(group.workspaces.count) workspaces")
                    }
                    // A square box, so the turn is about the glyph's centre
                    // and the chevron's edge is the row's edge.
                    OctetIcon("chevron.right", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .animation(.easeOut(duration: 0.15), value: collapsed)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            // On hover the new-workspace button sits over the count, left
            // of the chevron, so the chevron never moves off the edge.
            .overlay(alignment: .trailing) {
                if let newWorkspace {
                    Button(action: newWorkspace) {
                        OctetIcon("pencil", size: 13).foregroundStyle(Theme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.hover.opacity(0.6)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 22)
                    .hoverReveal(hovered)
                    .allowsHitTesting(hovered)
                    .animation(.easeOut(duration: 0.15), value: hovered)
                    .help("New workspace in \(group.name)")
                    .accessibilityLabel("New workspace in \(group.name)")
                }
            }
        }
        // T3 Code's project row: 32pt, a fill under the pointer.
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
        .padding(.horizontal, 8)
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
        Group {
            if let symbol = ProjectIcon.symbol(for: name) {
                // What the name says it is: a wrench for tools, a puck for hockey.
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
            } else {
                Text(SidebarSearch.monogram(name))
                    .font(.system(size: size * 0.5, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.6)
            }
        }
            .foregroundStyle(color)
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
            .foregroundColor(snippet.fromYou ? Theme.accent : Theme.success)
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
        .accessibilityLabel(help)
    }
}

/// The "All projects" dropdown: every project with its badge and how many
/// workspaces it has, the shown one checked. Arrow keys move, Return picks,
/// Escape closes.
private struct ProjectPickerPanel: View {
    let groups: [ProjectGroup]
    let total: Int
    let selected: String
    let width: CGFloat
    let select: (String) -> Void
    let close: () -> Void
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    /// "" stands for all projects, then each project by its folder.
    private var ids: [String] { [""] + groups.map(\.id) }

    var body: some View {
        OctetPalettePanel(style: .floating, divider: .none) {
            VStack(alignment: .leading, spacing: 1) {
                row(id: "", count: total) {
                    OctetIcon("folder", size: 13).foregroundStyle(Theme.textTertiary)
                } title: { "All projects" }
                if !groups.isEmpty {
                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
                    Text("PROJECTS")
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .vertical) {
                        projectRows
                        ScrollView { projectRows }.frame(height: 320)
                    }
                }
            }
            .padding(4)
        }
        .frame(width: max(width, 200))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            highlighted = selected
            DispatchQueue.main.async { focused = true }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { select(highlighted ?? selected); return .handled }
        .onExitCommand(perform: close)
        // A click outside the sidebar, e.g. in a terminal, takes focus away.
        .onChange(of: focused) { was, now in if was && !now { close() } }
    }

    private var projectRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(groups) { group in
                row(id: group.id, count: group.workspaces.count) {
                    ProjectMonogram(name: group.name)
                } title: { group.name }
                .help(group.id)
            }
        }
    }

    private func row<Mark: View>(id: String, count: Int, @ViewBuilder mark: () -> Mark,
                                 title: () -> String) -> some View {
        let isSelected = id == selected
        let name = title()
        return HStack(spacing: 8) {
            mark().frame(width: 18)
            Text(name)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(Theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
            OctetIcon("checkmark", size: 11)
                .foregroundStyle(Theme.accent)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 12)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
            .fill(highlighted == id ? Theme.cardSelected : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = id } }
        .onTapGesture { select(id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(count) workspace\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(id) }
    }

    private func move(_ delta: Int) {
        let current = ids.firstIndex(of: highlighted ?? selected) ?? 0
        highlighted = ids[(current + delta + ids.count) % ids.count]
    }
}

/// What a sidebar search found: workspaces under their groups, then idle
/// ones, with where each is in the order shown, for the arrow keys.
private struct SearchMatches {
    let query: String
    let groups: [ProjectGroup]
    let idle: [EngineWorkspace]
    let snippets: [String: SidebarSearch.Snippet]
    let order: [String]
    let position: [String: Int]

    init(query: String, groups: [ProjectGroup], idle: [EngineWorkspace], snippets: [String: SidebarSearch.Snippet]) {
        self.query = query
        self.groups = groups
        self.idle = idle
        self.snippets = snippets
        order = groups.flatMap(\.workspaces).map(\.workspaceId) + idle.map(\.workspaceId)
        position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let none = SearchMatches(query: "", groups: [], idle: [], snippets: [:])
}
