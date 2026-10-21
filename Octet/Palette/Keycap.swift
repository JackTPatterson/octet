import SwiftUI

/// One key, drawn as a small cap. The palette, tips, the cheat sheet, the
/// Keyboard settings page and the title bar all use this one, so a key
/// looks the same wherever Octet names it.
struct Keycap: View {
    let text: String
    /// Brighter, for a cap over busy content (the tab badges).
    var prominent = false

    var body: some View {
        Text(text)
            .font(Theme.Text.captionMedium)
            .foregroundStyle(prominent ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.xs + 1)
            .frame(minWidth: 18, minHeight: 18)
            .background(prominent ? Theme.cardSelected : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
    }
}

/// A whole shortcut as one cap per key: ⌃⌘↓ is ⌃, ⌘ and ↓. VoiceOver reads
/// the keys by name rather than the symbols.
struct KeyCombo: View {
    let keys: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.caps(keys).enumerated()), id: \.offset) { _, cap in
                Keycap(text: cap)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(keys))
    }

    private static let modifiers: [Character: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]

    /// "⌃⌘↓" as ⌃, ⌘, ↓; a range label ("⌘1…⌘8") or a word ("esc") stays one cap.
    static func caps(_ keys: String) -> [String] {
        guard !keys.contains("…") else { return [keys] }
        var caps: [String] = []
        var rest = Substring(keys)
        while let first = rest.first, modifiers[first] != nil {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }

    /// "⇧⌘P" as "Shift Command P".
    static func spoken(_ keys: String) -> String {
        let names: [String: String] = ["↩": "Return", "⇥": "Tab", "⌫": "Delete", "⌦": "Forward Delete",
                                       "⎋": "Escape", "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow",
                                       "↓": "Down Arrow", ".": "Period", ",": "Comma", "/": "Slash",
                                       "=": "Equals", "-": "Minus", "[": "Left Bracket", "]": "Right Bracket"]
        return caps(keys).map { cap in
            cap.count == 1 ? (modifiers[Character(cap)] ?? names[cap] ?? cap) : (names[cap] ?? cap)
        }.joined(separator: " ")
    }
}
