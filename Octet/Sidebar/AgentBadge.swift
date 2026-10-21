import SwiftUI

/// Agent state glyph: shape carries the state (spinner, tick, question
/// mark, lock, dot), so colour never carries it alone; the colour is the
/// shared vocabulary's (Shared/AgentStatus.swift).
struct AgentStateGlyph: View {
    let state: AgentState
    var size: CGFloat = 10
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var appeared = false

    init(state: AgentState, size: CGFloat = 10) {
        self.state = state
        self.size = size
    }

    /// A session server status, read through the vocabulary.
    init(status: EngineAgentStatus, size: CGFloat = 10) {
        self.init(state: AgentState(status), size: size)
    }

    var body: some View {
        Group {
            switch state {
            case .working, .waiting:
                if state == .working, motion.animates(.agentStatus) {
                    LoadingLine(width: size + 2, thickness: max(1.5, size * 0.16))
                } else {
                    Capsule()
                        .fill(state.color.opacity(state == .working ? 0.5 : 0.8))
                        .frame(width: size + 2, height: max(1.5, size * 0.16))
                }
            case .needsInput, .needsApproval, .failed, .planReady:
                ZStack {
                    Circle().fill(state.color)
                    Text(mark)
                        .font(.system(size: size * 0.78, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.terminalBackground)
                        .offset(y: -0.25)
                }
                .frame(width: size + 2, height: size + 2)
            case .done:
                OctetIcon("checkmark", size: (size - 1) * 1.35)
                    .foregroundStyle(state.color)
            case .idle:
                Circle().fill(state.color).frame(width: size - 4, height: size - 4)
            case .unknown:
                Circle().strokeBorder(state.color, lineWidth: 1).frame(width: size - 3, height: size - 3)
            }
        }
        .scaleEffect(appeared ? 1 : 0.55)
        .opacity(appeared ? 1 : 0)
        .onAppear { animateIn() }
        .onChange(of: state) { _, _ in
            appeared = false
            DispatchQueue.main.async { animateIn() }
        }
        .accessibilityLabel(state.title)
    }

    /// What the filled disc says: a question, a stop, a failure, a plan.
    private var mark: String {
        switch state {
        case .needsApproval: "!"
        case .failed: "×"
        case .planReady: "≡"
        default: "?"
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

/// Several agents' logos, slightly overlapping, each ringed in the card's
/// ground so the edges stay readable, e.g. Claude and Codex together.
struct AgentLogoStack: View {
    let brands: [AgentBrand]
    var size: CGFloat = 13
    private var shown: [AgentBrand] { Array(brands.prefix(3)) }

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, brand in
                AgentLogo(brand: brand, size: size * 0.72)
                    .frame(width: size + 3, height: size + 3)
                    .background(Circle().fill(Theme.cardSelected))
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                    .zIndex(Double(shown.count - index))
            }
        }
        .help(brands.map(\.displayName).joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brands.map(\.displayName).joined(separator: " and "))
    }
}
