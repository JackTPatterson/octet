import SwiftUI

/// Shown in the composer only while one of the agent's MCP servers has
/// failed or needs signing in: it's why a tool would be missing.
struct MCPProblemChip: View {
    @ObservedObject var session: AgentSession
    @State private var hovered = false

    var body: some View {
        let problems = (session.mcpServers ?? []).filter(\.status.isProblem)
        if !problems.isEmpty {
            Button { MCPServersDialog.show(session) } label: {
                HStack(spacing: 5) {
                    OctetIcon("exclamationmark.triangle.fill", size: 11)
                        .foregroundStyle(Color(hex: AgentStateColor.blocked))
                    Text(problems.count == 1 ? "\(problems[0].name) · \(problems[0].status.title)" : "\(problems.count) MCP servers down")
                        .font(Theme.captionFont.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(hovered ? Theme.hover : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("MCP servers that aren't working, so their tools are missing. Click for all of them.")
        }
    }
}

/// Every MCP server the conversation's agent has, checked afresh.
enum MCPServersDialog {
    @MainActor
    static func show(_ session: AgentSession) {
        session.checkMCPServers {
            let servers = session.mcpServers ?? []
            let lines = servers.map { server in
                "\(server.name) — \(server.status.title)" + (server.detail.map { ": \($0)" } ?? "")
            }
            ConfirmCenter.shared.show(
                title: servers.isEmpty ? "No MCP servers" : "MCP servers",
                message: servers.isEmpty
                    ? "\(session.engine.displayName) has no MCP servers in this conversation, or hasn't said yet (it does once the first message starts it)."
                    : lines.joined(separator: "\n"),
                detail: "Add or remove servers in the Marketplace.")
        }
    }
}
