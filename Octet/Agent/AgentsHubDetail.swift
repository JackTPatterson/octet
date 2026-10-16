import SwiftUI

// MARK: - Header

/// The detail side's header, after T3 Code's chat header: the agent's mark,
/// its name with its state as a pill, where it runs as a quiet breadcrumb
/// beneath, and what can be done with it on the right.
struct HubDetailHeader<Actions: View>: View {
    let vendor: String?
    let title: String
    let status: HubAgent.Status
    let crumbs: [String]
    @ViewBuilder var actions: () -> Actions

    static var height: CGFloat { 64 }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let brand = AgentBrand.forAgent(vendor) {
                    AgentLogo(brand: brand, size: 18)
                } else {
                    OctetIcon("sparkle", size: 18).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.interfaceFont(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    HubStatusPill(status: status)
                }
                HStack(spacing: 5) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Text("/").foregroundStyle(Theme.textMuted).accessibilityHidden(true) }
                        Text(crumb)
                            .foregroundStyle(index == crumbs.count - 1 ? Theme.textSecondary : Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(Theme.captionFont)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) { actions() }
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
    }
}

/// The agent's state as a tinted capsule: amber waiting on you, the accent
/// while working, green once done.
struct HubStatusPill: View {
    let status: HubAgent.Status

    var body: some View {
        HStack(spacing: 5) {
            if status == .working {
                LoadingLine(width: 10)
            } else {
                Circle().fill(status.color).frame(width: 6, height: 6)
            }
            Text(status.title)
        }
        .font(Theme.interfaceFont(11, weight: .medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(status.color.opacity(0.13)))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.title)")
    }
}

// MARK: - Empty state

/// A pane with nothing to show: a mark in a soft tile, a line saying so, a
/// line saying what to do, and sometimes a way to do it.
struct HubEmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            OctetIcon(icon, size: 18)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(Theme.border, lineWidth: 1))
            VStack(spacing: 4) {
                Text(title).font(Theme.interfaceFont(13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action()
        }
        .frame(maxWidth: 300)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension HubEmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message, action: { EmptyView() })
    }
}

// MARK: - Sections

/// A section's title, as on the Usage page.
struct HubSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }
}

/// How much of the model's window the agent is using, as a bar that warms
/// as it fills; with no window to measure against, how much is in play.
struct HubContextMeter: View {
    let used: Int
    let window: Int?

    private var fraction: Double? {
        guard let window, window > 0, used > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HubSectionTitle(text: "Context")
                Spacer()
                Text(label)
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.card)
                        Capsule().fill(colour(fraction))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context")
        .accessibilityValue(label)
    }

    private var label: String {
        let tokens = TwinUsage.compact(used)
        guard let fraction, let window else { return "\(tokens) tokens in play" }
        return "\(Int((fraction * 100).rounded()))% · \(tokens) of \(TwinUsage.compact(window))"
    }

    /// Quiet until it matters, then increasingly not, as the sidebar's ring.
    private func colour(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: Theme.textSecondary
        case ..<0.9: Color(hex: "e0af68")
        default: Color(hex: "e5484d")
        }
    }
}

