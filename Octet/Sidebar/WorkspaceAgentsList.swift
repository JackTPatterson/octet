import SwiftUI

/// Compact per-workspace agent disclosure, matching the sidebar's task hierarchy.
struct WorkspaceAgentsList: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    let workspaceId: String
    let brands: [AgentBrand]
    @State private var expanded = true

    private var agents: [EngineAgent] { store.snapshot.agents(inWorkspace: workspaceId) }
    private var sessions: [AgentSession] { center.sessions(in: workspaceId) }

    var body: some View {
        let count = agents.count + sessions.count
        if count > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if count > 1 {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if brands.count > 1 {
                            AgentLogoStack(brands: brands, size: 14)
                        } else if let brand = brands.first {
                            AgentLogo(brand: brand, size: 14)
                        }
                        Text("\(count) \(count == 1 ? "agent" : "agents")")
                        Spacer(minLength: 4)
                        OctetIcon(expanded ? "chevron.down" : "chevron.right", size: 10)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                if count == 1 || expanded {
                    ForEach(agents) { agent in
                        WorkspaceTerminalAgentRow(store: store, agent: agent) {
                            center.setActive(nil, in: workspaceId)
                            window.focusAgent(paneId: agent.paneId)
                        }
                    }
                    ForEach(sessions) { session in
                        WorkspaceConversationAgentRow(session: session) {
                            window.focusWorkspace(workspaceId)
                            center.setActive(session.id, in: workspaceId)
                        }
                    }
                }
            }
            .padding(.leading, 22)
        }
    }
}

private struct WorkspaceTerminalAgentRow: View {
    let store: SessionStore
    let agent: EngineAgent
    let action: () -> Void
    @ObservedObject private var usage: AgentUsageTracker

    init(store: SessionStore, agent: EngineAgent, action: @escaping () -> Void) {
        self.store = store
        self.agent = agent
        self.action = action
        _usage = ObservedObject(wrappedValue: store.usageTracker)
    }

    var body: some View {
        let tab = store.snapshot.tabs.first { $0.tabId == agent.tabId }
        let activity = agent.terminalId.flatMap { usage.lastActivity[$0] }
        let title = activity ?? agent.name ?? tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Agent"
        let since = agent.terminalId.flatMap { store.recovery.record(forTerminal: $0)?.firstSeen }
        WorkspaceAgentTaskRow(brand: AgentBrand.forAgent(agent.agent), status: agent.agentStatus,
                              title: title, since: since, timeHelp: "Time since this agent was first seen", action: action)
    }
}

private struct WorkspaceConversationAgentRow: View {
    @ObservedObject var session: AgentSession
    let action: () -> Void

    var body: some View {
        let status: EngineAgentStatus = session.pendingPermission != nil || session.pendingQuestion != nil ? .blocked
            : session.conversation.isRunning ? .working : .idle
        WorkspaceAgentTaskRow(brand: AgentBrand.forAgent(session.engine.agent), status: status,
                              title: session.title,
                              since: session.turnStartedAt ?? session.conversation.items.last?.createdAt,
                              timeHelp: status == .working ? "Time on this turn" : "Time since last activity", action: action)
    }
}

private struct WorkspaceAgentTaskRow: View {
    let brand: AgentBrand?
    let status: EngineAgentStatus
    let title: String
    let since: Date?
    let timeHelp: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                AgentStateGlyph(status: status, size: 9).frame(width: 12)
                if let brand { AgentLogo(brand: brand, size: 14) }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let since {
                        Text(WorkspaceActivity.ageLabel(since: since, now: context.date))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                            .help(timeHelp)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 3)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(brand?.displayName ?? "Agent") · \(stateLabel(status))\n\(title)")
        .accessibilityLabel("\(brand?.displayName ?? "Agent"), \(stateLabel(status)), \(title)")
    }
}
