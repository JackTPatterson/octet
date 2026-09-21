import SwiftUI

/// The strip over the terminal while an agent runs in its own interface:
/// continue it in Octet's conversation view, dismiss the offer for this run
/// of the agent, or turn the offer off.
struct AgentOfferBanner: View {
    static let height: CGFloat = 40

    let agent: EngineAgent
    let open: () -> Void
    let dismiss: () -> Void
    let never: () -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var shown = false

    var body: some View {
        let brand = AgentBrand.forAgent(agent.agent)
        HStack(spacing: 10) {
            if let brand { AgentLogo(brand: brand, size: 14) }
            Text("\(brand?.displayName ?? "The agent") is running in its own interface")
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Text("Octet can show it as a conversation.")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // Never squeezed: the words before them give way first.
            Group {
                OctetButton(title: "Open in Octet", kind: .primary, compact: true, action: open)
                    .help("Ends this terminal session and continues it in Octet")
                OctetButton(title: "Dismiss", kind: .ghost, compact: true, action: dismiss)
                    .help("Hide this until the agent is started again")
                OctetButton(title: "Don't show again", kind: .ghost, compact: true, action: never)
                    .help("Turn this banner off. Settings has the switch to bring it back")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        // The terminal below resizes once, at once; only the strip's own
        // contents fade in, so the agent isn't resized on every frame.
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -6)
        .onAppear { motion.perform(.toasts, .smooth(duration: 0.22)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(brand?.displayName ?? "Agent") is running in its own interface")
    }
}
