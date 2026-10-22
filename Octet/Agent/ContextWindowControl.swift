import SwiftUI

/// Composer-local view of the context the provider actually reports: a ring
/// and the share used, as a composer control, opening a popover with the
/// breakdown and the ways to make room.
struct ContextWindowControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    let newChat: () -> Void
    @State private var hovered = false
    private var usage: ContextWindowUsage {
        ContextWindowUsage(used: session.conversation.contextUsed,
                           limit: session.conversation.contextWindow, tokens: session.conversation.lastTokens)
    }
    var body: some View {
        OctetDropdownAnchor(spec: OctetDropdownSpec(id: "context", options: [], selected: "", select: { _ in },
            panel: { close in AnyView(ContextWindowPanel(session: session, close: close, newChat: newChat)) }), state: dropdowns) { open in
            HStack(spacing: 6) {
                // The shared ring and thresholds, as the sidebar's.
                ContextRing(fraction: usage.fraction, size: 14, normal: ChatStyle.text)
                if let fraction = usage.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.interfaceFont(12, weight: .medium).monospacedDigit())
                        .foregroundStyle(ContextLevel(fraction: fraction).color(normal: hovered || open ? ChatStyle.text : ChatStyle.mutedText))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                .fill(hovered || open ? ChatStyle.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
        }
        .accessibilityLabel("Context window")
        .accessibilityValue(usage.fraction.map { "\(Int(($0 * 100).rounded())) percent used" } ?? "Not reported yet")
        .help("Context window: what's used, and how to make room for the next turn")
    }
}

/// The context popover: how much of the window is used, one bar split into
/// what fills it (hover a part to single it out), each part's share, a word
/// when it's nearly full, and compacting or starting fresh.
private struct ContextWindowPanel: View {
    @ObservedObject var session: AgentSession
    let close: () -> Void
    let newChat: () -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered: String?
    private var usage: ContextWindowUsage {
        ContextWindowUsage(used: session.conversation.contextUsed,
                           limit: session.conversation.contextWindow, tokens: session.conversation.lastTokens)
    }
    private var selected: ContextWindowUsage.Part? { usage.parts.first { $0.id == hovered } }

    /// The parts in the accent's own family: white, then two greys.
    private func color(_ id: String) -> Color {
        switch id {
        case "cache-read": ChatStyle.text.opacity(0.55)
        case "cache-write": ChatStyle.text.opacity(0.3)
        default: ChatStyle.text
        }
    }
    private var canCompact: Bool {
        guard !session.conversation.isRunning, (usage.used ?? 0) > 0 else { return false }
        switch session.engine {
        case .claude: return true
        case .codex, .opencode: return session.threadId != nil
        case .pi: return session.runtimePID != nil
        case .qwen: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
            total
                .padding(.horizontal, 16)
                .padding(.top, 12)
            bar
                .padding(.horizontal, 16)
                .padding(.top, 12)
            legend
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            if let fraction = usage.fraction, fraction >= 0.8 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(fraction >= 0.95 ? "Nearly full. The agent will compact on its own soon; do it now to choose when."
                                          : "Getting full. Compact to keep going with a summary, or start a new chat.")
                        .font(Theme.interfaceFont(11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(ChatStyle.warning)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Rectangle().fill(ChatStyle.border).frame(height: 1)
            footer
                .padding(.horizontal, 12)
                .frame(height: 44)
        }
        .frame(width: 340)
        .chatPopover()
        .animation(motion.animation(.palette, .easeOut(duration: 0.18)), value: hovered)
        .animation(motion.animation(.palette, .spring(response: 0.4, dampingFraction: 0.88)), value: usage.used)
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Context").font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(ChatStyle.text)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if let brand = AgentBrand.forAgent(session.engine.agent) { AgentLogo(brand: brand, size: 12) }
                Text(TwinStyle.shortModel(session.conversation.model ?? session.model))
                    .font(Theme.interfaceFont(11, weight: .medium))
                    .foregroundStyle(ChatStyle.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(ChatStyle.bubble))
            .frame(maxWidth: 170, alignment: .trailing)
        }
    }

    private var total: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text((selected?.tokens ?? usage.used).map(Self.tokens) ?? "—")
                .font(Theme.interfaceFont(26, weight: .semibold).monospacedDigit())
                .foregroundStyle(ChatStyle.text)
                .contentTransition(.numericText())
            Text(selected?.label.lowercased() ?? usage.limit.map { "of \(Self.tokens($0))" } ?? "tokens used")
                .font(ChatStyle.meta)
                .foregroundStyle(ChatStyle.mutedText)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            if let fraction = usage.fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(Theme.interfaceFont(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ContextLevel(fraction: fraction).color(normal: ChatStyle.text))
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.used.map { "\($0)\(usage.limit.map { " of \($0)" } ?? "") context tokens used" } ?? "Context usage has not been reported")
    }

