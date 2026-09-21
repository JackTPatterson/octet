import SwiftUI

/// A small card at the foot of the sidebar showing one thing Herd does that
/// is easy to miss. It only offers tips that fit the session, steps forward
/// when clicked, and can be turned off for good.
struct TipCard: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
        if settings.values.showTips, let tip = store.currentTip {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    HerdIcon("lightbulb", size: 13)
                        .foregroundStyle(Theme.accent)
                    Text(tip.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !tip.shortcut.isEmpty {
                        Text(tip.shortcut)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
                    }
                    if hovered {
                        Text(store.tipPosition)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Button { store.dismissTips() } label: {
                        HerdIcon("xmark", size: 15)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovered ? 1 : 0)
                    .help("Stop showing tips")
                }
                Text(tip.body)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Theme.hover : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { store.nextTip() }
            .help("Click for the next tip")
            .transition(motion.animates(.sidebar) ? .opacity.combined(with: .move(edge: .bottom)) : .identity)
            .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: tip.id)
        }
    }
}
