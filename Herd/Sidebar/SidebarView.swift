import SwiftUI

/// Warp-style vertical tabs: project groups with uppercase headers and
/// bordered workspace cards tinted by the running agent's vendor hue.
struct SidebarView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.activeGroups) { group in
                        groupSection(group)
                    }
                    if store.snapshot.workspaces.isEmpty {
                        Text(store.isConnected ? "No workspaces" : "Starting the terminal…")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 8)
                .animation(motion.animation(.sidebar), value: store.activeGroups)
            }
            TipCard(store: store)
            if !store.idleWorkspaces.isEmpty {
                IdleDock(store: store)
                    .transition(motion.animates(.sidebar) ? .move(edge: .bottom).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion.animation(.sidebar), value: store.idleWorkspaces.isEmpty)
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            ControlButton(title: "New workspace", systemImage: "plus", shortcut: "⌘N") {
                store.newWorkspace()
            }
        }
        .padding(8)
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
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
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
                    VStack(spacing: 2) {
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
            Image(systemName: run.worktreePath == nil ? "arrow.triangle.branch" : "square.stack.3d.up")
                .font(.system(size: 9))
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

private struct WorkspaceCard: View {
    @ObservedObject var store: HerdrStore
    let workspace: HerdrWorkspace
    @State private var hovered = false

    var body: some View {
        let snapshot = store.snapshot
        let isSelected = workspace.workspaceId == store.focusedWorkspace?.workspaceId
        let agents = snapshot.agents(inWorkspace: workspace.workspaceId)
        let agent = store.primaryAgent(in: agents)
        let brand = AgentBrand.forAgent(agent?.agent)
        let directory = snapshot.directory(ofWorkspace: workspace.workspaceId)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentStateGlyph(status: agent?.agentStatus ?? workspace.agentStatus)
                    .frame(width: 12)
                Text(workspace.label)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if store.isPinned(workspace.workspaceId) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Pinned: never moves to Idle")
                }
                Spacer(minLength: 0)
            }
            if let directory {
                Text(abbreviateHome(directory))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 5) {
                if let brand {
                    AgentLogo(brand: brand, size: 11)
                    Text(agentLine(agent: agent, brand: brand, count: agents.count))
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(workspace.tabCount == 1 ? "Terminal" : "\(workspace.tabCount) tabs")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(isSelected: isSelected, hue: brand?.hueHex))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(isSelected ? Theme.border.opacity(1.6) : Theme.border.opacity(hovered ? 1 : 0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.focusWorkspace(workspace.workspaceId) }
        .contextMenu {
            WorkspaceOrganizeMenu(store: store, workspace: workspace)
        }
    }

    private func cardBackground(isSelected: Bool, hue: String?) -> some View {
        ZStack {
            (isSelected ? Theme.cardSelected : (hovered ? Theme.hover : Theme.card))
            if let hue {
                Color(hex: hue).opacity(hovered ? Theme.tabColorOpacity * 1.6 : Theme.tabColorOpacity)
            }
        }
    }

    private func agentLine(agent: HerdrAgent?, brand: AgentBrand, count: Int) -> String {
        let status = agent.map { stateLabel($0.agentStatus) } ?? ""
        let extra = count > 1 ? " · \(count) agents" : ""
        return "\(brand.displayName) \(status)\(extra)"
    }
}

func stateLabel(_ status: HerdrAgentStatus) -> String {
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
    let systemImage: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                Text(title).font(Theme.uiFontMedium)
                if let shortcut {
                    Text(shortcut).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(hovered ? Theme.hover : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Context menu items shared by workspace cards and idle rows.
struct WorkspaceOrganizeMenu: View {
    @ObservedObject var store: HerdrStore
    let workspace: HerdrWorkspace

    var body: some View {
        let id = workspace.workspaceId
        if store.isPinned(id) {
            Button("Unpin") { store.setPinned(id, false) }
        } else {
            Button("Pin to Keep in View") { store.setPinned(id, true) }
        }
        if store.idleWorkspaces.contains(where: { $0.workspaceId == id }) {
            Button("Keep in View Now") {
                store.setPinned(id, false)
                store.focusWorkspace(id)
            }
        } else {
            Button("Move to Idle") { store.markIdle(id) }
        }
        Divider()
        Button("Close Workspace") { store.closeWorkspace(id) }
    }
}

/// Bottom dock of workspaces that haven't been used in a while: compact
/// one-line rows so active work stays in view.
struct IdleDock: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject private var motion = MotionPreferences.shared
    @AppStorage("herd.idleDock.collapsed") private var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 6) {
                Button {
                    motion.perform(.sidebar) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
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
                    Image(systemName: "xmark.bin").font(.system(size: 10))
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
    @ObservedObject var store: HerdrStore
    let workspace: HerdrWorkspace
    @State private var hovered = false

    var body: some View {
        let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspace.workspaceId))
        let brand = AgentBrand.forAgent(agent?.agent)
        HStack(spacing: 6) {
            Group {
                if let brand {
                    AgentLogo(brand: brand, size: 10).saturation(0.2).opacity(0.8)
                } else {
                    Image(systemName: "terminal").font(.system(size: 9))
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 12)
            Text(workspace.label)
                .font(.system(size: 11.5))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if let project = store.projectName(of: workspace.workspaceId),
               project.caseInsensitiveCompare(workspace.label) != .orderedSame {
                Text(project)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                Button {
                    store.closeWorkspace(workspace.workspaceId)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
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
        .onTapGesture { store.focusWorkspace(workspace.workspaceId) }
        .contextMenu { WorkspaceOrganizeMenu(store: store, workspace: workspace) }
        .help("\(workspace.label) · last used \(WorkspaceActivity.ageLabel(since: store.activity.lastActive(workspace.workspaceId))) ago")
    }
}
