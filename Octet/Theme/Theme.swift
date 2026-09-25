import AppKit
import SwiftUI

/// App chrome colors and metrics.
///
/// Colors are derived from the selected terminal theme so the whole window
/// matches it: surfaces step from the theme background toward its foreground,
/// the way the Dark theme steps outward from its charcoal terminal surface.
/// Vertical tab metrics: 248pt panel, 4pt row radius, tab
/// colors at 15% opacity.
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
    /// Text and icons drawn on an accent fill.
    static var onAccent: Color { palette.color(\.onAccent) }
    /// Errors and destructive actions, from the theme's own red.
    static var danger: Color { palette.color(\.danger) }
    static var isLight: Bool { palette.isLight }
    static var colorScheme: ColorScheme { palette.isLight ? .light : .dark }

    static let sidebarWidth: CGFloat = 248
    static let rowRadius: CGFloat = 4
    static let titleBarHeight: CGFloat = 38
    static let tabBarHeight: CGFloat = 34
    /// Tabs share one width.
    static let tabWidth: CGFloat = 180
    static let tabColorOpacity = 0.15
    static let tabColorHoverOpacity = 0.25

    static let uiFont = Font.system(size: 12)
    static let uiFontMedium = Font.system(size: 12, weight: .medium)
    static let headerFont = Font.system(size: 10.5, weight: .semibold)
    static let captionFont = Font.system(size: 10.5)
    static let monoFont = Font.system(size: 11.5, design: .monospaced)

    /// Shortcuts Octet's menus own; unbound in the renderer so the surface lets them through.
    static let octetShortcutUnbinds = [
        "super+t",
        "super+w",
        "super+n",
        "super+b",
        "super+p",
        "super+f",
        "super+g",
        "super+shift+g",
        "super+shift+p",
        "super+shift+r",
        "super+shift+i",
        "super+o",
        "super+shift+o",
        "super+s",
        "super+alt+s",
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
        "super+digit_1",
        "super+digit_2",
        "super+digit_3",
        "super+digit_4",
        "super+digit_5",
        "super+digit_6",
        "super+digit_7",
        "super+digit_8",
        "super+digit_9",
        // Font size is Octet's View menu, which changes the setting for every
        // pane. The renderer binds the characters, so both forms are unbound.
        "super+=",
        "super+equal",
        "super+plus",
        "super+-",
        "super+minus",
        "super+0",
        "super+digit_0",
    ].map { "keybind = \($0)=unbind" }.joined(separator: "\n")
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
    let onAccent: String
    let danger: String
    /// Command-line syntax colors, from the theme's ANSI palette.
    let syntaxBuiltin: String
    let syntaxFlag: String
    let syntaxString: String
    let syntaxPath: String
    let syntaxVariable: String

    /// Minimum contrast ratios (WCAG). Body text needs 4.5:1; hints and
    /// accents, which never carry text alone, 3:1. Increase Contrast in
    /// System Settings raises both a step.
    private struct Targets {
        let primary, secondary, tertiary, accent: Double
        static let standard = Targets(primary: 7, secondary: 4.5, tertiary: 3, accent: 3)
        static let high = Targets(primary: 10, secondary: 7, tertiary: 4.5, accent: 4.5)
    }

    init(theme: TerminalTheme, highContrast: Bool = SystemDisplay.increaseContrast) {
        let bg = theme.background
        let fg = theme.foreground
        let targets = highContrast ? Targets.high : .standard
        // Light backgrounds need slightly larger steps to read as layers;
        // Increase Contrast makes borders and fills plainly visible.
        let k = (theme.isLight ? 1.25 : 1.0) * (highContrast ? 1.8 : 1.0)
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
        // Text is checked against the busiest surface it sits on.
        let surface = cardSelected
        textPrimary = Self.readable(Self.mix(bg, fg, 0.94), on: surface, toward: fg, minimum: targets.primary)
        textSecondary = Self.readable(Self.mix(bg, fg, 0.6), on: surface, toward: fg, minimum: targets.secondary)
        textTertiary = Self.readable(Self.mix(bg, fg, 0.4), on: surface, toward: fg, minimum: targets.tertiary)
        textMuted = Self.readable(Self.mix(bg, fg, 0.82), on: surface, toward: fg, minimum: targets.secondary)
        accent = Self.readable(theme.accent, on: bg, toward: fg, minimum: targets.accent)
        onAccent = Self.contrast("ffffff", accent) >= Self.contrast("000000", accent) ? "ffffff" : "000000"
        let ansi = theme.ansi.count >= 8 ? theme.ansi : Array(repeating: fg, count: 8)
        danger = Self.readable(ansi[1], on: bg, toward: fg, minimum: targets.secondary)
        // The prompt line is drawn on the terminal background.
        syntaxBuiltin = Self.readable(ansi[6], on: bg, toward: fg, minimum: targets.secondary)
        syntaxFlag = Self.readable(ansi[5], on: bg, toward: fg, minimum: targets.secondary)
        syntaxString = Self.readable(ansi[2], on: bg, toward: fg, minimum: targets.secondary)
        syntaxPath = Self.readable(ansi[4], on: bg, toward: fg, minimum: targets.secondary)
        syntaxVariable = Self.readable(ansi[3], on: bg, toward: fg, minimum: targets.secondary)
    }

    /// `color`, moved toward `target` (then to black or white if the target
    /// itself falls short) just far enough to reach `minimum` contrast.
    static func readable(_ color: String, on surface: String, toward target: String, minimum: Double) -> String {
        if contrast(color, surface) >= minimum { return color }
        for i in 1...20 {
            let candidate = mix(color, target, Double(i) / 20)
            if contrast(candidate, surface) >= minimum { return candidate }
        }
        // Keep going the way the target already points (darker or lighter).
        let extreme = luminance(target) < luminance(surface) ? "000000" : "ffffff"
        for i in 1...20 {
            let candidate = mix(target, extreme, Double(i) / 20)
            if contrast(candidate, surface) >= minimum { return candidate }
        }
        return extreme
    }

    /// WCAG contrast ratio between two hex colors, 1...21.
    static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG relative luminance of a hex color.
    static func luminance(_ hex: String) -> Double {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
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

/// System display preferences Octet follows (System Settings > Accessibility
/// > Display), and the system's light/dark appearance.
enum SystemDisplay {
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// Read from the global default so it works before NSApp exists.
    static var isDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
}