/// Label and value pairs: model, folder, workspace and the like.
struct HubFacts: View {
    let rows: [(label: String, value: String, mono: Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 84, alignment: .leading)
                    Text(row.value)
                        .font(row.mono ? Theme.monoFont : Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// The files an agent edited, in the order first touched, with how often.
struct HubFilesList: View {
    let files: [(path: String, edits: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(files, id: \.path) { file in
                HStack(spacing: 8) {
                    OctetIcon("doc", size: 12).foregroundStyle(Theme.textTertiary)
                    Text(file.path)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    if file.edits > 1 {
                        Text("\(file.edits) edits")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.bottom, 4)
    }
}

/// The last few commands it ran, a failed one marked.
struct HubCommandsList: View {
    let commands: [(command: String, failed: Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(commands.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$").font(Theme.monoFont).foregroundStyle(Theme.textMuted)
                    Text(entry.command)
                        .font(Theme.monoFont)
                        .foregroundStyle(entry.failed ? Theme.danger : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    if entry.failed {
                        Spacer(minLength: 6)
                        Text("failed").font(Theme.captionFont).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.bottom, 4)
    }
}

/// A card for an agent's own words.
private struct HubQuote<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A note above the sections: "waiting on you", "the log is gone".
struct HubCallout: View {
    let icon: String
    let title: String
    let message: String
    var tint: Color = HubStyle.waiting

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OctetIcon(icon, size: 14).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

/// What a transcript adds up to, above it: context and the files touched.
/// Draws nothing when the transcript says neither.
struct HubTranscriptSummary: View {
    let conversation: AgentConversation
    let cwd: String
    @State private var filesOpen = false

    var body: some View {
        let files = HandoffBrief.changedFiles(in: conversation.items, cwd: cwd)
        if conversation.contextUsed != nil || !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let used = conversation.contextUsed, used > 0 {
                    HubContextMeter(used: used, window: conversation.contextWindow)
                        .padding(.bottom, 4)
                }
                if !files.isEmpty {
                    OctetCollapsible(title: "Files touched · \(files.count)", open: $filesOpen) {
                        HubFilesList(files: files)
                    }
                }
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.top, 4)
            }
        }
    }
}

// MARK: - Chat

/// A conversation in Octet: what it's doing, how full its context is, what
/// it last said and what it touched. It opens where it runs.
struct ChatHubDetail: View {
    let agent: HubAgent
    @ObservedObject var session: AgentSession
    let focus: () -> Void
    @State private var filesOpen = true
    @State private var commandsOpen = true

    private var status: HubAgent.Status {
        session.pendingPermission != nil || session.pendingQuestion != nil ? .needsInput
            : session.conversation.isRunning ? .working : .done
    }

    var body: some View {
        let conversation = session.conversation
        let files = HandoffBrief.changedFiles(in: conversation.items, cwd: session.cwd)
        let commands = HandoffBrief.lastCommands(in: conversation.items, count: 5)
        let lastReply = conversation.items.last { item in
            if case .text(let text) = item.kind { return !text.isEmpty }
            return false
        }
        VStack(spacing: 0) {
            HubDetailHeader(vendor: agent.vendor, title: session.title, status: status,
                            crumbs: ["Chat", agent.workspace ?? abbreviateHome(session.cwd)]) {
                if conversation.isRunning {
                    OctetButton(title: "Stop", icon: "pause.circle", kind: .secondary, compact: true) { session.interrupt() }
                        .help("End this turn; the conversation stays")
                }
                OctetButton(title: "Open Chat", icon: "arrow.up.right", kind: .primary, compact: true, action: focus)
                    .help("Go to the conversation (Return)")
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if status == .needsInput {
                        HubCallout(icon: "message", title: "Waiting on you",
                                   message: "It has a question or needs permission to go on. Open the chat to answer.")
                    }
                    HubFacts(rows: facts(conversation))
                    if let used = conversation.contextUsed, used > 0 {
                        HubContextMeter(used: used, window: conversation.contextWindow)
                    }
                    if let lastReply {
                        VStack(alignment: .leading, spacing: 10) {
                            HubSectionTitle(text: "Last reply")
                            HubQuote { ItemRow(item: lastReply, running: false) }
                        }
                    }
                    if !files.isEmpty || !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            if !files.isEmpty {
                                OctetCollapsible(title: "Files touched · \(files.count)", open: $filesOpen) {
                                    HubFilesList(files: files)
                                }
                            }
                            if !commands.isEmpty {
                                OctetCollapsible(title: "Recent commands", open: $commandsOpen) {
                                    HubCommandsList(commands: commands)
                                }
                            }
                        }
                    }
                    if lastReply == nil, files.isEmpty, commands.isEmpty {
                        Text("Nothing said yet.")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .octetScrollIndicators()
        }
    }

    private func facts(_ conversation: AgentConversation) -> [(label: String, value: String, mono: Bool)] {
        var rows: [(label: String, value: String, mono: Bool)] = []
        if let brand = AgentBrand.forAgent(agent.vendor) { rows.append(("Agent", brand.displayName, false)) }
        let model = conversation.model ?? session.model
        if !model.isEmpty { rows.append(("Model", model, true)) }
        if let workspace = agent.workspace { rows.append(("Workspace", workspace, false)) }
        rows.append(("Folder", abbreviateHome(session.cwd), true))
        if let cost = conversation.costUSD, cost > 0 { rows.append(("Cost", String(format: "$%.2f", cost), false)) }
        return rows
    }
}

// MARK: - Terminal

/// An agent in a terminal tab (or a cloud session streamed into one): its
/// state, context and latest activity, as the sidebar reads them. The full
/// conversation is in its tab.
struct TerminalHubDetail: View {
    let agent: HubAgent
    @ObservedObject var tracker: AgentUsageTracker
    let focus: () -> Void

    var body: some View {
        let usage = tracker.usage(forTerminal: agent.terminalId)
        let activity = agent.terminalId.flatMap { tracker.lastActivity[$0] }
        VStack(spacing: 0) {
            HubDetailHeader(vendor: agent.vendor, title: agent.title, status: agent.status,
                            crumbs: [agent.place.title] + [agent.workspace, agent.tab].compactMap { $0 }) {
                OctetButton(title: "Go to Tab", icon: "arrow.up.right", kind: .primary, compact: true, action: focus)
                    .help("Go to its terminal tab (Return)")
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if agent.status == .needsInput {
                        HubCallout(icon: "message", title: "Waiting on you",
                                   message: "It's asking something in its terminal. Go to the tab to answer.")
                    }
                    HubFacts(rows: facts)
                    if let usage, usage.currentContextTokens > 0 {
                        HubContextMeter(used: usage.currentContextTokens, window: usage.effectiveContextWindow)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HubSectionTitle(text: "Latest activity")
                        if let activity, !activity.isEmpty {
                            HubQuote {
                                Text(activity)
                                    .font(Theme.uiFont)
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(activity == nil ? "Nothing read from its session yet. Its conversation is in the tab."
                                             : "The full conversation is in its tab.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .octetScrollIndicators()
        }
    }

    private var facts: [(label: String, value: String, mono: Bool)] {
        var rows: [(label: String, value: String, mono: Bool)] = []
        if let brand = agent.brandName { rows.append(("Agent", brand, false)) }
        if let workspace = agent.workspace { rows.append(("Workspace", workspace, false)) }
        if let tab = agent.tab { rows.append(("Tab", tab, false)) }
        if let cwd = agent.cwd { rows.append(("Folder", abbreviateHome(cwd), true)) }
        return rows
    }
}
