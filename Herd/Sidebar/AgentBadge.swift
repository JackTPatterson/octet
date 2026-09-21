import SwiftUI

/// Agent state glyph: shape carries the
/// state (spinner, tick, question mark, dot); color stays semantic.
struct AgentStateGlyph: View {
    let status: EngineAgentStatus
    var size: CGFloat = 10

    var body: some View {
        switch status {
        case .working:
            if MotionPreferences.shared.animates(.agentStatus) {
                SpinnerArc(size: size)
            } else {
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: size - 1, height: size - 1)
            }
        case .blocked:
            Image("state-blocked")
                .resizable()
                .frame(width: size + 2, height: size + 2)
                .foregroundStyle(Color(hex: AgentStateColor.blocked))
        case .done:
            HerdIcon("checkmark", size: (size - 1) * 1.35)
                .foregroundStyle(Color(hex: AgentStateColor.done))
        case .idle:
            Circle().fill(Theme.textTertiary).frame(width: size - 4, height: size - 4)
        case .unknown:
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1).frame(width: size - 3, height: size - 3)
        }
    }
}

private struct SpinnerArc: View {
    let size: CGFloat
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size - 1, height: size - 1)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
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
                HerdIcon("sparkle", size: size)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? Theme.textPrimary)
    }
}
