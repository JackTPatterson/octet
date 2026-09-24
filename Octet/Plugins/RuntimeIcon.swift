import AppKit
import SwiftUI

/// A plugin's icon for what a pane runs, tinted in its brand colour. Brand
/// colours that vanish on the theme (Next.js, Bun and Rust are black) move
/// toward the text colour until they read, as language logos do.
struct RuntimeIcon: View {
    let badge: RuntimeBadge
    var size: CGFloat = 11

    var body: some View {
        if let image = Self.image(at: badge.iconPath) {
            let palette = Theme.palette
            let color = badge.color.map {
                ThemePalette.readable($0, on: palette.background, toward: palette.textPrimary, minimum: 3)
            }
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(color.map { Color(hex: $0) } ?? Theme.textSecondary)
                .accessibilityLabel(badge.name)
        }
    }

    /// Plugin icons are files on disk; each is read once.
    private static var cache: [String: NSImage] = [:]

    private static func image(at path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        cache[path] = image
        return image
    }
}
