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
                HStack(spacing: 6) {
                    MCPAlertDisc(size: 14)
                    Text(problems.count == 1 ? "\(problems[0].name) · \(problems[0].status.title)" : "\(problems.count) MCP servers down")
                        .font(Theme.captionFont.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .frame(height: 24)
                .background(Capsule().fill(Theme.danger.opacity(hovered ? 0.2 : 0.12)))
                .overlay(Capsule().strokeBorder(Theme.danger.opacity(0.3), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .help("MCP servers that aren't working, so their tools are missing. Click for all of them.")
            .accessibilityLabel(problems.count == 1 ? "\(problems[0].name) is \(problems[0].status.title)" : "\(problems.count) MCP servers down")
        }
    }
}

/// A filled red disc with a white mark: the same alert the glyphs use.
private struct MCPAlertDisc: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.danger)
            Text("!")
                .font(.system(size: size * 0.72, weight: .black, design: .rounded))
                .foregroundStyle(Color.white)
                .offset(y: -0.25)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Raises the MCP servers dialog for a conversation, checked afresh.
@MainActor
final class MCPServersCenter: ObservableObject {
    static let shared = MCPServersCenter()

    @Published private(set) var session: AgentSession?
    @Published private(set) var checking = false
    /// The window that was in front; it draws the dialog.
    private(set) weak var window: NSWindow?

    var isPresented: Bool { session != nil }

    func show(_ session: AgentSession) {
        window = NSApp.keyWindow
        self.session = session
        recheck()
    }

    func recheck() {
        guard let session else { return }
        checking = true
        session.checkMCPServers { [weak self] in self?.checking = false }
    }

    func dismiss() { session = nil }
}

enum MCPServersDialog {
    @MainActor
    static func show(_ session: AgentSession) { MCPServersCenter.shared.show(session) }
}

/// The dialog, drawn over the whole window like Octet's other dialogs.
struct MCPServersDialogHost: View {
    @ObservedObject var center: MCPServersCenter

    var body: some View {
        OctetModalShell(isPresented: center.isPresented, window: center.window, overlayName: "mcp-servers",
                        onDismiss: { center.dismiss() }) {
            if let session = center.session {
                MCPServersCard(session: session, center: center)
            }
        }
    }
}

private struct MCPServersCard: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var center: MCPServersCenter

    private var servers: [MCPServerState] {
        // Trouble first, then the rest as the agent listed them.
        (session.mcpServers ?? []).enumerated()
            .sorted { ($0.element.status.isProblem ? 0 : 1, $0.offset) < ($1.element.status.isProblem ? 0 : 1, $1.offset) }
            .map(\.element)
    }

    var body: some View {
        let servers = servers
        let down = servers.filter(\.status.isProblem).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.hover)
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                    OctetIcon("tool.mcp", size: 24).foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(servers.isEmpty ? "No MCP servers" : down > 0 ? "\(down) of \(servers.count) MCP servers down" : "MCP servers")
                        .font(Theme.interfaceFont(15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle(servers: servers, down: down))
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !servers.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Rectangle().fill(Theme.divider.opacity(0.8)).frame(height: 1) }
                            MCPServerRow(server: server)
                        }
                    }
                }
                // Rows are about 51pt each; scroll only past six of them.
                .frame(height: min(CGFloat(servers.count) * 51, 306))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).fill(Theme.terminalBackground.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            }
            HStack(spacing: 8) {
                Text("Add or remove servers in the Marketplace.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                OctetButton(title: center.checking ? "Checking…" : "Check Again", icon: "arrow.clockwise", kind: .secondary) {
                    if !center.checking { center.recheck() }
                }
                OctetButton(title: "Done", kind: .primary) { center.dismiss() }
            }
        }
        .octetModalCard(width: 480, padding: 20)
    }

    private func subtitle(servers: [MCPServerState], down: Int) -> String {
        if servers.isEmpty {
            return "\(session.engine.displayName) has none in this conversation, or hasn't said yet (it does once the first message starts it)."
        }
        return down > 0
            ? "Their tools are missing until they work again. Sign in or fix the error shown."
            : "\(servers.count) \(servers.count == 1 ? "server" : "servers") for \(session.engine.displayName)."
    }
}

private struct MCPServerRow: View {
    let server: MCPServerState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover)
                if let logo = LanguageLogo(mcpServer: server.name, size: 16) {
                    logo
                } else {
                    OctetIcon("tool.mcp", size: 14).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = server.detail, !detail.isEmpty {
                    Text(detail)
                        .font(server.status.isProblem ? Theme.Text.mono(10.5) : Theme.captionFont)
                        .foregroundStyle(server.status.isProblem ? Theme.danger : Theme.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var status: some View {
        let color: Color = server.status.isProblem ? Theme.danger
            : server.status == .connected ? Theme.success : Theme.textTertiary
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(server.status.title)
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(server.status.isProblem ? Theme.danger : Theme.textSecondary)
        }
        .padding(.top, 6)
    }
}