    /// One bar across the window: each part's share in its tone, the rest
    /// empty. The part under the pointer stays lit; the others dim.
    private var bar: some View {
        GeometryReader { proxy in
            let limit = Double(usage.limit ?? max(1, usage.used ?? 1))
            HStack(spacing: 2) {
                ForEach(usage.parts) { part in
                    let width = max(3, proxy.size.width * CGFloat(Double(part.tokens) / limit))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(part.id))
                        .opacity(hovered == nil || hovered == part.id ? 1 : 0.25)
                        .frame(width: width)
                        .onHover { hovered = $0 ? part.id : nil }
                }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ChatStyle.text.opacity(0.08))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        VStack(spacing: 0) {
            ForEach(usage.parts) { part in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color(part.id)).frame(width: 8, height: 8)
                    Text(part.label).font(ChatStyle.meta).foregroundStyle(hovered == part.id ? ChatStyle.text : ChatStyle.secondaryText)
                    Spacer()
                    if let used = usage.used, used > 0 {
                        Text("\(Int((Double(part.tokens) / Double(used) * 100).rounded()))%")
                            .font(Theme.interfaceFont(11).monospacedDigit())
                            .foregroundStyle(ChatStyle.faintIcon)
                    }
                    Text(Self.tokens(part.tokens))
                        .font(Theme.interfaceFont(12, weight: .medium).monospacedDigit())
                        .foregroundStyle(ChatStyle.text)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(hovered == part.id ? ChatStyle.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? part.id : nil }
            }
            if usage.used == nil {
                Text("Usage appears after the provider reports its first turn.")
                    .font(ChatStyle.meta).foregroundStyle(ChatStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            } else if usage.parts.count <= 1 {
                Text("The provider hasn't reported a breakdown by category.")
                    .font(Theme.interfaceFont(11)).foregroundStyle(ChatStyle.faintIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(usage.remaining.map { "\(Self.tokens($0)) left" } ?? "Limit not reported")
                .font(Theme.interfaceFont(11).monospacedDigit())
                .foregroundStyle(ChatStyle.mutedText)
            Spacer(minLength: 0)
            if session.engine != .qwen {
                ChatButton(title: "Compact", icon: "arrow.down.right.and.arrow.up.left", kind: .ghost) {
                    compact(); close()
                }
                .disabled(!canCompact)
                .help("Ask the provider to summarize this conversation, keeping the gist and freeing the room")
            }
            ChatButton(title: "New Chat", icon: "plus", kind: .outline) { close(); newChat() }
        }
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000) :
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : String(count)
    }
    private func compact() {
        guard canCompact else { return }
        switch session.engine {
        case .claude: session.send("/compact")
        case .codex: session.codexCommand("compact", arguments: "")
        case .pi: session.piCommand("compact", arguments: "")
        case .opencode: session.compactOpenCode()
        case .qwen: break
        }
    }
}
