import SwiftUI

/// How "working" is drawn on an agent's avatar. The line is the original;
/// the others suit people who want something rounder or busier.
enum LoadingStyle: String, Codable, CaseIterable {
    case line, spinner, dots, pulse, bars

    var title: String {
        switch self {
        case .line: "Line"
        case .spinner: "Spinner"
        case .dots: "Dots"
        case .pulse: "Pulse"
        case .bars: "Bars"
        }
    }
}

/// A working indicator for an avatar `size` points across, drawn around or
/// under it. Every loop runs as a SwiftUI repeating animation, which Core
/// Animation drives, so a row of them doesn't rebuild views per frame.
/// Spinning is linear, since a steady turn is what reads as "busy"; the
/// breathing styles ease in and out. Reduce Motion shows a still mark.
struct LoadingIndicator: View {
    var style: LoadingStyle
    var size: CGFloat = 14
    var color: Color = Theme.accent
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var phase = false

    private var animates: Bool { motion.animates(.agentStatus) }

    var body: some View {
        Group {
            switch style {
            case .line:
                LoadingLine(width: size, thickness: 1.5, color: color).offset(y: size / 2)
            case .spinner:
                Circle()
                    .trim(from: 0, to: animates ? 0.28 : 0.6)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: size + 5, height: size + 5)
                    .rotationEffect(.degrees(animates && phase ? 360 : 0))
                    .animation(animates ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: phase)
            case .dots:
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().fill(color).frame(width: 2.5, height: 2.5)
                            .scaleEffect(animates && phase ? 1 : 0.55)
                            .opacity(animates ? (phase ? 1 : 0.35) : 0.6)
                            .animation(animates ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15) : nil, value: phase)
                    }
                }
                .offset(y: size / 2 + 2)
            case .pulse:
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: size + 4, height: size + 4)
                    .scaleEffect(animates && phase ? 1.35 : 0.95)
                    .opacity(animates ? (phase ? 0 : 0.8) : 0.4)
                    .animation(animates ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : nil, value: phase)
            case .bars:
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(color).frame(width: 1.5, height: 6)
                            .scaleEffect(y: animates ? (phase ? 1 : 0.35) : 0.6, anchor: .bottom)
                            .animation(animates ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.17) : nil, value: phase)
                    }
                }
                .frame(height: 6)
                .offset(y: size / 2 + 2)
            }
        }
        .onAppear { phase = true }
        .accessibilityElement()
        .accessibilityLabel("Working")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
