import AppKit
import SwiftUI

/// App chrome colors and metrics.
///
/// Colors are derived from the selected terminal theme (Warp's built-in
/// themes) so the whole window matches it: surfaces step from the theme
/// background toward its foreground the way Warp's Dark theme steps from
/// #050505 (chrome #111111, cards #1B1B1B, borders #2A2A2A). Metrics come from
/// `app/src/workspace/view/vertical_tabs.rs` (248pt panel, 4pt row radius,
/// tab colors at 15% opacity).
enum Theme {
    /// The active palette; updated by `SettingsStore` when the theme changes.
    nonisolated(unsafe) static var palette = ThemePalette(theme: .named("Dark"))

    static var terminalBackground: Color { palette.color(\.background) }
    static var chrome: Color { palette.color(\.chrome) }
    static var sidebar: Color { palette.color(\.sidebar) }
    static var card: Color { palette.color(\.card) }
    static var cardSelected: Color { palette.color(\.cardSelected) }
    static var hover: Color { palette.color(\.hover) }
    static var border: Color { palette.color(\.border) }
    static var divider: Color { palette.color(\.divider) }
    static var textPrimary: Color { palette.color(\.textPrimary) }
    static var textSecondary: Color { palette.color(\.textSecondary) }
    static var textTertiary: Color { palette.color(\.textTertiary) }
    static var textMuted: Color { palette.color(\.textMuted) }
    static var accent: Color { palette.color(\.accent) }
    static var isLight: Bool { palette.isLight }
    static var colorScheme: ColorScheme { palette.isLight ? .light : .dark }

    static let sidebarWidth: CGFloat = 248
    static let rowRadius: CGFloat = 4
    static let titleBarHeight: CGFloat = 38
    static let tabBarHeight: CGFloat = 34
    static let tabColorOpacity = 0.15
    static let tabColorHoverOpacity = 0.5

    static let uiFont = Font.system(size: 12)
    static let uiFontMedium = Font.system(size: 12, weight: .medium)
    static let headerFont = Font.system(size: 10.5, weight: .semibold)
    static let captionFont = Font.system(size: 10.5)
    static let monoFont = Font.system(size: 11.5, design: .monospaced)

    /// Shortcuts Herd's menus own; unbound in Ghostty so the surface lets them through.
    static let herdShortcutUnbinds = [
        "super+t",
        "super+w",
        "super+n",
        "super+b",
        "super+p",
        "super+shift+p",
        "super+o",
        "super+d",
        "super+shift+d",
        "super+shift+enter",
        "super+alt+left",
        "super+alt+right",
        "super+alt+up",
        "super+alt+down",
        "super+shift+left_bracket",
        "super+shift+right_bracket",
        "ctrl+super+up",
        "ctrl+super+down",
        "super+shift+w",
        "super+shift+t",
        "super+shift+v",
        "super+digit_1",
        "super+digit_2",
        "super+digit_3",
        "super+digit_4",
        "super+digit_5",
        "super+digit_6",
        "super+digit_7",
        "super+digit_8",
        "super+digit_9",
    ].map { "keybind = \($0)=unbind" }.joined(separator: "\n")
}

/// Herd's own buttons: the system's blue capsule doesn't belong on a panel
/// drawn in the terminal's colours.
struct HerdButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet }
    var kind: Kind = .quiet
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.captionFont)
            .foregroundStyle(kind == .primary ? Theme.terminalBackground : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(kind == .primary ? Theme.accent : Theme.card.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(kind == .primary ? Color.clear : Theme.border, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex) ?? .gray)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Chrome colors computed from a terminal theme.
struct ThemePalette: Equatable {
    let isLight: Bool
    let background: String
    let chrome: String
    let sidebar: String
    let card: String
    let cardSelected: String
    let hover: String
    let border: String
    let divider: String
    let textPrimary: String
    let textSecondary: String
    let textTertiary: String
    let textMuted: String
    let accent: String

    init(theme: TerminalTheme) {
        let bg = theme.background
        let fg = theme.foreground
        // Light backgrounds need slightly larger steps to read as layers.
        let k = theme.isLight ? 1.25 : 1.0
        func step(_ amount: Double) -> String { Self.mix(bg, fg, amount * k) }
        isLight = theme.isLight
        background = bg
        chrome = step(0.045)
        sidebar = step(0.06)
        card = step(0.085)
        cardSelected = step(0.14)
        hover = step(0.11)
        border = step(0.15)
        divider = step(0.1)
        textPrimary = Self.mix(bg, fg, 0.94)
        textSecondary = Self.mix(bg, fg, 0.6)
        textTertiary = Self.mix(bg, fg, 0.4)
        textMuted = Self.mix(bg, fg, 0.82)
        accent = theme.accent
    }

    func color(_ key: KeyPath<ThemePalette, String>) -> Color {
        Color(hex: self[keyPath: key])
    }

    func nsColor(_ key: KeyPath<ThemePalette, String>) -> NSColor {
        NSColor(hex: self[keyPath: key]) ?? .windowBackgroundColor
    }

    /// Linear sRGB mix of two hex colors (`amount` 0 = a, 1 = b).
    static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        func components(_ hex: String) -> (Double, Double, Double) {
            let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            return (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
        }
        let t = max(0, min(1, amount))
        let (ar, ag, ab) = components(a)
        let (br, bg, bb) = components(b)
        return String(format: "%02x%02x%02x",
                      Int((ar + (br - ar) * t).rounded()),
                      Int((ag + (bg - ag) * t).rounded()),
                      Int((ab + (bb - ab) * t).rounded()))
    }
}
