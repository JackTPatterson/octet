import SwiftUI

/// Every agent at once: what it is doing, how long it has been doing it, how
/// full its context is, and the last thing it said. Keeping track of a dozen
/// agents across tabs and windows is the thing a multiplexer stops being able
/// to do; this is Octet's answer to it.
struct AgentBoardView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = SettingsStore.shared
    let focus: (EngineAgent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if rows.isEmpty {
                Text("No agents running")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows, id: \.agent.paneId) { row in
                            AgentBoardRow(row: row) { focus(row.agent) }
                        }
                        ForEach(store.spawnedRuntimeAgents) { agent in
                            SpawnedAgentBoardRow(agent: agent,
                                                 workspace: workspaceName(agent.workspaceId),
                                                 tab: tabName(agent.tabId)) {
                                guard let paneId = agent.paneId else { return }
                                focus(EngineAgent(paneId: paneId, tabId: agent.tabId,
                                                  workspaceId: agent.workspaceId, agent: agent.agent,
                                                  name: agent.name, displayAgent: agent.name,
                                                  agentStatus: .working, cwd: agent.cwd))
                            }
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(Theme.terminalBackground)
        .background(DarkTransparentTitleBar())
        .background(ThemedWindow(themeName: settings.values.themeName))
        .preferredColorScheme(Theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AGENTS")
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
            Text(summary)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let working = rows.filter { $0.agent.agentStatus == .working }.count + store.spawnedRuntimeAgents.count
        let waiting = rows.filter { $0.agent.agentStatus == .blocked }.count
        var parts: [String] = ["\(rows.count + store.spawnedRuntimeAgents.count) running"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        return parts.joined(separator: " · ")
    }

    private func workspaceName(_ id: String?) -> String {
        guard let id else { return "Native conversation" }
        return store.snapshot.workspaces.first { $0.workspaceId == id }?.label ?? "Workspace"
    }

    private func tabName(_ id: String?) -> String {
        guard let id else { return "" }
        guard let tab = store.snapshot.tabs.first(where: { $0.tabId == id }) else { return "" }
        return TabAutoName.display(label: tab.label, number: tab.number)
    }

    /// Agents that want you first, then the busy ones, then the rest.
    private var rows: [AgentBoardRowModel] {
        let snapshot = store.snapshot
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceId, $0.label) },
                                    uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabId, $0.label) }, uniquingKeysWith: { first, _ in first })
        let rank: [EngineAgentStatus: Int] = [.blocked: 0, .working: 1, .done: 2, .idle: 3, .unknown: 4]
        return snapshot.agents.map { agent in
            AgentBoardRowModel(
                agent: agent,
                workspace: agent.workspaceId.flatMap { workspaces[$0] } ?? "",
                tab: agent.tabId.flatMap { tabs[$0] } ?? "",
                usage: store.usageTracker.usage(forTerminal: agent.terminalId),
                lastLine: agent.terminalId.flatMap { store.usageTracker.lastActivity[$0] } ?? ""
            )
        }
        .sorted { first, second in
            let firstRank = rank[first.agent.agentStatus] ?? 9
            let secondRank = rank[second.agent.agentStatus] ?? 9
            return firstRank == secondRank ? first.tab < second.tab : firstRank < secondRank
        }
    }
}

private struct SpawnedAgentBoardRow: View {
    let agent: SpawnedRuntimeAgent
    let workspace: String
    let tab: String
    let focus: () -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(agent.agent)
        let tint = brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent
        Button(action: focus) {
            HStack(alignment: .top, spacing: 10) {
                AgentStateGlyph(status: .working, size: 10)
                    .frame(width: 12)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let brand { AgentLogo(brand: brand, size: 12) }
                        Text(agent.name)
                            .font(Theme.uiFontMedium)
                            .foregroundStyle(Theme.textPrimary)
                        Text("spawned")
                            .font(Theme.captionFont)
                            .foregroundStyle(tint)
                        Spacer(minLength: 4)
                        Text("Working")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("Started by another agent")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 5) {
                        if !tab.isEmpty { Text(tab) }
                        if !tab.isEmpty { Text("·") }
                        Text(workspace)
                        Text("·")
                        Text(agent.agent).font(Theme.monoFont)
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hovered ? Theme.hover : Theme.card.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(agent.paneId == nil)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(agent.name), spawned by another agent, working")
    }
}

struct AgentBoardRowModel {
    let agent: EngineAgent
    let workspace: String
    let tab: String
    let usage: TwinUsage?
    let lastLine: String
}

private struct AgentBoardRow: View {
    let row: AgentBoardRowModel
    let focus: () -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(row.agent.agent)
        let tint = brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent

        HStack(alignment: .top, spacing: 10) {
            AgentStateGlyph(status: row.agent.agentStatus, size: 10)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let brand { AgentLogo(brand: brand, size: 12) }
                    Text(TabAutoName.display(label: row.tab, number: 0))
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(row.workspace)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(stateLabel(row.agent.agentStatus))
                        .font(Theme.captionFont)
                        .foregroundStyle(row.agent.agentStatus == .blocked ? tint : Theme.textSecondary)
                    if let usage = row.usage, !usage.label.isEmpty {
                        Text(usage.label)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if !row.lastLine.isEmpty {
                    Text(row.lastLine)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            row.agent.agentStatus == .blocked ? tint.opacity(0.5) : Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: focus)
        .help("Go to \(row.tab)")
    }
}
