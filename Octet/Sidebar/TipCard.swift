import SwiftUI

/// A small card at the foot of the sidebar showing one thing Octet does that
/// is easy to miss. It only offers tips that fit the session, steps forward
/// when clicked, and can be turned off for good.
struct TipCard: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    /// Redraws the keys when a shortcut is rebound.
    @ObservedObject private var shortcuts = ShortcutOverrides.shared
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        if settings.values.showTips, let tip = store.currentTip {
            // A button, so the keyboard and VoiceOver can step through tips
            // too; the dismiss button inside still takes its own clicks.
            Button { store.nextTip() } label: {
                card(tip).padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onHover { hovered = $0 }
            .help("Click for the next tip")
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the next tip")
            .accessibilityAction(named: "Stop Showing Tips") { store.dismissTips() }
            .transition(motion.animates(.sidebar) ? .opacity.combined(with: .move(edge: .bottom)) : .identity)
            .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: tip.id)
        }
    }

    private func card(_ tip: Tip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OctetIcon("lightbulb", size: 13)
                    .foregroundStyle(Theme.accent)
                Text(tip.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let keys = OctetShortcut.named(tip.shortcut)?.keys {
                    KeyCombo(keys: keys)
                }
                // Always laid out, so hovering never reflows the title.
                Text(store.tipPosition)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered || focused ? 1 : 0)
                Button { store.dismissTips() } label: {
                    OctetIcon("xmark", size: 15)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || focused ? 1 : 0)
                .help("Stop showing tips")
                .accessibilityLabel("Stop showing tips")
            }
            Text(tip.text { OctetShortcut.named($0)?.keys })
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
