import SwiftUI

/// Vertical tabs: project groups with uppercase headers and
/// bordered workspace cards tinted by the running agent's vendor hue.
struct SidebarView: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    var width: CGFloat = Theme.sidebarWidth
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.activeGroups) { group in
                        groupSection(group)
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
            TipCard(store: store)
            if !store.idleWorkspaces.isEmpty {
                IdleDock(store: store)
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion.animation(.sidebar), value: store.idleWorkspaces.isEmpty)
        .frame(width: width)
        .background(Theme.sidebar)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            ControlButton(title: "New workspace", icon: "plus", shortcut: "⌘N") {
                window.newWorkspace()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
                    Text(group.name.uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(group.workspaces.count == 1 ? "1 space" : "\(group.workspaces.count) spaces")
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
                    .help("\(run.workspaces.count) spaces on this branch")
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

    var body: some View {
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
                AgentStateGlyph(status: status)
                    .frame(width: 12)
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
                if store.isPinned(workspace.workspaceId) {
                    OctetIcon("pin.fill", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Pinned: never moves to Idle")
                }
                Spacer(minLength: 0)
                if hovered && !renaming {
                    WorkspaceRenameButton { renaming = true }
                }
                if elsewhere {
                    OctetIcon("rectangle.on.rectangle", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Open in another window. Click to bring it forward.")
                        .accessibilityLabel("Open in another window")
                }
            }
            // The folder only earns a line when the name doesn't already say it.
            if let directory, !Self.labelNamesFolder(workspace.label, directory) {
                Text(abbreviateHome(directory))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 5) {
                if let brand {
                    AgentLogo(brand: brand, size: 11)
                    Text(agentLine(status: status, brand: brand,
                                   count: session == nil ? agents.count : 1))
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
        .background(cardBackground(isSelected: isSelected, hue: brand?.hueHex))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(isSelected ? Theme.textTertiary.opacity(0.55)
                    : (hovered ? Theme.border : Theme.border.opacity(0.6)), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            // Not while renaming or dragging a tab over it.
            peek.source(hovering && !renaming && TabDrag.shared.tabId == nil)
        }
        .popover(isPresented: $peek.isShown, arrowEdge: .trailing) {
            WorkspacePeek(store: store, workspace: workspace) { peek.close() }
                .environmentObject(window)
                .onHover { peek.card($0) }
        }
        .onTapGesture {
            peek.close()
            window.focusWorkspace(workspace.workspaceId)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        .contextMenu {
            WorkspaceOrganizeMenu(store: store, workspace: workspace) { renaming = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { window.focusWorkspace(workspace.workspaceId) }
        .accessibilityAction(named: "Rename") { renaming = true }
        .accessibilityAction(named: "Close") { store.closeWorkspace(workspace.workspaceId) }
    }

    /// True when the label already is the folder ("~" for home, or its last
    /// path component), so repeating the path adds nothing.
    static func labelNamesFolder(_ label: String, _ directory: String) -> Bool {
        let short = abbreviateHome(directory)
        return label == short || label == (directory as NSString).lastPathComponent
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

    private func agentLine(status: EngineAgentStatus, brand: AgentBrand, count: Int) -> String {
        let status = stateLabel(status)
        let extra = count > 1 ? " · \(count) agents" : ""
        return "\(brand.displayName) \(status)\(extra)"
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
                store.setPinned(id, false)
                window.focusWorkspace(id)
            }
        } else {
            Button("Move to Idle") { store.markIdle(id) }
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

/// Bottom dock of workspaces that haven't been used in a while: compact
/// one-line rows so active work stays in view.
struct IdleDock: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var motion = MotionPreferences.shared
    @AppStorage("octet.idleDock.collapsed") private var collapsed = false

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
                Button {
                    confirmCloseAll()
                } label: {
                    OctetIcon("xmark.bin", size: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Close all idle workspaces")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if !collapsed {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.idleWorkspaces) { workspace in
                            IdleRow(store: store, workspace: workspace)
                                .transition(motion.animates(.sidebar) ? .move(edge: .top).combined(with: .opacity) : .identity)
                        }
                    }
                    .animation(motion.animation(.sidebar), value: store.idleWorkspaces)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(store.idleWorkspaces.count) * 25 + 6, 200))
                .transition(motion.animates(.sidebar) ? .opacity : .identity)
            }
        }
        .background(Theme.chrome)
    }

    private func confirmCloseAll() {
        let count = store.idleWorkspaces.count
        ConfirmCenter.shared.ask(
            title: "Close \(count) idle workspace\(count == 1 ? "" : "s")?",
            message: "Their terminals and any processes running in them will end.",
            items: store.idleWorkspaces.map(\.label),
            confirmTitle: "Close",
            destructive: true
        ) { _ in store.closeIdleWorkspaces() }
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
    @State private var hovered = false
    @State private var renaming = false

    var body: some View {
        let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspace.workspaceId))
        let brand = AgentBrand.forAgent(agent?.agent)
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
                    store.renameWorkspace(workspace.workspaceId, to: label, from: workspace.label)
                }
            } else {
                Text(workspace.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            if !renaming, let project = store.projectName(of: workspace.workspaceId),
               project.caseInsensitiveCompare(workspace.label) != .orderedSame {
                Text(project)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered && !renaming {
                WorkspaceRenameButton { renaming = true }
                Button {
                    store.closeWorkspace(workspace.workspaceId)
                } label: {
                    OctetIcon("xmark", size: 15)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Close workspace")
            } else {
                Text(WorkspaceActivity.ageLabel(since: store.activity.lastActive(workspace.workspaceId)))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { window.focusWorkspace(workspace.workspaceId) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        .contextMenu { WorkspaceOrganizeMenu(store: store, workspace: workspace) { renaming = true } }
        .help("\(workspace.label) · last used \(WorkspaceActivity.ageLabel(since: store.activity.lastActive(workspace.workspaceId))) ago")
    }
}

/// A pencil that appears on a hovered workspace, so renaming is found
/// without knowing to double-click.
struct WorkspaceRenameButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon("pencil", size: 12)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 18, height: 18)
                .background(hovered ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Rename workspace")
        .accessibilityLabel("Rename workspace")
    }
}
