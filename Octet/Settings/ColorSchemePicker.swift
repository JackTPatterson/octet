import SwiftUI

/// Settings › Appearance's colour scheme, after T3 Code's mode tiles:
/// System, Light and Dark, each a small drawing of Octet in that scheme.
/// System is Match system appearance; Light and Dark switch to the light or
/// dark theme last picked for that slot.
enum OctetColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What the settings say now. With Match system off, the theme showing
    /// decides, so an imported or picked theme reads as what it looks like.
    static func current(_ values: OctetSettings) -> OctetColorScheme {
        if values.matchSystemAppearance { return .system }
        return TerminalTheme.named(values.themeName).isLight ? .light : .dark
    }

    /// The built-in scheme: Match system off, the Dark theme.
    static var `default`: OctetColorScheme { current(OctetSettings.defaults) }

    /// `values` switched to this scheme, in one change so the store applies
    /// it once rather than flashing through a half-set state.
    func applied(to values: OctetSettings) -> OctetSettings {
        var next = values
        next.matchSystemAppearance = self == .system
        switch self {
        case .system: break // The store resolves the showing theme.
        case .light: next.themeName = values.lightThemeName
        case .dark: next.themeName = values.darkThemeName
        }
        return next
    }
}

struct ColorSchemeTiles: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let current = OctetColorScheme.current(settings.values)
        let light = ThemePalette(theme: .named(settings.values.lightThemeName))
        let dark = ThemePalette(theme: .named(settings.values.darkThemeName))
        HStack(spacing: 12) {
            ForEach(OctetColorScheme.allCases) { scheme in
                ColorSchemeTile(
                    scheme: scheme,
                    active: scheme == current,
                    light: light,
                    dark: dark
                ) {
                    guard scheme != current else { return }
                    settings.values = scheme.applied(to: settings.values)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color scheme")
    }
}

/// One scheme: rounded 14, a hairline border, the drawing and its name. The
/// one in use is ringed in the accent, as T3 Code's active tile is.
private struct ColorSchemeTile: View {
    let scheme: OctetColorScheme
    let active: Bool
    let light: ThemePalette
    let dark: ThemePalette
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(height: 120)
                Text(scheme.title)
                    .font(Theme.interfaceFont(12, weight: .medium))
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(shape.fill(active ? Theme.cardSelected.opacity(0.6)
                                   : hovered ? Theme.hover.opacity(0.6) : Theme.card.opacity(0.6)))
            .overlay(shape.strokeBorder(active ? Theme.accent : Theme.border.opacity(0.7), lineWidth: active ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(scheme == .system ? "Follow the system appearance" : "Use \(scheme.title.lowercased()) mode")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg)
        Group {
            switch scheme {
            case .light: OctetWireframe(palette: light)
            case .dark: OctetWireframe(palette: dark)
            case .system:
                // Split down the middle: light on the left, dark on the right.
                ZStack {
                    OctetWireframe(palette: light)
                        .mask(HalfMask(left: true))
                    OctetWireframe(palette: dark)
                        .mask(HalfMask(left: false))
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// One half of a tile, with a 1pt seam so the two schemes read as two.
private struct HalfMask: View {
    let left: Bool

    var body: some View {
        GeometryReader { geometry in
            let half = geometry.size.width / 2 - 1
            Rectangle()
                .frame(width: half)
                .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
        }
    }
}

/// A drawing of Octet's window in a theme's colours, after T3 Code's theme
/// wireframe: the sidebar and its rows, a reply, two lines of text, the
/// message bar and a floating panel. Placed in fractions of the tile, so it
/// scales with it.
private struct OctetWireframe: View {
    let palette: ThemePalette

    /// A rounded block at fractions of the tile.
    private func block(_ size: CGSize, _ line: Color, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                       _ fill: Color, radius: CGFloat = 3, stroke: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke ? line : .clear, lineWidth: 1))
            .frame(width: size.width * width, height: size.height * height)
            .position(x: size.width * (x + width / 2), y: size.height * (y + height / 2))
    }

    var body: some View {
        let canvas = palette.color(\.background)
        let sidebar = palette.color(\.sidebar)
        let surface = palette.color(\.card)
        let selected = palette.color(\.cardSelected)
        let accent = palette.color(\.accent)
        let line = Color(white: 0.5).opacity(0.25)
        GeometryReader { geometry in
            let size = geometry.size
            let w = size.width
            let h = size.height
            ZStack(alignment: .topLeading) {
                canvas
                // The sidebar, with a hairline at its edge.
                sidebar
                    .frame(width: w * 0.22)
                    .overlay(alignment: .trailing) { line.frame(width: 1) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                block(size, line, 0.03, 0.08, 0.16, 0.08, surface, stroke: true)
                block(size, line, 0.03, 0.22, 0.16, 0.07, selected)
                block(size, line, 0.03, 0.32, 0.16, 0.07, selected.opacity(0.7))
                block(size, line, 0.03, 0.42, 0.16, 0.07, selected.opacity(0.5))
                // A reply, then two lines of the conversation.
                block(size, line, 0.48, 0.11, 0.24, 0.09, selected, radius: 4)
                block(size, line, 0.27, 0.28, 0.34, 0.05, line, radius: 2)
                block(size, line, 0.27, 0.38, 0.26, 0.05, line, radius: 2)
                // The message bar, its placeholder and send button.
                block(size, line, 0.26, 0.77, 0.68, 0.15, surface, radius: 4, stroke: true)
                block(size, line, 0.28, 0.825, 0.22, 0.04, line, radius: 2)
                Circle()
                    .fill(accent)
                    .frame(width: h * 0.087, height: h * 0.087)
                    .position(x: w * 0.905, y: h * 0.845)
                // A floating panel with three status rows.
                block(size, line, 0.75, 0.08, 0.20, 0.46, surface, radius: 4, stroke: true)
                    .shadow(color: .black.opacity(0.14), radius: 2.5, y: 2)
                ForEach(0..<3, id: \.self) { row in
                    let y = 0.08 + 0.46 * (0.1 + Double(row) * 0.3) + 0.46 * 0.1
                    let dot = row == 0 ? Color(hex: "34d399") : row == 1 ? accent : Color(hex: "fbbf24")
                    Circle()
                        .fill(dot.opacity(0.55))
                        .frame(width: h * 0.03, height: h * 0.03)
                        .position(x: w * 0.79, y: h * y)
                    block(size, line, 0.81, y - 0.015, 0.10, 0.03, line, radius: 1.5)
                }
            }
        }
    }
}
