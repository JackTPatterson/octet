import SwiftUI

// The pieces the Other Macs screens share (Settings, the Peer window, the
// pairing dialog), after T3 Code's Connections: a machine glyph, a status
// dot, a quiet status line, empty and error states.

extension PeerPresentation.Tone {
    /// Green when it's there, muted when it isn't, amber when it needs
    /// something, red when it failed.
    var color: Color {
        switch self {
        case .online: Color(hex: AgentStateColor.done)
        case .idle: Theme.textTertiary.opacity(0.55)
        // No theme token for a caution; this amber reads on light and dark.
        case .warning: Color(hex: "#c99a2e")
        case .error: Theme.danger
        }
    }

    /// The status text's colour: muted unless something's wrong.
    var textColor: Color {
        switch self {
        case .online, .idle: Theme.textTertiary
        case .warning: Color(hex: "#c99a2e")
        case .error: Theme.danger
        }
    }
}

/// T3 Code's connection dot: filled, with a soft ring while connected so
/// "online" reads at a glance without moving.
struct PeerStatusDot: View {
    let tone: PeerPresentation.Tone
    var size: CGFloat = 7
    var help: String?

    var body: some View {
        ZStack {
            if tone == .online {
                Circle().fill(tone.color.opacity(0.22)).frame(width: size + 6, height: size + 6)
            }
            Circle().fill(tone.color).frame(width: size, height: size)
        }
        .frame(width: size + 6, height: size + 6)
        .help(help ?? "")
        .accessibilityHidden(help == nil)
        .accessibilityLabel(help ?? "")
    }
}

/// A Mac's glyph: a laptop for a MacBook, a desktop otherwise, as T3
/// Code marks each environment by its machine kind.
struct PeerMachineIcon: View {
    let name: String
    var size: CGFloat = 13

    var body: some View {
        let lower = name.lowercased()
        let laptop = lower.contains("book") || lower.contains("laptop") || lower.hasSuffix("-lt")
        Image(systemName: laptop ? "laptopcomputer" : "desktopcomputer")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: size + 6, height: size + 4)
            .accessibilityHidden(true)
    }
}

/// A small outlined label beside a name, like T3 Code's "This device".
struct PeerChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
    }
}

/// A centred empty state: a glyph in a soft tile, a title, a line of what
/// to do, and the action that does it.
struct PeerEmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
    }
}

extension PeerEmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message, action: { EmptyView() })
    }
}

/// Why a request to a Mac failed and what to do, with a retry, in the
/// issue's colour: offline is quiet, refused and failures are red.
struct PeerIssueBanner: View {
    let issue: PeerPresentation.Issue
    let machine: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(issue.tone == .idle ? Theme.textTertiary : issue.tone.color)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Text(issue.advice(machine: machine))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let retry {
                OctetButton(title: "Try Again", icon: "arrow.clockwise", kind: .ghost, compact: true, action: retry)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(issue.tone == .idle ? Theme.hover.opacity(0.5) : issue.tone.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(issue.tone == .idle ? Theme.border.opacity(0.6) : issue.tone.color.opacity(0.3), lineWidth: 1))
    }

    private var icon: String {
        switch issue {
        case .offline, .off: "wifi.slash"
        case .timedOut: "clock"
        case .refused: "hand.raised"
        case .versionTooOld: "arrow.up.circle"
        case .identityChanged, .notPaired: "key"
        case .other: "exclamationmark.triangle"
        }
    }
}

/// A row's actions behind an ellipsis that shows on hover, as T3 Code's
/// environment rows keep theirs out of sight until wanted.
struct PeerRowMenu<Content: View>: View {
    let label: String
    let visible: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        Menu {
            content()
        } label: {
            OctetIcon("ellipsis", size: 14)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .opacity(visible || hovered ? 1 : 0)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A quiet heading over a list in the Peer window.
struct PeerSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 2)
    }
}

extension PeerSectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title, trailing: { EmptyView() }) }
}

/// What the Other Macs screens show for one paired Mac, from the center
/// and the panel model, so Settings and the Peer window say the same thing.
@MainActor
struct PeerMachineState {
    let peer: PairedPeer
    let online: Bool
    let agents: [PeerProtocol.Agent]?
    let issue: PeerPresentation.Issue?
    let version: String?
    let latency: TimeInterval?
    let lastSeen: Date?

    init(_ peer: PairedPeer, center: PeerCenter, model: PeerPanelModel) {
        self.peer = peer
        online = center.online.contains(peer.device)
        agents = model.agents[peer.name]
        issue = model.issues[peer.name]
        version = model.versions[peer.name]
        latency = model.latency[peer.name]
        lastSeen = online ? nil : center.lastSeen[peer.device]
    }

    func status(now: Date = Date()) -> PeerPresentation.Status {
        PeerPresentation.status(online: online, agents: agents?.count, issue: issue, lastSeen: lastSeen,
                                remoteVersion: version, localVersion: PeerCenter.appVersion, now: now)
    }

    /// The status line's tooltip: everything known, one fact per line.
    var details: String {
        var lines = [online ? "Connected" : "Not connected"]
        if let issue { lines.append(issue.advice(machine: peer.name)) }
        if let version { lines.append("Octet \(version)") }
        if let latency, online { lines.append("Answered in \(PeerPresentation.latency(latency))") }
        lines.append("Key \(peer.fingerprint)")
        lines.append("Paired \(peer.paired.formatted(date: .abbreviated, time: .omitted))")
        return lines.joined(separator: "\n")
    }
}
