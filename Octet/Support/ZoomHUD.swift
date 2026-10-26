import SwiftUI

/// What ⌘+ ⌘− ⌘0 just did, near the top of the window: the size, where it
/// sits between the smallest and the largest, and a word when it's the
/// default or can go no further.
struct ZoomHUD: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if let zoom = settings.zoomIndicator {
                pill(zoom)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).combined(with: .offset(y: -6))
                        : .identity)
            }
        }
        .animation(.smooth(duration: 0.22), value: settings.zoomIndicator?.id)
        .animation(.smooth(duration: 0.18), value: settings.zoomIndicator?.size)
        .allowsHitTesting(false)
    }

    private func pill(_ zoom: SettingsStore.ZoomIndicator) -> some View {
        let range = SettingsStore.fontSizeRange
        let fraction = (zoom.size - range.lowerBound) / (range.upperBound - range.lowerBound)
        return HStack(spacing: 10) {
            OctetIcon("device.textsize", size: 13).foregroundStyle(Theme.textSecondary)
            Text("\(Int(zoom.size)) pt")
                .font(Theme.uiFontMedium.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(zoom.atLimit ? Theme.warning : Theme.accent)
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(width: 56, height: 3)
            if zoom.atLimit || zoom.atDefault {
                Text(zoom.atLimit ? (fraction > 0.5 ? "Largest" : "Smallest") : "Default")
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(zoom.atLimit ? Theme.warning : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(.top, 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text size \(Int(zoom.size)) points")
    }
}
