import SwiftUI

// How the shared status vocabulary (Shared/AgentStatus.swift) is drawn:
// each tone from the theme, and the context meter every surface shares.

extension AgentState.Tone {
    /// The tone in `palette`: the window's theme, or the Notch's own dark one.
    func color(in palette: ThemePalette = Theme.palette) -> Color {
        switch self {
        case .warning: palette.color(\.warning)
        case .danger: palette.color(\.danger)
        case .info: Color(hex: palette.isLight ? "2563EB" : "60A5FA")
        case .accent: palette.color(\.accent)
        case .success: palette.color(\.success)
        case .muted: palette.color(\.textTertiary)
        }
    }
}

extension AgentState {
    var color: Color { tone.color() }
}

/// A state as a dot or spinner and its word, tinted: the hub's rows and
/// header, the dashboard's cards.
struct AgentStatePill: View {
    let state: AgentState
    /// "4m": how long it has been in this state, when known.
    var duration: String? = nil
    var filled = true

    var body: some View {
        HStack(spacing: 5) {
            if state == .working {
                LoadingLine(width: 10)
            } else {
                Circle().fill(state.color).frame(width: 6, height: 6)
            }
            Text(state.title)
            if let duration {
                Text(duration).monospacedDigit().opacity(0.8)
            }
        }
        .font(Theme.Text.captionMedium)
        .foregroundStyle(state.color)
        .padding(.horizontal, filled ? Theme.Space.md : 0)
        .frame(height: 20)
        .background(Capsule().fill(filled ? state.color.opacity(0.13) : .clear))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(state.title)" + (duration.map { ", for \($0)" } ?? ""))
    }
}

extension ContextLevel {
    /// `normal` is the meter's resting colour; it warms from there.
    func color(normal: Color) -> Color {
        switch self {
        case .normal: normal
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }
}

/// How much of the model's window is used, as a ring that fills clockwise.
/// One ring and one set of thresholds for the sidebar and the composer.
struct ContextRing: View {
    let fraction: Double?
    var size: CGFloat = 12
    var normal: Color = Theme.textSecondary
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 2)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, fraction)))
                    .stroke(ContextLevel(fraction: fraction).color(normal: normal),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .animation(motion.animation(.connections, .easeOut(duration: 0.4)), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The same measure as a bar, for the hub's detail pages.
struct ContextBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card)
                Capsule().fill(ContextLevel(fraction: fraction).color(normal: Theme.textSecondary))
                    .frame(width: max(4, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
