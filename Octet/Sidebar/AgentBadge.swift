import SwiftUI

/// Agent state glyph: shape carries the
/// state (spinner, tick, question mark, dot); color stays semantic.
struct AgentStateGlyph: View {
    let status: EngineAgentStatus
    var size: CGFloat = 10
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var appeared = false

    var body: some View {
        Group {
            switch status {
            case .working:
                if motion.animates(.agentStatus) {
                    LoadingLine(width: size + 2, thickness: max(1.5, size * 0.16))
                } else {
                    Capsule()
                        .fill(Theme.accent.opacity(0.5))
                        .frame(width: size + 2, height: max(1.5, size * 0.16))
                }
            case .blocked:
                ZStack {
                    Circle().fill(Color(hex: AgentStateColor.blocked))
                    Text("?")
                        .font(.system(size: size * 0.78, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white)
                        .offset(y: -0.25)
                }
                .frame(width: size + 2, height: size + 2)
            case .done:
                OctetIcon("checkmark", size: (size - 1) * 1.35)
                    .foregroundStyle(Color(hex: AgentStateColor.done))
            case .idle:
                Circle().fill(Theme.textTertiary).frame(width: size - 4, height: size - 4)
            case .unknown:
                Circle().strokeBorder(Theme.textTertiary, lineWidth: 1).frame(width: size - 3, height: size - 3)
            }
        }
        .scaleEffect(appeared ? 1 : 0.55)
        .opacity(appeared ? 1 : 0)
        .onAppear { animateIn() }
        .onChange(of: status) { _, _ in
            appeared = false
            DispatchQueue.main.async { animateIn() }
        }
    }

    private func animateIn() {
        motion.perform(.agentStatus, .spring(response: 0.28, dampingFraction: 0.62)) {
            appeared = true
        }
    }
}

/// Vendor mark, tinted with the vendor hue (or neutral ink).
struct AgentLogo: View {
    let brand: AgentBrand
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let asset = brand.logoAssetName {
                Image(asset).resizable().aspectRatio(contentMode: .fit)
            } else {
                OctetIcon("sparkle", size: size)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? Theme.textPrimary)
    }
}
