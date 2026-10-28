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
                        // Open, the rows below carry their own logos.
                        if !expanded {
                            if brands.count > 1 {
                                AgentLogoStack(brands: brands, size: 14)
                            } else if let brand = brands.first {
                                AgentLogo(brand: brand, size: 14)
                            }
                        }
                        Text("\(count) \(count == 1 ? "agent" : "agents")")
                        Spacer(minLength: 4)
                        OctetIcon(expanded ? "chevron.down" : "chevron.right", size: 10)
                    }
                    .font(Theme.Text.body)
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
        let tool = activity != nil ? agent.terminalId.flatMap { usage.lastTool[$0] }.flatMap { $0.isEmpty ? nil : $0 } : nil
        WorkspaceAgentTaskRow(brand: AgentBrand.forAgent(agent.agent), status: agent.agentStatus,
                              title: title, tool: tool, since: since, timeHelp: "Time since this agent was first seen", action: action)
    }
}

private struct WorkspaceConversationAgentRow: View {
    @ObservedObject var session: AgentSession
    let action: () -> Void

    var body: some View {
        let status: EngineAgentStatus = session.pendingPermission != nil || session.pendingQuestion != nil ? .blocked
            : session.conversation.isRunning ? .working : .idle
        let tool = status == .working ? session.conversation.items.last.flatMap { item -> String? in
            if case .tool(let call) = item.kind { return call.name } else { return nil }
        } : nil
        WorkspaceAgentTaskRow(brand: AgentBrand.forAgent(session.engine.agent), status: status,
                              title: session.title, tool: tool,
                              since: session.turnStartedAt ?? session.conversation.items.last?.createdAt,
                              timeHelp: status == .working ? "Time on this turn" : "Time since last activity", action: action)
    }
}

private struct WorkspaceAgentTaskRow: View {
    let brand: AgentBrand?
    let status: EngineAgentStatus
    let title: String
    /// The tool the agent is on, drawn as in the conversation's work log.
    var tool: String? = nil
    let since: Date?
    let timeHelp: String
    let action: () -> Void
    @State private var hovered = false
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                // Only a state that needs a look takes the gutter.
                if AgentState(status).needsGlyph {
                    AgentStateGlyph(status: status, size: 9).frame(width: 12)
                        .transition(motion.animates(.sidebar)
                            ? .move(edge: .leading).combined(with: .opacity) : .identity)
                }
                if let brand {
                    AgentLogo(brand: brand, size: 14)
                        // Working: the loading line runs under the logo, out of
                        // the row's height, not in a column of its own.
                        .overlay(alignment: .bottom) {
                            if AgentState(status) == .working {
                                LoadingLine(width: 14, thickness: 1.5)
                                    .offset(y: 7)
                                    .transition(.opacity)
                            }
                        }
                }
                if let tool { AgentToolMark(tool: tool, size: 12).frame(width: 14) }
                Text(title)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let since {
                        Text(WorkspaceActivity.ageLabel(since: since, now: context.date))
                            .font(Theme.interfaceFont(10).monospacedDigit())
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
        .animation(motion.animation(.sidebar, .smooth(duration: 0.25)), value: AgentState(status).needsGlyph)
        .animation(.easeOut(duration: 0.2), value: AgentState(status) == .working)
        .onHover { hovered = $0 }
        .help("\(brand?.displayName ?? "Agent") · \(stateLabel(status))\n\(title)")
        .accessibilityLabel("\(brand?.displayName ?? "Agent"), \(stateLabel(status)), \(title)")
    }
}


extension AgentState {
    /// A question, an approval, a failure, a plan or a finished turn: the
    /// states whose glyph earns the sidebar's gutter.
    var needsGlyph: Bool {
        switch self {
        case .needsInput, .needsApproval, .failed, .planReady, .done: true
        default: false
        }
    }
}

/// A tool's mark, as the conversation's work log draws it: an MCP tool's
/// service logo where there is one, else the icon for its kind.
struct AgentToolMark: View {
    let tool: String
    var size: CGFloat = 12

    var body: some View {
        if let logo = LanguageLogo(mcpTool: tool, size: size) {
            logo
        } else {
            OctetIcon(AgentToolCall.iconName(forTool: tool), size: size).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// What runs in a workspace's panes besides its agents, e.g. a Python script
/// in the split beside Claude: one avatar per program, grouped the way
/// several agents' logos are.
struct WorkspaceProcessRow: View {
    @ObservedObject var store: SessionStore
    let workspaceId: String

    /// Each program once, by the name its logo and label use.
    private var programs: [String] {
        let snapshot = store.snapshot
        let agentPanes = Set(snapshot.agents(inWorkspace: workspaceId).map(\.paneId))
        var seen = Set<String>()
        var names: [String] = []
        for pane in snapshot.panes where pane.workspaceId == workspaceId && !agentPanes.contains(pane.paneId) {
            for process in store.paneProcesses[pane.paneId]?.foreground ?? [] {
                let command = (process.name as NSString).lastPathComponent
                let bare = command.hasPrefix("-") ? String(command.dropFirst()) : command
                let lowered = bare.lowercased()
                guard !bare.isEmpty, !ShellPrompt.shells.contains(lowered), !ShellPrompt.shells.contains(command.lowercased()),
                      !EngineProtocol.processNames.contains(lowered),
                      AgentBrand.runtimeAgentID(forExecutable: bare) == nil else { continue }
                let name = Self.language(of: lowered)
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    /// "python3.12" is Python; "node" stays itself.
    private static func language(of command: String) -> String {
        var name = command
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return name.isEmpty ? command : name
    }

    var body: some View {
        let programs = programs
        if !programs.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: -14 * 0.3) {
                    ForEach(Array(programs.prefix(3).enumerated()), id: \.offset) { index, name in
                        Group {
                            if let logo = LanguageLogo(language: name, size: 10) {
                                logo
                            } else {
                                OctetIcon("terminal", size: 10).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Theme.cardSelected))
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                        .zIndex(Double(3 - index))
                    }
                }
                Text(programs.joined(separator: ", "))
                    .font(Theme.Text.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textTertiary)
            .help("Running in this workspace: " + programs.joined(separator: ", "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Running: " + programs.joined(separator: ", "))
        }
    }
}
