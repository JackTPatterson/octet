import SwiftUI

/// The strip under the terminal: chips for the focused pane, in the order
/// and selection set in Settings › Status Bar. Over SSH only chips about the
/// other machine (or about nothing local) show.
struct StatusBar: View {
    @ObservedObject var model: StatusBarModel
    @ObservedObject var store: SessionStore
    let ssh: SSHTarget?
    let agent: EngineAgent?
    var openOnOctetUI: (EngineAgent) -> Void = { _ in }
    @ObservedObject private var plugins = OctetPluginHost.shared
    @ObservedObject private var motion = MotionPreferences.shared
    /// Redraws the account chip when accounts change.
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.openURL) private var openURL

    static let height: CGFloat = 32

    /// Whether any chip would draw, so an empty bar takes no room.
    @MainActor
    static func hasContent(model: StatusBarModel, ssh: SSHTarget?, agent: EngineAgent?) -> Bool {
        let host = OctetPluginHost.shared
        let descriptors = Dictionary(host.statusDescriptors.map { ($0.id, $0) }) { first, _ in first }
        return host.statusBarOrder.contains { id in
            descriptors[id].map { draws($0, model: model, ssh: ssh, agent: agent) } ?? false
        }
    }

    /// "Claude · Work", for each agent whose account here isn't the default.
    static func accountLabel(for directory: String?) -> String {
        guard let directory else { return "" }
        return AccountProfiles.inForce(for: directory)
            .map { "\(AgentBrand.forAgent($0.agent)?.displayName ?? $0.agent) · \($0.name)" }
            .joined(separator: ", ")
    }

    /// Whether a chip has something to show; `chip(for:)` draws exactly these.
    static func draws(_ descriptor: StatusItemDescriptor, model: StatusBarModel, ssh: SSHTarget?, agent: EngineAgent?) -> Bool {
        switch descriptor.scope {
        case .local: guard ssh == nil else { return false }
        case .remote: guard ssh != nil else { return false }
        case .any: break
        }
        switch descriptor.id {
        case "builtin.ssh": return ssh != nil
        case "builtin.agent": return agent != nil
        case "builtin.account": return !Self.accountLabel(for: model.directory).isEmpty
        case "builtin.remoteControl": return model.remoteControlOn
        case "builtin.runtime": return model.runtime != nil
        case "builtin.directory": return model.directory != nil
        case "builtin.branch": return model.repo?.branch != nil
        case "builtin.worktree": return model.repo?.linkedWorktree == true
        case "builtin.gitState": return model.repo.map { !$0.operation.isEmpty } ?? false
        case "builtin.changes": return model.repo?.changes.map { !$0.isEmpty } ?? false
        case "builtin.pullRequest": return model.repo?.pullRequest != nil
        default: return model.pluginOutputs[descriptor.id] != nil
        }
    }

    var body: some View {
        let descriptors = Dictionary(plugins.statusDescriptors.map { ($0.id, $0) }) { first, _ in first }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plugins.statusBarOrder, id: \.self) { id in
                    if let descriptor = descriptors[id], Self.draws(descriptor, model: model, ssh: ssh, agent: agent) {
                        chip(for: descriptor)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
        }
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)), value: ssh)
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)), value: model.remoteControlOn)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.terminalBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
    }

    @ViewBuilder
    private func chip(for descriptor: StatusItemDescriptor) -> some View {
        switch descriptor.id {
        case "builtin.ssh":
            if let ssh {
                SSHHostChip(target: ssh)
                    .id(ssh.display)
                    .transition(motion.animates(.connections)
                        ? .asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity), removal: .opacity)
                        : .identity)
            }
        case "builtin.agent":
            if let agent { agentChip(agent) }
        case "builtin.account":
            let label = Self.accountLabel(for: model.directory)
            if !label.isEmpty {
                StatusChip(help: "Agents started here sign in with this account. Palette › Use Account for This Project changes it.") {
                    Image(systemName: "person.crop.circle").font(.system(size: 10, weight: .medium))
                    Text(label).lineLimit(1)
                }
            }
        case "builtin.remoteControl":
            if model.remoteControlOn {
                // Keyed like the SSH chip, so it sweeps again each time it's shown.
                remoteControlChip(model.remoteControlURL)
                    .id(model.remoteControlURL?.absoluteString ?? "remote")
                    .transition(motion.animates(.connections)
                        ? .asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity), removal: .opacity)
                        : .identity)
            }
        case "builtin.runtime":
            if let runtime = model.runtime {
                StatusChip(help: "\(runtime.name)\(model.version.map { " \($0)" } ?? "")") {
                    if let badge = plugins.runtimeBadge(id: runtime.id) {
                        RuntimeIcon(badge: badge, size: 11)
                    }
                    Text(model.version ?? runtime.name)
                }
            }
        case "builtin.directory":
            if let directory = model.directory {
                StatusChip(color: descriptor.color, help: directory) {
                    Image(systemName: "folder").font(.system(size: 10, weight: .medium))
                    Text(abbreviateHome(directory)).lineLimit(1).truncationMode(.head)
                }
                .contextMenu { Button("Copy Path") { copy(directory) } }
            }
        case "builtin.branch":
            if let repo = model.repo, let branch = repo.branch {
                StatusChip(tone: repo.detached ? .warning : .normal,
                           help: repo.detached ? "Detached at \(branch)" : "Branch \(branch)") {
                    OctetIcon("arrow.triangle.branch", size: 10)
                    Text(repo.detached ? "HEAD \(branch)" : branch).lineLimit(1).truncationMode(.middle)
                }
                .contextMenu { Button("Copy Branch Name") { copy(branch) } }
            }
        case "builtin.worktree":
            if let repo = model.repo, repo.linkedWorktree {
                StatusChip(color: descriptor.color, help: "Worktree at \(repo.root)") {
                    OctetIcon("square.stack.3d.up", size: 10)
                    Text((repo.root as NSString).lastPathComponent).lineLimit(1)
                }
            }
        case "builtin.gitState":
            if let operation = model.repo?.operation, !operation.isEmpty {
                StatusChip(tone: operation.conflicts > 0 ? .danger : .warning,
                           help: "Finish or abort it before switching branches") {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                    Text(operation.label)
                }
            }
        case "builtin.changes":
            if let changes = model.repo?.changes, !changes.isEmpty {
                StatusChip(help: "\(changes.files) changed \(changes.files == 1 ? "file" : "files") in the working tree") {
                    OctetIcon("doc", size: 10)
                    Text("\(changes.files)")
                    if changes.added > 0 || changes.removed > 0 {
                        Text("•").foregroundStyle(Theme.textTertiary)
                    }
                    if changes.added > 0 {
                        Text("+\(changes.added)").foregroundStyle(Color(hex: AgentStateColor.done))
                    }
                    if changes.removed > 0 {
                        Text("-\(changes.removed)").foregroundStyle(Color(hex: AgentStateColor.blocked))
                    }
                }
            }
        case "builtin.pullRequest":
            if let pullRequest = model.repo?.pullRequest {
                Button { openURL(pullRequest.url) } label: {
                    StatusChip(help: "\(pullRequest.title)\n\(pullRequest.statusText) · Open on GitHub") {
                        OctetIcon("arrow.triangle.pull", size: 10)
                        Text("PR #\(pullRequest.number)")
                        checksGlyph(pullRequest)
                    }
                }
                .buttonStyle(.plain)
            }
        default:
            if let output = model.pluginOutputs[descriptor.id] {
                pluginChip(descriptor, output)
            }
        }
    }

    /// Remote Control is on for the agent in this pane: a light passes over
    /// the chip; clicked, it opens the session on claude.ai.
    private func remoteControlChip(_ url: URL?) -> some View {
        Button { if let url { openURL(url) } } label: {
            StatusChip(help: url.map { "Remote Control is on · \($0.absoluteString)" } ?? "Remote Control is on", glimmer: true) {
                Circle().fill(RemoteGlimmer.tint).frame(width: 6, height: 6)
                Text("Remote")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url {
                Button("Open in claude.ai") { openURL(url) }
                Button("Copy Link") { copy(url.absoluteString) }
            }
        }
    }

    private func agentChip(_ agent: EngineAgent) -> some View {
        let brand = AgentBrand.forAgent(agent.agent)
        let name = brand?.displayName ?? agent.agent ?? "Agent"
        let blocked = agent.agentStatus == .blocked
        let movable = AgentOffer.agentId(agent) != nil
        return Button { if movable { openOnOctetUI(agent) } } label: {
            StatusChip(tone: blocked ? .warning : .normal,
                       help: movable ? "\(name) · Click to open on Octet UI" : name) {
                if let brand { AgentLogo(brand: brand, size: 11) }
                Text(blocked ? "\(name) needs you" : [name, stateLabel(agent.agentStatus)].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func checksGlyph(_ pullRequest: GitHubPullRequest) -> some View {
        switch pullRequest.checks {
        case .passing: Text("✓").foregroundStyle(Color(hex: AgentStateColor.done))
        case .failing: Text("✗").foregroundStyle(Color(hex: AgentStateColor.blocked))
        case .pending: Text("•").foregroundStyle(Theme.accent)
        case .none: EmptyView()
        }
    }

    @ViewBuilder
    private func pluginChip(_ descriptor: StatusItemDescriptor, _ output: StatusItemOutput) -> some View {
        let content = StatusChip(color: descriptor.color, tone: output.tone, help: output.help ?? descriptor.name) {
            StatusItemIcon(descriptor: descriptor)
            Text(output.text).lineLimit(1)
        }
        if let url = output.url {
            Button { openURL(url) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One chip's frame: an outlined rounded box in the terminal's font, its
/// text in the chip's colour, or in a tone's when it's warning of something.
struct StatusChip<Content: View>: View {
    var color: String?
    var tone: StatusItemOutput.Tone = .normal
    var help: String?
    /// A band of light passing over it, for something live elsewhere.
    var glimmer = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(Theme.monoFont.monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(glimmer ? RemoteGlimmer.tint.opacity(0.14) : background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(glimmer ? RemoteGlimmer.tint.opacity(0.45) : border))
            .overlay { if glimmer { RemoteGlimmer() } }
            .fixedSize()
            .help(help ?? "")
    }

    private var toneColor: Color? {
        switch tone {
        case .warning: Color(hex: AgentStateColor.blocked)
        case .danger: Theme.danger
        case .success: Color(hex: AgentStateColor.done)
        case .muted: Theme.textTertiary
        case .normal: nil
        }
    }

    private var foreground: Color {
        if glimmer { return RemoteGlimmer.tint }
        if let toneColor { return toneColor }
        let palette = Theme.palette
        return color.map {
            Color(hex: ThemePalette.readable($0, on: palette.background, toward: palette.textPrimary, minimum: 4.5))
        } ?? Theme.textPrimary
    }

    private var background: Color {
        switch tone {
        case .warning, .danger: (toneColor ?? Theme.card).opacity(0.12)
        default: Theme.card
        }
    }

    private var border: Color {
        switch tone {
        case .warning, .danger: (toneColor ?? Theme.border).opacity(0.5)
        default: Theme.border
        }
    }
}

/// A chip's icon: a plugin's image tinted like a runtime icon, or an SF Symbol.
struct StatusItemIcon: View {
    let descriptor: StatusItemDescriptor

    var body: some View {
        if let path = descriptor.iconPath {
            RuntimeIcon(badge: RuntimeBadge(id: descriptor.id, name: descriptor.name, iconPath: path, color: descriptor.color), size: 11)
        } else if let symbol = descriptor.symbol {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
        }
    }
}

/// The machine a pane is logged into, in the accent colour so it reads as
/// "not here" at a glance. A light sweeps across it once as it arrives.
struct SSHHostChip: View {
    let target: SSHTarget
    var compact = false
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: "network")
                .font(.system(size: compact ? 8.5 : 10, weight: .semibold))
            Text(compact ? target.host : target.display)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(compact ? Theme.captionFont : Theme.monoFont)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, compact ? 5 : 7)
        .frame(height: compact ? 16 : 22)
        .background(RoundedRectangle(cornerRadius: compact ? 4 : 6).fill(Theme.accent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 6).strokeBorder(Theme.accent.opacity(0.45)))
        .overlay {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Theme.accent.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.4)
                    .offset(x: sweep * proxy.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 6))
            .allowsHitTesting(false)
        }
        .help("Connected over SSH to \(target.display)")
        .accessibilityLabel("SSH to \(target.display)")
        .onAppear {
            guard motion.animates(.connections) else { return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.15)) { sweep = 1.1 }
        }
    }
}

/// Shown over the terminal for a moment when the focused pane connects:
/// this Mac, a stream of packets, the other machine, and its name.
struct SSHConnectCard: View {
    let target: SSHTarget
    @State private var start = Date()
    @State private var landed = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TimelineView(.animation) { timeline in
                let phase = min(1, timeline.date.timeIntervalSince(start) / 1.2)
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { dot in
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 4, height: 4)
                            .opacity(Self.pulse(dot, phase: phase))
                    }
                }
            }
            Image(systemName: "server.rack")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .scaleEffect(landed ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(target.display)
                    .font(Theme.monoFont.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .onAppear {
            start = Date()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.9)) { landed = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected to \(target.display)")
    }

    /// Each dot lights as the stream passes it, then settles on.
    private static func pulse(_ dot: Int, phase: Double) -> Double {
        let position = Double(dot) / 4
        return phase >= 1 ? 1 : max(0.2, 1 - abs(phase * 1.4 - position) * 3)
    }
}
