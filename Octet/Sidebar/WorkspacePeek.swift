import SwiftUI

/// Hovering a workspace in the sidebar shows what's running in it without
/// switching to it, the way Warp's tab hover card does: every tab with its
/// agent and state, and every conversation, each one a click away.
struct WorkspacePeek: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var agents = AgentCenter.shared
    let workspace: EngineWorkspace
    let dismiss: () -> Void

    var body: some View {
        let snapshot = store.snapshot
        let tabs = snapshot.tabs(inWorkspace: workspace.workspaceId)
        let conversations = agents.sessions(in: workspace.workspaceId)
        let shownTab = WindowRegistry.shared.window(showing: workspace.workspaceId)?.displayedFocusedTabId
            ?? (window.focusedWorkspace?.workspaceId == workspace.workspaceId ? window.displayedFocusedTabId : nil)

        VStack(alignment: .leading, spacing: 2) {
            header(directory: snapshot.directory(ofWorkspace: workspace.workspaceId))
            section("Tabs", count: tabs.count)
            ForEach(tabs) { tab in
                TabPeekRow(store: store, tab: tab, showing: tab.tabId == shownTab) {
                    dismiss()
                    window.focusTabAnywhere(tab)
                }
            }
            if !conversations.isEmpty {
                section("Conversations", count: conversations.count)
                ForEach(conversations) { session in
                    ConversationPeekRow(session: session) {
                        dismiss()
                        window.focusWorkspace(workspace.workspaceId)
                        AgentCenter.shared.setActive(session.id, in: workspace.workspaceId)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(Theme.chrome)
    }

    private func header(directory: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workspace.label)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let directory {
                Text(abbreviateHome(directory))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let branch = store.branches[workspace.workspaceId] {
                HStack(spacing: 4) {
                    OctetIcon("arrow.triangle.branch", size: 10)
                    Text(branch).font(Theme.monoFont).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text("\(count)")
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// A terminal tab: its name, the agent running in it and what that agent is
/// doing. A tab with several agents (a split, or subagent viewers) lists
/// how many.
private struct TabPeekRow: View {
    @ObservedObject var store: SessionStore
    let tab: EngineTab
    let showing: Bool
    let action: () -> Void

    var body: some View {
        let running = store.snapshot.agents(inTab: tab.tabId)
        let agent = store.primaryAgent(in: running)
        let brand = AgentBrand.forAgent(agent?.agent)
        PeekRow(showing: showing, action: action) {
            AgentStateGlyph(status: agent?.agentStatus ?? tab.agentStatus)
        } mark: {
            if let brand { AgentLogo(brand: brand, size: 12) } else {
                OctetIcon("terminal", size: 12).foregroundStyle(Theme.textTertiary)
            }
        } title: {
            TabAutoName.display(label: tab.label, number: tab.number)
        } detail: {
            detail(agent: agent, brand: brand, count: running.count)
        }
    }

    private func detail(agent: EngineAgent?, brand: AgentBrand?, count: Int) -> String {
        var parts: [String] = []
        if let agent, let brand {
            let state = stateLabel(agent.agentStatus)
            parts.append(state.isEmpty ? brand.displayName : "\(brand.displayName) \(state)")
        } else {
            parts.append("Shell")
        }
        if count > 1 { parts.append("\(count) agents") }
        if tab.paneCount > 1 { parts.append("\(tab.paneCount) panes") }
        return parts.joined(separator: " · ")
    }
}

/// A native conversation, and whether it's working, waiting on you, or done.
private struct ConversationPeekRow: View {
    @ObservedObject var session: AgentSession
    let action: () -> Void

    var body: some View {
        let status: EngineAgentStatus = session.pendingPermission != nil ? .blocked
            : session.conversation.isRunning ? .working : .idle
        PeekRow(showing: false, action: action) {
            AgentStateGlyph(status: status)
        } mark: {
            if let brand = AgentBrand.forAgent(session.engine.agent) { AgentLogo(brand: brand, size: 12) }
        } title: {
            session.title
        } detail: {
            detail(status)
        }
    }

    private func detail(_ status: EngineAgentStatus) -> String {
        switch status {
        case .blocked: return "Needs your approval"
        case .working:
            guard let started = session.turnStartedAt else { return "Working" }
            let seconds = Int(Date().timeIntervalSince(started))
            return seconds < 60 ? "Working \(seconds)s" : "Working \(seconds / 60)m \(seconds % 60)s"
        default: return "\(session.engine.displayName) · idle"
        }
    }
}

/// The shared row: state, mark, title over a detail line.
private struct PeekRow<Glyph: View, Mark: View>: View {
    let showing: Bool
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let mark: () -> Mark
    let title: () -> String
    let detail: () -> String
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                glyph().frame(width: 12)
                mark().frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title())
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(detail())
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if showing {
                    Text("Showing")
                        .font(Theme.headerFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Waits before showing a hover card, and a moment before hiding it so the
/// pointer can cross from the card to it: hover intent, as menus do.
@MainActor
final class HoverIntent: ObservableObject {
    @Published var isShown = false
    private var overSource = false
    private var overCard = false
    private var pending: DispatchWorkItem?

    func source(_ hovering: Bool) {
        overSource = hovering
        schedule(hovering && !isShown ? 0.5 : 0.2)
    }

    func card(_ hovering: Bool) {
        overCard = hovering
        schedule(0.2)
    }

    func close() {
        pending?.cancel()
        overSource = false
        overCard = false
        isShown = false
    }

    private func schedule(_ delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let want = self.overSource || self.overCard
            if want != self.isShown { self.isShown = want }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
