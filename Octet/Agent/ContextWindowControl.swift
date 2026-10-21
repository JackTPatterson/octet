import SwiftUI

/// Composer-local view of the context the provider actually reports.
struct ContextWindowControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    let newChat: () -> Void
    private var usage: ContextWindowUsage {
        ContextWindowUsage(used: session.conversation.contextUsed,
                           limit: session.conversation.contextWindow, tokens: session.conversation.lastTokens)
    }
    var body: some View {
        OctetDropdownAnchor(spec: OctetDropdownSpec(id: "context", options: [], selected: "", select: { _ in },
            panel: { close in AnyView(ContextWindowPanel(session: session, close: close, newChat: newChat)) }), state: dropdowns) { open in
            HStack(spacing: 5) {
                // The shared ring and thresholds, as the sidebar's.
                ContextRing(fraction: usage.fraction, size: 13, normal: Theme.textPrimary)
                Text(usage.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Context")
                    .font(Theme.interfaceFont(10).monospacedDigit())
            }.foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7).frame(height: 25)
                .background(open ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel("Context window")
        .help("View context usage and make room for the next turn")
    }
}

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
    private func color(_ id: String) -> Color {
        switch id {
        case "cache-read": Color(red: 0.49, green: 0.46, blue: 0.90)
        case "cache-write": Color(red: 0.23, green: 0.73, blue: 0.52)
        default: Color(red: 0.35, green: 0.56, blue: 0.92)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Context window").font(Theme.uiFontMedium)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    if let brand = AgentBrand.forAgent(session.engine.agent) { AgentLogo(brand: brand, size: 12) }
                    Text(TwinStyle.shortModel(session.conversation.model ?? session.model))
                        .font(Theme.interfaceFont(9)).lineLimit(1).truncationMode(.middle)
                }.padding(.horizontal, 5).padding(.vertical, 3).background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((selected?.tokens ?? usage.used).map(Self.tokens) ?? "—")
                    .font(Theme.interfaceFont(23, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                Text(selected?.label ?? usage.limit.map { "of \(Self.tokens($0)) tokens" } ?? "tokens used")
                    .font(Theme.interfaceFont(10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if let fraction = usage.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.interfaceFont(10).monospacedDigit())
                        .foregroundStyle(ContextLevel(fraction: fraction).color(normal: Theme.textSecondary))
                        .padding(.horizontal, 5).padding(.vertical, 3).background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(usage.used.map { "\($0)\(usage.limit.map { " of \($0)" } ?? "") context tokens used" } ?? "Context usage has not been reported")
            let cells = usage.cells()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: 36), spacing: 2) {
                ForEach(cells.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.3)
                        .fill(cells[index].map(color) ?? Theme.hover)
                        .opacity(hovered == nil || cells[index] == hovered ? 1 : 0.25)
                        .frame(height: 6)
                        .animation(motion.animation(.palette, .easeOut(duration: 0.2).delay(Double(index) * 0.0015)), value: cells[index])
                        .onHover { inside in hovered = inside ? cells[index] : nil }
                }
            }.accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(usage.parts) { part in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(color(part.id)).frame(width: 7, height: 7)
                        Text(part.label).font(Theme.uiFont)
                        Spacer()
                        Text(Self.tokens(part.tokens)).font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }.frame(height: 29).contentShape(Rectangle())
                        .onHover { hovered = $0 ? part.id : nil }
                }
                if usage.used == nil {
                    Text("Usage appears after the provider reports its first turn.")
                        .font(Theme.uiFont).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else if usage.parts.count <= 1 {
                    Text("The provider has not reported a per-category breakdown.")
                        .font(Theme.interfaceFont(10)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(usage.remaining.map { "\(Self.tokens($0)) left" } ?? "Limit not reported")
                    .font(Theme.interfaceFont(10)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                if session.engine != .qwen {
                    OctetButton(title: "Compact", icon: "arrow.up.left.and.arrow.down.right", kind: .ghost, compact: true) {
                        compact(); close()
                    }.disabled(!canCompact)
                    .help("Ask the provider to summarize this conversation")
                }
                OctetButton(title: "New chat", icon: "arrow.right", kind: .secondary, compact: true) { close(); newChat() }
            }
        }.padding(14).frame(width: 360).octetGlass(cornerRadius: 11)
            .animation(motion.animation(.palette, .easeOut(duration: 0.16)), value: hovered)
            .animation(motion.animation(.palette, .easeOut(duration: 0.2)), value: usage.used)
            .onExitCommand(perform: close)
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
